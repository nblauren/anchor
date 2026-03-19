import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/utils/logger.dart';
import '../encryption/encryption.dart';
import '../transport/transport_enums.dart';
import 'bloom_filter.dart';
import 'mesh_packet.dart';
import 'peer_registry.dart';

/// Configuration for the message router.
class RouterConfig {
  const RouterConfig({
    this.defaultTtl = 5,
    this.maxTtl = 7,
    this.anchorDropTtl = 3,
    this.announcesTtl = 7,
    this.photoMetaTtl = 1,
    this.dedupCapacity = 10000,
    this.dedupFpp = 0.01,
    this.highDensityThreshold = 15,
    this.highDensityRelayProbability = 0.65,
    this.sessionTimeoutHours = 24,
    this.storeForwardTtlDays = 7,
    this.maxRetries = 20,
  });

  /// Default TTL for direct messages.
  final int defaultTtl;

  /// Maximum TTL allowed (prevents infinite loops).
  final int maxTtl;

  /// TTL for anchor drop signals (short range, ephemeral).
  final int anchorDropTtl;

  /// TTL for peer announcements (broader discovery).
  final int announcesTtl;

  /// TTL for photo metadata (direct only, too heavy to relay).
  final int photoMetaTtl;

  /// Expected number of unique messages for Bloom filter sizing.
  final int dedupCapacity;

  /// Target false positive rate for Bloom filter.
  final double dedupFpp;

  /// Peer count threshold for high-density mode.
  final int highDensityThreshold;

  /// Relay probability in high-density mode (0.0-1.0).
  final double highDensityRelayProbability;

  /// E2EE session timeout in hours.
  final int sessionTimeoutHours;

  /// Store-and-forward message TTL in days.
  final int storeForwardTtlDays;

  /// Maximum cross-session retries.
  final int maxRetries;
}

/// Result of a send attempt.
enum SendResult {
  /// Message delivered to peer via transport.
  delivered,

  /// Message queued for later delivery (peer offline).
  queued,

  /// Message was a duplicate (already sent/seen).
  duplicate,

  /// Send failed (no transport available, no route).
  failed,
}

/// Unified message router with cross-transport deduplication, gossip relay,
/// and store-and-forward integration.
///
/// ## Architecture
///
/// The MessageRouter sits between the application layer (Blocs) and the
/// transport layer (BLE, LAN, Wi-Fi Aware). It provides:
///
/// 1. **Cross-transport dedup**: Messages received from multiple transports
///    are deduplicated before reaching the application layer.
/// 2. **TTL-based gossip relay**: Messages with TTL > 0 are forwarded to
///    connected peers (minus the sender) with decremented TTL.
/// 3. **Unified encryption**: All encryption goes through this layer.
/// 4. **Adaptive transport selection**: Uses health metrics to pick the
///    best transport for each peer.
///
/// ## Dedup Strategy (Bitchat-inspired)
///
/// Uses a [RotatingBloomFilter] (primary, space-efficient) backed by an
/// LRU [Map] (secondary, exact-match for recent messages). The Bloom filter
/// catches 99% of duplicates; the LRU map provides exact confirmation.
///
/// False positives in the Bloom filter (message incorrectly marked as "seen")
/// are compensated by the gossip protocol's redundancy — the same message
/// arrives via multiple paths.
class MessageRouter {
  MessageRouter({
    required PeerRegistry peerRegistry,
    EncryptionService? encryptionService,
    RouterConfig config = const RouterConfig(),
  })  : _peers = peerRegistry,
        _encryption = encryptionService,
        _config = config,
        _bloomFilter = RotatingBloomFilter(
          expectedInsertions: config.dedupCapacity,
          falsePositiveRate: config.dedupFpp,
        );

  final PeerRegistry _peers;
  final EncryptionService? _encryption;
  final RouterConfig _config;
  final RotatingBloomFilter _bloomFilter;
  final _random = Random();

  /// LRU backup for recent message IDs (exact match, bounded).
  /// Stores messageId → timestamp for the most recent 2000 messages.
  final Map<String, DateTime> _recentIds = {};
  static const _maxRecentIds = 2000;

  /// Own user ID (set after profile is loaded).
  String? ownUserId;

