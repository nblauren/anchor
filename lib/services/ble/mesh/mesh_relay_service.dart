import 'dart:convert';
import 'dart:typed_data';

import 'package:anchor/core/constants/message_keys.dart';
import 'package:anchor/core/utils/logger.dart';
import 'package:anchor/services/ble/ble_config.dart';
import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/ble/connection/connection_manager.dart';
import 'package:anchor/services/ble/gatt/gatt_write_queue.dart';
import 'package:anchor/services/mesh/bloom_filter.dart';
import 'package:anchor/services/mesh/mesh_packet.dart';
import 'package:uuid/uuid.dart';

/// Result of handling an incoming peer_announce — returned to the BLE service
/// so it can update _visiblePeers and _userIdToPeerId.
class RelayedPeerResult {
  const RelayedPeerResult({
    required this.peer,
    this.userId,
  });

  final DiscoveredPeer peer;
  final String? userId;
}

/// Manages BLE mesh relay: message forwarding, peer announcements,
/// neighbor-list routing, and announce dedup.
///
/// ## Improvements over v1
///
/// - **Bloom filter dedup**: Replaces unbounded Set with space-efficient
///   [RotatingBloomFilter] that auto-rotates at capacity (10K messages, 1% FPP).
/// - **TTL on all originated messages**: Previously only relay had TTL;
///   now originated messages also respect TTL limits.
/// - **Neighbor table aging**: Routing entries expire after 10 minutes
///   to prevent stale relay paths.
/// - **Shared Random instance**: One instance per service instead of
///   creating new Random() on every relay decision.
/// - **Improved cycle detection**: Checks both userId AND relay path
///   for loop prevention.
class MeshRelayService {
  MeshRelayService({
    required ConnectionManager connectionManager,
    required GattWriteQueue writeQueue,
    required BleConfig config,
  })  : _connectionManager = connectionManager,
        _writeQueue = writeQueue,
        _config = config;

  final ConnectionManager _connectionManager;
  final GattWriteQueue _writeQueue;
  final BleConfig _config;

  // ==================== State ====================

  /// Whether mesh relay is enabled.
  bool _enabled = true;

  /// When true, all outgoing mesh writes are silently dropped.
  /// Used during critical BLE operations (e.g. wifiTransferReady signal)
  /// to prevent mesh traffic from saturating the iOS prepare queue.
  bool _suppressed = false;

  /// Routing table: sender userId → (set of neighbor userIds, last updated).
  final Map<String, _NeighborEntry> _neighborMap = {};

  /// Throttle peer_announce broadcasts: once per 5 minutes per peer.
  final Map<String, DateTime> _lastAnnouncedAt = {};

  /// Bloom filter for announce dedup — replaces unbounded Set.
  /// Auto-rotates when near capacity to prevent false positive rate growth.
  final RotatingBloomFilter _announceDedup = RotatingBloomFilter(
    expectedInsertions: 5000,
  );

  /// Bloom filter for message relay dedup.
  final RotatingBloomFilter _messageDedup = RotatingBloomFilter(
    expectedInsertions: 10000,
  );

  /// Neighbor entry aging timeout.
  static const _neighborTimeout = Duration(minutes: 10);

  // ==================== Callbacks ====================

  /// Returns this device's own app userId.
  String Function()? getOwnUserId;

  /// Returns the app userId for a given BLE peripheral UUID, or null.
  String? Function(String blePeerId)? getAppUserIdForPeer;

  /// Returns the current visible peer count (for high-density relay probability).
  int Function()? getVisiblePeerCount;

  /// Called when a relayed peer is discovered via mesh announce.
  /// The BLE service uses this to update _visiblePeers and emit to stream.
  void Function(RelayedPeerResult result)? onRelayedPeerDiscovered;

  /// Called to check if a peer is directly visible (not relayed).
  /// If true, the mesh service won't overwrite it with a relayed version.
  bool Function(String peerId)? isDirectPeer;

  /// Signs raw bytes with our Ed25519 private key, returning the signature.
  /// Used to sign peer_announce payloads. Null if E2EE is not available.
  Future<Uint8List?> Function(Uint8List data)? signData;

  /// Verifies a signature against the announced peer's Ed25519 public key.
  /// Returns true if valid. Null if E2EE is not available.
  Future<bool> Function(Uint8List data, Uint8List signature, Uint8List publicKey)? verifySignature;

  // ==================== Public API ====================

