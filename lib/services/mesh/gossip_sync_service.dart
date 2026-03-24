import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anchor/core/constants/message_keys.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/mesh/golomb_coded_set.dart';

/// Gossip-based message synchronization using Golomb-Coded Sets (GCS).
///
/// ## Protocol Overview
///
/// 1. Periodically (every [syncInterval]), this service builds a GCS encoding
///    of recently-seen message IDs and sends it to connected peers.
/// 2. Each peer decodes the GCS, compares against their own message IDs, and
///    requests any missing messages via the `gossip_request` message type.
/// 3. The requesting peer receives the missing messages via normal transport.
///
/// ## Why GCS over Bloom filters?
///
/// - GCS is ~1.5x more compact than Bloom filters at the same false-positive rate
/// - GCS is decodable — the receiver can extract hash values for set difference
/// - One-shot encoding is cheaper than maintaining a shared Bloom filter state
///
/// ## Wire format
///
/// Outgoing gossip_sync message:
/// ```json
/// {"type": "gossip_sync", "gcs": "<base64-encoded GCS>", "n": 150}
/// ```
///
/// Incoming gossip_request message:
/// ```json
/// {"type": "gossip_request", "missing": ["msg-id-1", "msg-id-2", ...]}
/// ```
class GossipSyncService {
  GossipSyncService({
    this.syncInterval = const Duration(seconds: 30),
    this.maxMessageAge = const Duration(hours: 1),
    GolombCodedSet? gcs,
  }) : _gcs = gcs ?? const GolombCodedSet();

  /// How often to broadcast our GCS to connected peers.
  final Duration syncInterval;

  /// Only include messages newer than this in the GCS. Older messages
  /// are unlikely to be missing from peers who have been connected.
  final Duration maxMessageAge;

  final GolombCodedSet _gcs;

  /// Recently seen message IDs (maintained by the message router).
  /// Maps messageId → timestamp for age-based filtering.
  final Map<String, DateTime> _knownMessageIds = {};

  /// Cache of recent message bytes (for gossip fulfillment).
  /// Maps messageId → serialized packet bytes.
  final Map<String, Uint8List> _recentMessageBytes = {};

  /// Periodic sync timer.
  Timer? _syncTimer;

  /// Callback to send a gossip_sync GCS to a peer.
  /// Parameters: (peerId, encodedPayload)
  void Function(String peerId, Map<String, dynamic> payload)? onSendGossip;

  /// Callback when we determine we're missing messages from a peer.
  /// Parameters: (peerId, missingMessageIds, originalN)
  void Function(String peerId, List<String> missingIds, int originalN)?
      onMissingMessages;

  /// Callback to resend a cached message to a peer who requested it.
  /// Parameters: (peerId, serializedMessageBytes)
  void Function(String peerId, Uint8List messageBytes)? onResendMessage;

  /// Connected peer IDs to sync with.
  final Set<String> _connectedPeers = {};

  // ==================== Public API ====================