  /// Own truncated ID (cached for packet comparison).
  String? _ownTruncatedId;

  // ==================== Streams ====================

  final _inboundController = StreamController<InboundMessage>.broadcast();
  final _relayController = StreamController<RelayRequest>.broadcast();
  final _ackController = StreamController<String>.broadcast();

  /// Deduplicated inbound messages for the application layer.
  Stream<InboundMessage> get inboundStream => _inboundController.stream;

  /// Relay requests — TransportManager listens and forwards to connected peers.
  Stream<RelayRequest> get relayStream => _relayController.stream;

  /// Message IDs that were acknowledged.
  Stream<String> get ackStream => _ackController.stream;

  // ==================== Send ====================

  /// Prepare a message for sending.
  ///
  /// 1. Check dedup (don't re-send what we already sent)
  /// 2. Encrypt if E2EE session exists
  /// 3. Build MeshPacket
  /// 4. Mark as seen in dedup filter
  ///
  /// Returns null if the message is a duplicate.
  MeshPacket? prepareSend({
    required String messageId,
    required String recipientId,
    required PacketType type,
    required Uint8List payload,
    int? ttl,
  }) {
    if (_isDuplicate(messageId)) return null;
    _markSeen(messageId);

    final effectiveTtl = ttl ?? _ttlForType(type);

    int flags = 0;
    if (recipientId == MeshPacket.broadcastRecipientId) {
      flags |= PacketFlags.broadcast;
    }

    return MeshPacket(
      type: type,
      ttl: effectiveTtl,
      flags: flags,
      timestamp: DateTime.now(),
      senderId: _ownTruncatedId ?? MeshPacket.truncateIdSync(ownUserId ?? ''),
      recipientId: MeshPacket.truncateIdSync(recipientId),
      payload: payload,
      messageId: messageId,
    );
  }

  /// Encrypt a payload for a specific peer.
  ///
  /// Returns the original payload if no E2EE session exists.
  /// Returns encrypted payload with encryption flag if session exists.
  Future<({Uint8List data, bool encrypted})> encryptPayload(
    String canonicalPeerId,
    Uint8List plaintext,
  ) async {
    final enc = _encryption;
    if (enc == null || !enc.hasSession(canonicalPeerId)) {
      return (data: plaintext, encrypted: false);
    }

    final result = await enc.encrypt(canonicalPeerId, plaintext);
    if (result == null) {
      return (data: plaintext, encrypted: false);
    }

    // Wire format: nonce (24) || ciphertext+tag
    final wire = Uint8List(result.nonce.length + result.ciphertext.length);
    wire.setRange(0, result.nonce.length, result.nonce);
    wire.setRange(result.nonce.length, wire.length, result.ciphertext);

    return (data: wire, encrypted: true);
  }

  /// Decrypt a payload from a specific peer.
  Future<Uint8List?> decryptPayload(
    String canonicalPeerId,
    Uint8List ciphertext,
  ) async {
    final enc = _encryption;
    if (enc == null) return null;
    if (ciphertext.length < 24) return null;

    final nonce = ciphertext.sublist(0, 24);
    final ct = ciphertext.sublist(24);

    return enc.decrypt(
      canonicalPeerId,
      EncryptedPayload(nonce: nonce, ciphertext: ct),
    );
  }

  // ==================== Receive ====================