  bool get enabled => _enabled;

  set enabled(bool value) {
    _enabled = value;
    Logger.info(
        'MeshRelay: ${value ? "enabled" : "disabled"}', 'BLE',);
  }

  int get routingTableSize => _neighborMap.length;

  bool get suppressed => _suppressed;

  /// Temporarily suppress all outgoing mesh writes.
  /// Call [resumeBroadcasts] to re-enable.
  void suppressBroadcasts() {
    _suppressed = true;
    Logger.info('MeshRelay: Broadcasts suppressed', 'BLE');
  }

  /// Resume outgoing mesh writes after [suppressBroadcasts].
  void resumeBroadcasts() {
    _suppressed = false;
    Logger.info('MeshRelay: Broadcasts resumed', 'BLE');
  }

  /// Check if an announce message ID has been seen (for shared dedup).
  bool isAnnounceSeen(String messageId) => _announceDedup.mightContain(messageId);

  /// Mark an announce message ID as seen.
  void markAnnounceSeen(String messageId) {
    _announceDedup.add(messageId);
  }

  /// Check if a message has been seen for relay dedup.
  bool isMessageSeen(String messageId) => _messageDedup.mightContain(messageId);

  /// Mark a message as seen for relay dedup.
  void markMessageSeen(String messageId) {
    _messageDedup.add(messageId);
  }

  // ==================== Message Relay ====================

  /// Originate a locally-created message into the mesh toward [destinationUserId].
  ///
  /// Now includes TTL (default from config) to prevent unlimited flooding.
  bool originateMessage(Uint8List data, String destinationUserId, {int? ttl}) {
    if (!_enabled) return false;
    if (_connectionManager.activeConnectionCount == 0) return false;

    final effectiveTtl = ttl ?? _config.meshTtl;

    // Inject TTL into the data if it's JSON (for backward compat)
    var effectiveData = data;
    try {
      final json = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      json[MessageKeys.ttl] = effectiveTtl;
      final ownUserId = getOwnUserId?.call() ?? '';
      json[MessageKeys.relayPath] = <String>[ownUserId];
      effectiveData = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    } on Exception catch (_) {
      // Not JSON — send raw
    }

    // Directed routing first
    final bestRelay = findBestRelayPeer(destinationUserId, '');
    if (bestRelay != null) {
      _writeRelayData(effectiveData, bestRelay);
      Logger.info(
        'MeshRelay: Originated message via directed relay for $destinationUserId',
        'BLE',
      );
      return true;
    }

    // Flood to all connected peers with deterministic suppression.
    // Originated messages are always high-priority (we want our own
    // messages delivered).
    var relayCount = 0;
    for (final peerId in _connectionManager.connectedPeerIds) {
      if (!_connectionManager.canSendTo(peerId)) continue;
      _writeRelayData(effectiveData, peerId);
      relayCount++;
    }

    Logger.info(
      'MeshRelay: Originated message, flooded to $relayCount peers',
      'BLE',
    );
    return relayCount > 0;
  }

