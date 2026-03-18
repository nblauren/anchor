import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../core/utils/logger.dart';
import '../ble_config.dart';
import '../ble_models.dart';
import '../connection/connection_manager.dart';
import '../gatt/gatt_write_queue.dart';

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
/// Extracted from the monolithic BLE service (now [BleFacade]) to:
/// - Separate mesh topology from scan/connection lifecycle
/// - Encapsulate routing table and announce throttle state
/// - Make relay logic independently testable
/// - Allow mesh relay to be disabled cleanly without side effects
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

  /// Routing table: sender userId → set of peer userIds they directly see.
  final Map<String, Set<String>> _neighborMap = {};

  /// Throttle peer_announce broadcasts: once per 5 minutes per peer.
  final Map<String, DateTime> _lastAnnouncedAt = {};

  /// Announce message ID dedup — prevents re-processing our own announces
  /// and duplicate peer_announce messages from the mesh.
  final Set<String> _seenAnnounceIds = {};

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

  // ==================== Public API ====================

  bool get enabled => _enabled;

  set enabled(bool value) {
    _enabled = value;
    Logger.info(
        'MeshRelay: ${value ? "enabled" : "disabled"}', 'BLE');
  }

  int get routingTableSize => _neighborMap.length;

  /// Check if an announce message ID has been seen (for shared dedup).
  bool isAnnounceSeen(String messageId) => _seenAnnounceIds.contains(messageId);

  /// Mark an announce message ID as seen.
  void markAnnounceSeen(String messageId) {
    _seenAnnounceIds.add(messageId);
    Future.delayed(
        const Duration(minutes: 5), () => _seenAnnounceIds.remove(messageId));
  }

  // ==================== Message Relay ====================

  /// Originate a locally-created message into the mesh toward [destinationUserId].
  ///
  /// Called by the facade when a direct BLE connection to the peer isn't
  /// available but the peer may be reachable through an intermediate node.
  /// Returns true if the message was forwarded to at least one connected peer.
  bool originateMessage(Uint8List data, String destinationUserId) {
    if (!_enabled) return false;
    if (_connectionManager.activeConnectionCount == 0) return false;

    // Directed routing first
    final bestRelay = findBestRelayPeer(destinationUserId, '');
    if (bestRelay != null) {
      _writeRelayData(data, bestRelay);
      Logger.info(
        'MeshRelay: Originated message via directed relay for $destinationUserId',
        'BLE',
      );
      return true;
    }

    // Flood to all connected peers
    int relayCount = 0;
    for (final peerId in _connectionManager.connectedPeerIds) {
      if (!_connectionManager.canSendTo(peerId)) continue;
      _writeRelayData(data, peerId);
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
      Map<String, dynamic> json, String receivedFromPeerId) {
    if (!_enabled) return;

    final ttl = json['ttl'] as int? ?? 0;
    if (ttl <= 0) {
      Logger.info('MeshRelay: TTL exhausted, dropping relay', 'BLE');
      return;
    }

    final ownUserId = getOwnUserId?.call() ?? '';
    final relayPath =
        List<String>.from((json['relay_path'] as List<dynamic>? ?? []));

    if (relayPath.contains(ownUserId)) {
      Logger.info('MeshRelay: Already in relay path, dropping', 'BLE');
      return;
    }

    final relayJson = Map<String, dynamic>.from(json);
    relayJson['ttl'] = ttl - 1;
    relayJson['relay_path'] = [...relayPath, ownUserId];

    final data = Uint8List.fromList(utf8.encode(jsonEncode(relayJson)));

    // Directed routing: if we know which peer can reach the destination
    final destinationId = json['destination_id'] as String? ?? '';
    if (destinationId.isNotEmpty) {
      final bestRelay = findBestRelayPeer(destinationId, receivedFromPeerId);
      if (bestRelay != null) {
        _writeRelayData(data, bestRelay);
        Logger.info(
            'MeshRelay: Directed relay to best peer (TTL ${ttl - 1})', 'BLE');
        return;
      }
    }

    // High-density probabilistic drop
    final visibleCount = getVisiblePeerCount?.call() ?? 0;
    final isHighDensity = visibleCount >= _config.highDensityPeerThreshold;
    final relayProb =
        isHighDensity ? _config.highDensityRelayProbability : 1.0;
    final rng = Random();

    // Flood to all connected peers except sender
    int relayCount = 0;
    for (final targetPeerId in _connectionManager.connectedPeerIds) {
      if (targetPeerId == receivedFromPeerId) continue;
      if (!_connectionManager.canSendTo(targetPeerId)) continue;
      if (rng.nextDouble() > relayProb) continue;
      _writeRelayData(data, targetPeerId);
      relayCount++;
    }

    Logger.info(
      'MeshRelay: Flooded message to $relayCount peers '
          '(TTL remaining: ${ttl - 1})',
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
      'type': 'peer_announce',
      'message_id': msgId,
      'peer_id': peer.peerId,
      'peer_user_id': getAppUserIdForPeer?.call(peer.peerId) ?? '',
      'name': peer.name,
      if (peer.age != null) 'age': peer.age,
      if (peer.bio != null) 'bio': peer.bio,
      // Thumbnail omitted — base64 thumbnail easily exceeds the 512-byte BLE
      // attribute value limit, causing Android IllegalArgumentException.
      // Peers fetch thumbnails via GATT profile read instead.
      'ttl': _config.meshTtl - 1,
      'relay_path': <String>[ownUserId],
    };

    // Mark as seen so our own announce doesn't loop back
    markAnnounceSeen(msgId);

    final data = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    _broadcastToAll(data);

    Logger.info(
        'MeshRelay: Announced "${peer.name}" to '
        '${_connectionManager.activeConnectionCount} mesh peers',
        'BLE');
  }

  /// Handle an incoming peer_announce — returns a [RelayedPeerResult] if the
  /// announce should be emitted to the discovery stream, or null if suppressed.
  void handlePeerAnnounce(Map<String, dynamic> json, String fromPeerId) {
    final messageId = json['message_id'] as String? ?? '';

    // Dedup
    if (messageId.isNotEmpty) {
      if (_seenAnnounceIds.contains(messageId)) return;
      markAnnounceSeen(messageId);
    }

    final announcedPeerId = json['peer_id'] as String? ?? '';
    if (announcedPeerId.isEmpty) return;

    // Don't emit ourselves
    final announcedUserId = json['peer_user_id'] as String? ?? '';
    final ownUserId = getOwnUserId?.call() ?? '';
    if (announcedUserId.isNotEmpty && announcedUserId == ownUserId) return;

    // Don't overwrite directly-seen peer
    if (isDirectPeer?.call(announcedPeerId) == true) {
      _relayPeerAnnounce(json, fromPeerId);
      return;
    }

    // Decode thumbnail
    Uint8List? thumbnail;
    final thumbB64 = json['thumbnail_b64'] as String?;
    if (thumbB64 != null && thumbB64.isNotEmpty) {
      try {
        thumbnail = base64Decode(thumbB64);
      } catch (_) {}
    }

    final relayPath =
        List<String>.from(json['relay_path'] as List<dynamic>? ?? []);
    final hopCount = relayPath.length;

    final peer = DiscoveredPeer(
      peerId: announcedPeerId,
      name: json['name'] as String? ?? 'Unknown',
      age: json['age'] as int?,
      bio: json['bio'] as String?,
      thumbnailBytes: thumbnail,
      rssi: null,
      timestamp: DateTime.now(),
      isRelayed: true,
      hopCount: hopCount,
    );

    onRelayedPeerDiscovered?.call(RelayedPeerResult(
      peer: peer,
      userId: announcedUserId.isNotEmpty ? announcedUserId : null,
    ));

    Logger.info(
      'MeshRelay: Mesh-discovered "${peer.name}" ($hopCount hops away)',
      'BLE',
    );

    _relayPeerAnnounce(json, fromPeerId);
  }

  // ==================== Neighbor List / Routing ====================

  /// Store the sender's neighbor list in the routing table.
  void handleNeighborList(Map<String, dynamic> json) {
    final senderId = json['sender_id'] as String? ?? '';
    if (senderId.isEmpty) return;
    final peers = List<String>.from(json['peers'] as List<dynamic>? ?? []);
    _neighborMap[senderId] = Set<String>.from(peers);
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
      'type': 'neighbor_list',
      'sender_id': ownUserId,
      'peers': directPeerUserIds,
      'ttl': 1,
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
  String? findBestRelayPeer(String destinationUserId, String excludePeerId) {
    for (final peerId in _connectionManager.connectedPeerIds) {
      if (peerId == excludePeerId) continue;
      if (!_connectionManager.canSendTo(peerId)) continue;
      final peerUserId = getAppUserIdForPeer?.call(peerId);
      if (peerUserId == null) continue;
      final neighbors = _neighborMap[peerUserId] ?? const {};
      if (neighbors.contains(destinationUserId)) return peerId;
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
    _seenAnnounceIds.clear();
  }

  // ==================== Internal ====================

  void _writeRelayData(Uint8List data, String targetPeerId) {
    final conn = _connectionManager.getConnection(targetPeerId);
    if (conn == null || conn.messagingChar == null) return;
    _writeQueue.enqueueFireAndForget(
      peerId: targetPeerId,
      peripheral: conn.peripheral,
      characteristic: conn.messagingChar!,
      data: data,
      priority: WritePriority.meshRelay,
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
    final ttl = json['ttl'] as int? ?? 0;
    if (ttl <= 0) return;

    final ownUserId = getOwnUserId?.call() ?? '';
    final relayPath =
        List<String>.from(json['relay_path'] as List<dynamic>? ?? []);
    if (relayPath.contains(ownUserId)) return;

    final relayJson = Map<String, dynamic>.from(json);
    relayJson['ttl'] = ttl - 1;
    relayJson['relay_path'] = [...relayPath, ownUserId];

    final data = Uint8List.fromList(utf8.encode(jsonEncode(relayJson)));

    // Directed: prefer a peer who already knows the announced peer
    final announcedPeerId = json['peer_id'] as String? ?? '';
    final announcedUserId = json['peer_user_id'] as String? ?? '';
    final targetId =
        announcedUserId.isNotEmpty ? announcedUserId : announcedPeerId;
    if (targetId.isNotEmpty) {
      final best = findBestRelayPeer(targetId, excludePeerId);
      if (best != null) {
        _writeRelayData(data, best);
        return;
      }
    }

    // Fallback: flood
    _broadcastToAll(data, excludePeerId: excludePeerId);
  }
}