  /// Process an incoming message from ANY transport.
  ///
  /// This is the SINGLE entry point for all received messages. It:
  /// 1. Deduplicates across all transports
  /// 2. Resolves sender to canonical peer ID
  /// 3. Decrypts if needed
  /// 4. Emits to application layer if addressed to us
  /// 5. Relays to mesh if TTL > 0
  Future<void> onReceive({
    required String rawSenderId,
    required String messageId,
    required PacketType type,
    required Uint8List payload,
    required TransportType fromTransport,
    int ttl = 0,
    int flags = 0,
    String? recipientId,
    DateTime? timestamp,
  }) async {
    // 1. DEDUP — the critical cross-transport gate
    if (messageId.isNotEmpty && _isDuplicate(messageId)) {
      Logger.debug(
        'MessageRouter: Dedup dropped $messageId (${fromTransport.name})',
        'Mesh',
      );
      return;
    }
    if (messageId.isNotEmpty) _markSeen(messageId);

    // 2. Resolve sender to canonical peer ID
    final canonicalSender = _peers.resolveCanonical(rawSenderId) ?? rawSenderId;

    // 3. Check if addressed to us
    final isForUs = recipientId == null ||
        recipientId.isEmpty ||
        recipientId == MeshPacket.broadcastRecipientId ||
        recipientId == _ownTruncatedId ||
        recipientId == ownUserId;

    if (isForUs) {
      // 4. Decrypt if encrypted
      Uint8List effectivePayload = payload;
      bool wasEncrypted = false;

      if ((flags & PacketFlags.encrypted) != 0) {
        final decrypted = await decryptPayload(canonicalSender, payload);
        if (decrypted != null) {
          effectivePayload = decrypted;
          wasEncrypted = true;
        } else {
          Logger.warning(
            'MessageRouter: Decryption failed from $canonicalSender — dropping',
            'Mesh',
          );
          return;
        }
      }

      // 5. Emit to application layer
      _inboundController.add(InboundMessage(
        fromPeerId: canonicalSender,
        messageId: messageId,
        type: type,
        payload: effectivePayload,
        timestamp: timestamp ?? DateTime.now(),
        fromTransport: fromTransport,
        isEncrypted: wasEncrypted,
      ));
    }

    // 6. Gossip relay — forward to mesh if TTL > 0 and not photo data
    if (ttl > 0 && _shouldRelay(type)) {
      _relayController.add(RelayRequest(
        messageId: messageId,
        type: type,
        payload: payload,
        ttl: ttl - 1,
        flags: flags | PacketFlags.isRelay,
        senderId: rawSenderId,
        recipientId: recipientId ?? MeshPacket.broadcastRecipientId,
        excludeTransportId: rawSenderId,
        timestamp: timestamp ?? DateTime.now(),
      ));
    }
  }

  /// Process incoming from legacy JSON format (backward compat with current BLE).
  Future<void> onReceiveLegacyJson({
    required Map<String, dynamic> json,
    required String rawSenderId,
    required TransportType fromTransport,
  }) async {
    final messageId = json['messageId'] as String? ?? json['message_id'] as String? ?? '';
    final typeStr = json['type'] as String? ?? 'message';
    final type = _legacyType(typeStr);
    final content = json['content'] as String? ?? '';
    final ttl = json['ttl'] as int? ?? 0;
    final destinationId = json['destination_id'] as String?;

    int flags = 0;
    if (json['v'] == 1) flags |= PacketFlags.encrypted;

    // For encrypted messages, rebuild the ciphertext from JSON fields
    Uint8List payload;
    if ((flags & PacketFlags.encrypted) != 0) {
      final nonce = json['n'] as String?;
      final ciphertext = json['c'] as String?;
      if (nonce != null && ciphertext != null) {
        final nonceBytes = base64.decode(nonce);
        final ctBytes = base64.decode(ciphertext);
        payload = Uint8List(nonceBytes.length + ctBytes.length);
        payload.setRange(0, nonceBytes.length, nonceBytes);
        payload.setRange(nonceBytes.length, payload.length, ctBytes);
      } else {
        payload = Uint8List.fromList(utf8.encode(content));
      }
    } else {
      // Encode the full JSON as payload so the application layer can parse it
      payload = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    }

    await onReceive(
      rawSenderId: rawSenderId,
      messageId: messageId,
      type: type,
      payload: payload,
      fromTransport: fromTransport,
      ttl: ttl,
      flags: flags,
      recipientId: destinationId,
    );
  }

  // ==================== Dedup ====================

  /// Check if a message ID has been seen before.
  bool _isDuplicate(String messageId) {
    if (messageId.isEmpty) return false;
    // Check LRU first (exact match)
    if (_recentIds.containsKey(messageId)) return true;
    // Check Bloom filter (probabilistic)
    return _bloomFilter.mightContain(messageId);
  }

  /// Mark a message ID as seen.
  void _markSeen(String messageId) {
    if (messageId.isEmpty) return;
    _bloomFilter.add(messageId);
    _recentIds[messageId] = DateTime.now();

    // Evict oldest entries from LRU if over capacity
    if (_recentIds.length > _maxRecentIds) {
      final keysToRemove = _recentIds.keys.take(_recentIds.length - _maxRecentIds).toList();
      for (final key in keysToRemove) {
        _recentIds.remove(key);
      }
    }
  }