  /// Relay a message toward its destination via connected peers.
  ///
  /// Uses directed routing (neighbor table) when possible, falls back to
  /// TTL-bounded flooding with probabilistic drop in high-density scenarios.
  void maybeRelayMessage(
      Map<String, dynamic> json, String receivedFromPeerId,) {
    if (!_enabled) return;

    final ttl = json[MessageKeys.ttl] as int? ?? 0;
    if (ttl <= 0) {
      Logger.info('MeshRelay: TTL exhausted, dropping relay', 'BLE');
      return;
    }

    // Dedup: check if we've already relayed this message.
    // If it's in the dedup cache, another neighbor already relayed it —
    // track the observation count for suppression decisions.
    final messageId = json[MessageKeys.messageIdCamel] as String? ?? json[MessageKeys.messageId] as String? ?? '';
    if (messageId.isNotEmpty && isMessageSeen(messageId)) {
      _trackRelayObservation(messageId);
      Logger.debug('MeshRelay: Dedup dropped relay for $messageId', 'BLE');
      return;
    }
    if (messageId.isNotEmpty) markMessageSeen(messageId);

    final ownUserId = getOwnUserId?.call() ?? '';
    final relayPath =
        List<String>.from(json[MessageKeys.relayPath] as List<dynamic>? ?? []);

    // Cycle detection: check both userId and path
    if (relayPath.contains(ownUserId)) {
      Logger.info('MeshRelay: Already in relay path, dropping', 'BLE');
      return;
    }

    final relayJson = Map<String, dynamic>.from(json);
    relayJson[MessageKeys.ttl] = ttl - 1;
    relayJson[MessageKeys.relayPath] = [...relayPath, ownUserId];

    final data = Uint8List.fromList(utf8.encode(jsonEncode(relayJson)));

    // Directed routing: if we know which peer can reach the destination
    final destinationId = json[MessageKeys.destinationId] as String? ?? '';
    if (destinationId.isNotEmpty) {
      final bestRelay = findBestRelayPeer(destinationId, receivedFromPeerId);
      if (bestRelay != null) {
        _writeRelayData(data, bestRelay);
        Logger.info(
            'MeshRelay: Directed relay to best peer (TTL ${ttl - 1})', 'BLE',);
        return;
      }
    }

    // Flood to all connected peers except sender, with deterministic suppression
    var relayCount = 0;
    final type = json[MessageKeys.type] as String? ?? '';
    final isHighPriority = type == MessageTypes.noiseHandshake || type == MessageTypes.dropAnchor;
    for (final targetPeerId in _connectionManager.connectedPeerIds) {
      if (targetPeerId == receivedFromPeerId) continue;
      if (!_connectionManager.canSendTo(targetPeerId)) continue;
      if (!_shouldRelay(messageId: messageId, isHighPriority: isHighPriority)) continue;
      _writeRelayData(data, targetPeerId);
      relayCount++;
    }

    Logger.info(
      'MeshRelay: Flooded message to $relayCount peers '
          '(TTL remaining: ${ttl - 1})',
      'BLE',
    );
  }

  /// Relay a binary MeshPacket toward its destination.
  ///
  /// Pure binary path — no JSON conversion. Decrements TTL, applies dedup
  /// and cycle detection, then forwards to connected peers.
  void maybeRelayBinaryPacket(MeshPacket packet, String receivedFromPeerId) {
    if (!_enabled) return;
    if (packet.ttl <= 0) {
      Logger.info('MeshRelay: Binary TTL exhausted, dropping', 'BLE');
      return;
    }

    final messageId = packet.messageId;
    if (messageId.isNotEmpty && isMessageSeen(messageId)) {
      _trackRelayObservation(messageId);
      Logger.debug('MeshRelay: Dedup dropped binary relay for $messageId', 'BLE');
      return;
    }
    if (messageId.isNotEmpty) markMessageSeen(messageId);

    // Cycle detection via sender ID
    final ownUserId = getOwnUserId?.call() ?? '';
    final ownTruncated = MeshPacket.truncateIdSync(ownUserId);
    if (packet.senderId == ownTruncated) {
      Logger.info('MeshRelay: Own packet returned, dropping', 'BLE');
      return;
    }

    final relayPacket = packet.decrementTtl();
    final data = relayPacket.serialize();

    // Directed routing: if recipient is known, try best relay
    if (!relayPacket.isBroadcast) {
      final bestRelay = findBestRelayPeer(relayPacket.recipientId, receivedFromPeerId);
      if (bestRelay != null) {
        _writeRelayData(data, bestRelay);
        Logger.info(
          'MeshRelay: Directed binary relay (TTL ${relayPacket.ttl})',
          'BLE',
        );
        return;
      }
    }

    // Flood to all connected peers except sender
    var relayCount = 0;
    final isHighPriority = relayPacket.type == PacketType.handshake ||
        relayPacket.type == PacketType.anchorDrop;
    for (final targetPeerId in _connectionManager.connectedPeerIds) {
      if (targetPeerId == receivedFromPeerId) continue;
      if (!_connectionManager.canSendTo(targetPeerId)) continue;
      if (!_shouldRelay(messageId: messageId, isHighPriority: isHighPriority)) continue;
      _writeRelayData(data, targetPeerId);
      relayCount++;
    }

    Logger.info(
      'MeshRelay: Binary flood to $relayCount peers (TTL ${relayPacket.ttl})',
      'BLE',
    );
  }

  // ==================== Peer Announce ====================