  /// Start periodic gossip sync.
  void start() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(syncInterval, (_) => _broadcastGcs());
    Logger.info(
      'GossipSync: Started (interval=${syncInterval.inSeconds}s)',
      'Mesh',
    );
  }

  /// Stop periodic gossip sync.
  void stop() {
    _syncTimer?.cancel();
    _syncTimer = null;
    Logger.info('GossipSync: Stopped', 'Mesh');
  }

  /// Register a message ID as known (seen/sent by us).
  void addMessageId(String messageId) {
    _knownMessageIds[messageId] = DateTime.now();
  }

  /// Cache a message's serialized bytes for potential gossip fulfillment.
  void cacheMessage(String messageId, Uint8List serializedBytes) {
    _recentMessageBytes[messageId] = serializedBytes;
  }

  /// Register a peer as connected (will receive gossip sync).
  void addPeer(String peerId) {
    _connectedPeers.add(peerId);
  }

  /// Remove a disconnected peer.
  void removePeer(String peerId) {
    _connectedPeers.remove(peerId);
  }

  /// Handle an incoming gossip_sync message from a peer.
  ///
  /// Decodes their GCS, computes set difference against our known messages,
  /// and emits [onMissingMessages] for any we're missing.
  void handleGossipSync(String fromPeerId, Map<String, dynamic> payload) {
    try {
      final gcsBase64 = payload[MessageKeys.gcs] as String?;
      final remoteN = payload[MessageKeys.gossipCount] as int?;
      if (gcsBase64 == null || remoteN == null || remoteN == 0) return;

      final gcsBytes = base64Decode(gcsBase64);
      final remoteHashes = _gcs.decode(Uint8List.fromList(gcsBytes));

      if (remoteHashes.isEmpty) return;

      // Re-hash our own message IDs using the sender's modulus
      final modulus = remoteN * _gcs.fpRate;
      final recentIds = _getRecentMessageIds();
      final localHashes = recentIds
          .map((id) => GolombCodedSet.hashItem(id, modulus))
          .toList()
        ..sort();

      final missingIndices =
          GolombCodedSet.setDifference(remoteHashes, localHashes);

      if (missingIndices.isNotEmpty) {
        Logger.info(
          'GossipSync: Found ${missingIndices.length} potentially missing '
          'messages from $fromPeerId',
          'Mesh',
        );
        // We can't map indices back to message IDs (GCS is one-way), so
        // we send the hash indices to the peer along with the originalN
        // so they can resolve which messages to resend.
        onMissingMessages?.call(
          fromPeerId,
          missingIndices.map((i) => '$i').toList(),
          remoteN,
        );
      }
    } on Exception catch (e) {
      Logger.warning(
          'GossipSync: Failed to process sync from $fromPeerId: $e', 'Mesh',);
    }
  }

  /// Handle an incoming gossip_request from a peer.
  ///
  /// Resolves the requested hash indices to message IDs using the given
  /// [originalN] (the sender's message count when they built the GCS we sent),
  /// and triggers resending of matching cached messages.
  void handleGossipRequest(
    String fromPeerId,
    List<int> requestedHashes,
    int originalN,
  ) {
    if (requestedHashes.isEmpty || originalN == 0) return;

    final modulus = originalN * _gcs.fpRate;
    final recentIds = _getRecentMessageIds();

    var resent = 0;
    for (final id in recentIds) {
      final hash = GolombCodedSet.hashItem(id, modulus);
      if (requestedHashes.contains(hash)) {
        final cached = _recentMessageBytes[id];
        if (cached != null) {
          onResendMessage?.call(fromPeerId, cached);
          resent++;
        }
      }
    }

    Logger.info(
      'GossipSync: Fulfilled gossip request from $fromPeerId '
      '(${requestedHashes.length} requested, $resent resent)',
      'Mesh',
    );
  }

  /// Build our GCS payload for sending to a peer.
  Map<String, dynamic>? buildGossipPayload() {
    final recentIds = _getRecentMessageIds();
    if (recentIds.isEmpty) return null;

    final encoded = _gcs.encode(recentIds);
    return {
      MessageKeys.type: MessageTypes.gossipSync,
      MessageKeys.gcs: base64Encode(encoded),
      MessageKeys.gossipCount: recentIds.length,
    };
  }

  /// Clear all state.
  void dispose() {
    stop();
    _knownMessageIds.clear();
    _recentMessageBytes.clear();
    _connectedPeers.clear();
  }

  // ==================== Internal ====================

  /// Get message IDs within [maxMessageAge].
  List<String> _getRecentMessageIds() {
    final cutoff = DateTime.now().subtract(maxMessageAge);
    // Also prune old entries
    _knownMessageIds.removeWhere((_, ts) => ts.isBefore(cutoff));
    // Also prune cached bytes for expired messages
    _recentMessageBytes.removeWhere((id, _) => !_knownMessageIds.containsKey(id));
    return _knownMessageIds.keys.toList();
  }

  /// Broadcast our GCS to all connected peers.
  void _broadcastGcs() {
    if (_connectedPeers.isEmpty) return;

    final payload = buildGossipPayload();
    if (payload == null) return;

    Logger.debug(
      'GossipSync: Broadcasting GCS (${_knownMessageIds.length} IDs) '
      'to ${_connectedPeers.length} peers',
      'Mesh',
    );

    for (final peerId in _connectedPeers) {
      onSendGossip?.call(peerId, payload);
    }
  }
}