  /// Check if a message ID has been seen (public, for external callers).
  bool isDuplicate(String messageId) => _isDuplicate(messageId);

  /// Mark a message ID as seen (public, for external callers like BleFacade).
  void markSeen(String messageId) => _markSeen(messageId);

  // ==================== Relay Policy ====================

  /// Whether a packet type should be relayed through the mesh.
  bool _shouldRelay(PacketType type) {
    switch (type) {
      case PacketType.message:
      case PacketType.anchorDrop:
      case PacketType.reaction:
      case PacketType.readReceipt:
      case PacketType.peerAnnounce:
      case PacketType.neighborList:
        return true;
      // Never relay heavy data or handshakes
      case PacketType.handshake:
      case PacketType.photoPreview:
      case PacketType.photoRequest:
      case PacketType.photoData:
      case PacketType.wifiTransferReady:
      case PacketType.ack:
        return false;
    }
  }

  /// Get the appropriate TTL for a packet type.
  int _ttlForType(PacketType type) {
    switch (type) {
      case PacketType.anchorDrop:
        return _config.anchorDropTtl;
      case PacketType.peerAnnounce:
      case PacketType.neighborList:
        return _config.announcesTtl;
      case PacketType.photoPreview:
      case PacketType.photoRequest:
      case PacketType.photoData:
      case PacketType.wifiTransferReady:
        return _config.photoMetaTtl;
      default:
        return _config.defaultTtl;
    }
  }

  PacketType _legacyType(String type) {
    switch (type) {
      case 'message':
      case 'text':
        return PacketType.message;
      case 'noise_hs':
        return PacketType.handshake;
      case 'peer_announce':
        return PacketType.peerAnnounce;
      case 'neighbor_list':
        return PacketType.neighborList;
      case 'drop_anchor':
        return PacketType.anchorDrop;
      case 'reaction':
        return PacketType.reaction;
      case 'photo_preview':
        return PacketType.photoPreview;
      case 'photo_request':
        return PacketType.photoRequest;
      case 'read_receipt':
      case 'read':
        return PacketType.readReceipt;
      default:
        return PacketType.message;
    }
  }

  // ==================== Configuration ====================

  /// Set the own user ID (called after profile load).
  void setOwnUserId(String userId) {
    ownUserId = userId;
    _ownTruncatedId = MeshPacket.truncateIdSync(userId);
  }

  /// Get the visible peer count for relay probability calculations.
  int Function()? getVisiblePeerCount;

  /// Whether relay should be probabilistic (high-density mode).
  bool shouldRelay() {
    final count = getVisiblePeerCount?.call() ?? 0;
    if (count < _config.highDensityThreshold) return true;
    return _random.nextDouble() <= _config.highDensityRelayProbability;
  }

  // ==================== Lifecycle ====================

  Future<void> dispose() async {
    await _inboundController.close();
    await _relayController.close();
    await _ackController.close();
  }
}

/// A deduplicated inbound message ready for the application layer.
class InboundMessage {
  const InboundMessage({
    required this.fromPeerId,
    required this.messageId,
    required this.type,
    required this.payload,
    required this.timestamp,
    required this.fromTransport,
    this.isEncrypted = false,
  });

  /// Canonical peer ID (already resolved by PeerRegistry).
  final String fromPeerId;
  final String messageId;
  final PacketType type;
  final Uint8List payload;
  final DateTime timestamp;
  final TransportType fromTransport;
  final bool isEncrypted;
}

/// A request to relay a message to mesh peers.
class RelayRequest {
  const RelayRequest({
    required this.messageId,
    required this.type,
    required this.payload,
    required this.ttl,
    required this.flags,
    required this.senderId,
    required this.recipientId,
    required this.excludeTransportId,
    required this.timestamp,
  });

  final String messageId;
  final PacketType type;
  final Uint8List payload;
  final int ttl;
  final int flags;
  final String senderId;
  final String recipientId;

  /// Don't relay back to the peer we received it from.
  final String excludeTransportId;
  final DateTime timestamp;
}