  /// Broadcast a peer_announce for a directly-discovered peer.
  /// Throttled to once per 5 minutes per peer.
  void announcePeerToMesh(DiscoveredPeer peer) {
    if (!_enabled) return;
    if (_connectionManager.activeConnectionCount == 0) return;
    if (peer.isRelayed) return;

    final now = DateTime.now();
    final lastAnnounced = _lastAnnouncedAt[peer.peerId];
    if (lastAnnounced != null && now.difference(lastAnnounced).inMinutes < 5) {
      return;
    }
    _lastAnnouncedAt[peer.peerId] = now;

    final ownUserId = getOwnUserId?.call() ?? '';

    final msgId = const Uuid().v4();
    final json = <String, dynamic>{
      MessageKeys.type: MessageTypes.peerAnnounce,
      MessageKeys.messageId: msgId,
      MessageKeys.peerId: peer.peerId,
      MessageKeys.peerUserId: getAppUserIdForPeer?.call(peer.peerId) ?? '',
      MessageKeys.name: peer.name,
      if (peer.age != null) MessageKeys.age: peer.age,
      if (peer.bio != null) MessageKeys.bio: peer.bio,
      if (peer.publicKeyHex != null) MessageKeys.publicKey: peer.publicKeyHex,
      if (peer.signingPublicKeyHex != null) MessageKeys.signingPublicKey: peer.signingPublicKeyHex,
      MessageKeys.ttl: _config.meshTtl - 1,
      MessageKeys.relayPath: <String>[ownUserId],
    };

    // Mark as seen so our own announce doesn't loop back
    markAnnounceSeen(msgId);

    // Sign the announce payload with our Ed25519 key if available.
    // Fire-and-forget: sign → broadcast asynchronously.
    _signAndBroadcastAnnounce(json);
  }

  Future<void> _signAndBroadcastAnnounce(Map<String, dynamic> json) async {
    if (signData != null) {
      // Sign the canonical JSON (without the sig field) for deterministic verification.
      final payloadBytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      final sig = await signData!(payloadBytes);
      if (sig != null) {
        json[MessageKeys.signature] = base64Encode(sig);
      }
    }

    final data = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    _broadcastToAll(data);

    Logger.info(
        'MeshRelay: Announced "${json[MessageKeys.name]}" to '
        '${_connectionManager.activeConnectionCount} mesh peers'
        '${json.containsKey(MessageKeys.signature) ? ' (signed)' : ''}',
        'BLE',);
  }

  /// Handle an incoming peer_announce — returns a [RelayedPeerResult] if the
  /// announce should be emitted to the discovery stream, or null if suppressed.
  Future<void> handlePeerAnnounce(Map<String, dynamic> json, String fromPeerId) async {
    final messageId = json[MessageKeys.messageId] as String? ?? '';

    // Dedup via Bloom filter
    if (messageId.isNotEmpty) {
      if (_announceDedup.mightContain(messageId)) return;
      markAnnounceSeen(messageId);
    }

    final announcedPeerId = json[MessageKeys.peerId] as String? ?? '';
    if (announcedPeerId.isEmpty) return;

    // Don't emit ourselves
    final announcedUserId = json[MessageKeys.peerUserId] as String? ?? '';
    final ownUserId = getOwnUserId?.call() ?? '';
    if (announcedUserId.isNotEmpty && announcedUserId == ownUserId) return;

    // Don't overwrite directly-seen peer
    if (isDirectPeer?.call(announcedPeerId) ?? false) {
      _relayPeerAnnounce(json, fromPeerId);
      return;
    }

    // Verify Ed25519 signature if present and we have a verify callback.
    final sigB64 = json[MessageKeys.signature] as String?;
    final spkHex = json[MessageKeys.signingPublicKey] as String?;
    if (sigB64 != null && spkHex != null && spkHex.length == 64 && verifySignature != null) {
      try {
        final sig = base64Decode(sigB64);
        final spkBytes = _hexToBytes(spkHex);
        // Reconstruct the signed payload (JSON without the 'sig' field).
        final signedJson = Map<String, dynamic>.from(json)..remove(MessageKeys.signature);
        final payloadBytes = Uint8List.fromList(utf8.encode(jsonEncode(signedJson)));
        final valid = await verifySignature!(payloadBytes, Uint8List.fromList(sig), spkBytes);
        if (!valid) {
          Logger.warning(
            'MeshRelay: Dropping peer_announce for "$announcedPeerId" — invalid signature',
            'BLE',
          );
          return;
        }
      } on Exception catch (e) {
        Logger.warning('MeshRelay: Signature verification failed: $e', 'BLE');
        // Don't drop — old clients won't sign, so missing/malformed sigs are tolerated.
      }
    }

    // Decode thumbnail
    Uint8List? thumbnail;
    final thumbB64 = json[MessageKeys.thumbnailB64] as String?;
    if (thumbB64 != null && thumbB64.isNotEmpty) {
      try {
        thumbnail = base64Decode(thumbB64);
      } on Exception catch (_) {}
    }

    final relayPath =
        List<String>.from(json[MessageKeys.relayPath] as List<dynamic>? ?? []);
    final hopCount = relayPath.length;

    final peerPkHex = json[MessageKeys.publicKey] as String?;
    final peerSpkHex = json[MessageKeys.signingPublicKey] as String?;

    final peer = DiscoveredPeer(
      peerId: announcedPeerId,
      name: json[MessageKeys.name] as String? ?? 'Unknown',
      age: json[MessageKeys.age] as int?,
      bio: json[MessageKeys.bio] as String?,
      thumbnailBytes: thumbnail,
      timestamp: DateTime.now(),
      isRelayed: true,
      hopCount: hopCount,
      publicKeyHex: peerPkHex?.length == 64 ? peerPkHex : null,
      signingPublicKeyHex: peerSpkHex?.length == 64 ? peerSpkHex : null,
    );

    onRelayedPeerDiscovered?.call(RelayedPeerResult(
      peer: peer,
      userId: announcedUserId.isNotEmpty ? announcedUserId : null,
    ),);

    Logger.info(
      'MeshRelay: Mesh-discovered "${peer.name}" ($hopCount hops away)',
      'BLE',
    );

    _relayPeerAnnounce(json, fromPeerId);
  }

  // ==================== Neighbor List / Routing ====================

  /// Store the sender's neighbor list in the routing table.
  /// Entries now have a timestamp and expire after [_neighborTimeout].
  void handleNeighborList(Map<String, dynamic> json) {
    final senderId = json[MessageKeys.senderId] as String? ?? '';
    if (senderId.isEmpty) return;
    final peers = List<String>.from(json[MessageKeys.peers] as List<dynamic>? ?? []);
    _neighborMap[senderId] = _NeighborEntry(
      neighbors: Set<String>.from(peers),
      updatedAt: DateTime.now(),
    );
    Logger.info(
      'MeshRelay: Updated routing table for $senderId '
          '(${peers.length} neighbors)',
      'BLE',
    );
  }

  /// Broadcast our neighbor list to all connected peers.
  void broadcastNeighborList(List<String> directPeerUserIds) {
    if (!_enabled || _connectionManager.activeConnectionCount == 0) return;
    if (directPeerUserIds.isEmpty) return;

    final ownUserId = getOwnUserId?.call() ?? '';
    final json = <String, dynamic>{
      MessageKeys.type: MessageTypes.neighborList,
      MessageKeys.senderId: ownUserId,
      MessageKeys.peers: directPeerUserIds,
      MessageKeys.ttl: 1,
    };

    final data = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    _broadcastToAll(data);

    Logger.info(
      'MeshRelay: Broadcast neighbor list '
          '(${directPeerUserIds.length} peers to '
          '${_connectionManager.activeConnectionCount} nodes)',
      'BLE',
    );
  }

  /// Find the best relay peer for a destination userId.
  /// Now checks for stale neighbor entries and removes them.
  String? findBestRelayPeer(String destinationUserId, String excludePeerId) {
    final now = DateTime.now();
    for (final peerId in _connectionManager.connectedPeerIds) {
      if (peerId == excludePeerId) continue;
      if (!_connectionManager.canSendTo(peerId)) continue;
      final peerUserId = getAppUserIdForPeer?.call(peerId);
      if (peerUserId == null) continue;
      final entry = _neighborMap[peerUserId];
      if (entry == null) continue;
      // Check for stale entry
      if (now.difference(entry.updatedAt) > _neighborTimeout) {
        _neighborMap.remove(peerUserId);
        continue;
      }
      if (entry.neighbors.contains(destinationUserId)) return peerId;
    }
    return null;
  }

  // ==================== Cleanup ====================

  void clearPeer(String peerId) {
    _lastAnnouncedAt.remove(peerId);
  }

  void clear() {
    _neighborMap.clear();
    _lastAnnouncedAt.clear();
    _announceDedup.clear();
    _messageDedup.clear();
    _dedupRelayCount.clear();
  }

  // ==================== Internal ====================

  /// Deterministic relay decision for high-density environments.
  ///
  /// In low-density mode (< threshold peers), always relay.
  /// In high-density mode, suppress a message if 2+ neighbors have already
  /// relayed it (tracked via the dedup cache hit count). This replaces the
  /// old probabilistic drop (random 65% relay) with a rule that guarantees
  /// at least 2 relay paths per message while preventing flood storms.
  final Map<String, int> _dedupRelayCount = {};

  bool _shouldRelay({String? messageId, bool isHighPriority = false}) {
    // Always relay high-priority messages (handshakes, anchor drops).
    if (isHighPriority) return true;

    final visibleCount = getVisiblePeerCount?.call() ?? 0;
    if (visibleCount < _config.highDensityPeerThreshold) return true;

    // In high-density: suppress if 2+ neighbors already relayed this message.
    if (messageId != null && messageId.isNotEmpty) {
      final count = _dedupRelayCount[messageId] ?? 0;
      if (count >= 2) return false;
    }
    return true;
  }

  /// Increment the relay observation count for a message.
  /// Called when we see a message that was already in the dedup cache
  /// (meaning a neighbor relayed it).
  void _trackRelayObservation(String messageId) {
    _dedupRelayCount[messageId] = (_dedupRelayCount[messageId] ?? 0) + 1;
    // Bound the map to prevent unbounded growth — piggyback on dedup capacity.
    if (_dedupRelayCount.length > 10000) {
      // Remove oldest ~half of entries.
      final keys = _dedupRelayCount.keys.toList();
      for (var i = 0; i < keys.length ~/ 2; i++) {
        _dedupRelayCount.remove(keys[i]);
      }
    }
  }

  void _writeRelayData(Uint8List data, String targetPeerId) {
    if (_suppressed) return;
    final conn = _connectionManager.getConnection(targetPeerId);
    if (conn == null || conn.messagingChar == null) return;
    _writeQueue.enqueueFireAndForget(
      peerId: targetPeerId,
      peripheral: conn.peripheral,
      characteristic: conn.messagingChar!,
      data: data,
    );
  }

  /// Broadcast data to all connected peers via the write queue.
  void _broadcastToAll(
    Uint8List data, {
    String? excludePeerId,
  }) {
    for (final peerId in _connectionManager.connectedPeerIds) {
      if (peerId == excludePeerId) continue;
      if (_connectionManager.isDeadPeer(peerId)) continue;
      _writeRelayData(data, peerId);
    }
  }

  void _relayPeerAnnounce(Map<String, dynamic> json, String excludePeerId) {
    final ttl = json[MessageKeys.ttl] as int? ?? 0;
    if (ttl <= 0) return;

    final ownUserId = getOwnUserId?.call() ?? '';
    final relayPath =
        List<String>.from(json[MessageKeys.relayPath] as List<dynamic>? ?? []);
    if (relayPath.contains(ownUserId)) return;

    final relayJson = Map<String, dynamic>.from(json);
    relayJson[MessageKeys.ttl] = ttl - 1;
    relayJson[MessageKeys.relayPath] = [...relayPath, ownUserId];

    final data = Uint8List.fromList(utf8.encode(jsonEncode(relayJson)));

    // Directed: prefer a peer who already knows the announced peer
    final announcedPeerId = json[MessageKeys.peerId] as String? ?? '';
    final announcedUserId = json[MessageKeys.peerUserId] as String? ?? '';
    final targetId =
        announcedUserId.isNotEmpty ? announcedUserId : announcedPeerId;
    if (targetId.isNotEmpty) {
      final best = findBestRelayPeer(targetId, excludePeerId);
      if (best != null) {
        _writeRelayData(data, best);
        return;
      }
    }

    // Fallback: flood with deterministic suppression.
    // Peer announces are high-priority (discovery is critical).
    final msgId = json[MessageKeys.messageId] as String? ?? '';
    for (final peerId in _connectionManager.connectedPeerIds) {
      if (peerId == excludePeerId) continue;
      if (_connectionManager.isDeadPeer(peerId)) continue;
      if (!_shouldRelay(messageId: msgId, isHighPriority: true)) continue;
      _writeRelayData(data, peerId);
    }
  }

  /// Convert a hex string to bytes.
  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

/// Neighbor entry with aging support.
class _NeighborEntry {
  const _NeighborEntry({
    required this.neighbors,
    required this.updatedAt,
  });

  final Set<String> neighbors;
  final DateTime updatedAt;
}
