import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Packet types for the mesh protocol.
///
/// Each type has a fixed byte value for binary serialization.
enum PacketType {
  /// Encrypted chat message (text, typing, read receipt).
  message(0x01),

  /// Noise_XK handshake frame (steps 1-3).
  handshake(0x02),

  /// Peer announcement for mesh discovery.
  peerAnnounce(0x03),

  /// Neighbor list exchange for routing table updates.
  neighborList(0x04),

  /// Delivery acknowledgment.
  ack(0x05),

  /// Drop anchor signal (⚓).
  anchorDrop(0x06),

  /// Emoji reaction.
  reaction(0x07),

  /// Photo preview (consent-first flow, phase 1).
  photoPreview(0x08),

  /// Photo request (consent grant, phase 2).
  photoRequest(0x09),

  /// Full photo data (binary chunks).
  photoData(0x0A),

  /// Wi-Fi transfer ready signal.
  wifiTransferReady(0x0B),

  /// Read receipt.
  readReceipt(0x0C),

  /// GCS gossip sync — broadcast our known message ID set to peers.
  gossipSync(0x0D),

  /// Gossip request — ask a peer for specific missing messages.
  gossipRequest(0x0E);

  const PacketType(this.value);
  final int value;

  static PacketType fromValue(int value) {
    return PacketType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => PacketType.message,
    );
  }
}

/// Packet flags (bitfield).
class PacketFlags {
  static const int encrypted = 0x01;
  static const int broadcast = 0x02;
  static const int requiresAck = 0x04;
  static const int isRelay = 0x08;
  static const int hasSignature = 0x10;

  /// Packet includes a source route (list of intermediate peer IDs).
  /// When set, relay nodes follow the route instead of flooding.
  static const int hasSourceRoute = 0x20;

  /// The PacketType byte is XOR-masked to prevent traffic analysis.
  /// Observers cannot distinguish message types without knowing the
  /// sender ID and timestamp (both in the same header).
  static const int typeHidden = 0x40;
}

/// Binary mesh packet — the unified wire format for all transports.
///
/// ## Header Format (30 bytes fixed)
///
/// ```
/// Offset  Size  Field
/// ------  ----  -----
///   0      1    Version (protocol version, currently 1)
///   1      1    Type (PacketType enum value)
///   2      1    TTL (hop counter, decremented at each relay)
///   3      1    Flags (bitfield: encrypted, broadcast, requiresAck, isRelay)
///   4      8    Timestamp (milliseconds since epoch, big-endian uint64)
///  12      8    Sender ID (first 8 bytes of SHA-256 of sender's app userId)
///  20      8    Recipient ID (first 8 bytes of SHA-256 of recipient's app userId,
///                              or 0xFF×8 for broadcast)
///  28      2    Payload length (big-endian uint16, max 65535 bytes)
/// ```
///
/// ## Variable-Length Sections
///
/// ```
///  30      N    Payload (encrypted or plaintext, depending on flags)
///  30+N   16    Message ID (UUID bytes, for deduplication)
/// ```
///
/// Total packet size: 46 + payload bytes
///
/// ## Comparison with JSON
///
/// A typical JSON message: `{"type":"message","messageId":"<36>","sender_id":"<36>",
/// "content":"hello","ttl":3}` = ~150 bytes overhead.
///
/// MeshPacket header: 46 bytes fixed = **70% less overhead**.
class MeshPacket {
  const MeshPacket({
    this.version = 1,
    required this.type,
    required this.ttl,
    this.flags = 0,
    required this.timestamp,
    required this.senderId,
    required this.recipientId,
    required this.payload,
    required this.messageId,
    this.sourceRoute,
    this.signature,
  });

  static const int headerSize = 30;
  static const int messageIdSize = 16;
  static const int broadcastId8 = 0xFFFFFFFFFFFFFFFF;

  /// Protocol version (currently 1).
  final int version;

  /// Packet type.
  final PacketType type;

  /// Time-to-live: decremented at each relay hop. Dropped when 0.
  final int ttl;

  /// Bitfield flags.
  final int flags;

  /// Packet creation timestamp.
  final DateTime timestamp;

  /// Truncated sender ID (8 bytes from SHA-256 of app userId).
  final String senderId;

  /// Truncated recipient ID (8 bytes), or [broadcastRecipientId] for broadcast.
  final String recipientId;

  /// Payload bytes (encrypted content, handshake data, etc.).
  final Uint8List payload;

  /// Full message ID (UUID string) for deduplication.
  final String messageId;

  /// Optional source route: ordered list of truncated intermediate peer IDs
  /// the packet should traverse. When present, relay nodes follow the route
  /// instead of flooding. Each hop pops the first entry and forwards to it.
  final List<String>? sourceRoute;

  /// Optional Ed25519 signature (64 bytes) over the unsigned packet bytes.
  /// Present when the sender signed the packet before transmission.
  final Uint8List? signature;

  /// Whether this packet is a broadcast (all-peers).
  bool get isBroadcast => recipientId == broadcastRecipientId;

  /// Whether this packet is encrypted.
  bool get isEncrypted => (flags & PacketFlags.encrypted) != 0;

  /// Whether this packet was relayed (not from original sender).
  bool get isRelay => (flags & PacketFlags.isRelay) != 0;

  /// Broadcast recipient sentinel.
  static const String broadcastRecipientId = 'ffffffffffffffff';

  /// Create a decremented-TTL copy for relay.
  /// If a source route is present, the first hop is consumed.
  MeshPacket decrementTtl() {
    final remainingRoute = (sourceRoute != null && sourceRoute!.length > 1)
        ? sourceRoute!.sublist(1)
        : null;
    return MeshPacket(
      version: version,
      type: type,
      ttl: ttl - 1,
      flags: flags | PacketFlags.isRelay,
      timestamp: timestamp,
      senderId: senderId,
      recipientId: recipientId,
      payload: payload,
      messageId: messageId,
      sourceRoute: remainingRoute,
      signature: signature,
    );
  }

  /// The next hop peer ID from the source route, or null if no route / exhausted.
  String? get nextHop =>
      (sourceRoute != null && sourceRoute!.isNotEmpty) ? sourceRoute!.first : null;

  /// Serialize to binary.
  ///
  /// Type hiding: the PacketType byte is XOR-masked using sender ID and
  /// timestamp bytes already present in the header. This prevents passive
  /// observers from distinguishing message types without parsing the header.
  Uint8List serialize() {
    final totalSize = headerSize + payload.length + messageIdSize;
    final data = ByteData(totalSize);

    // Sender ID and timestamp — needed early for type mask
    final senderBytes = _truncatedIdBytes(senderId);
    final ms = timestamp.millisecondsSinceEpoch;

    // Compute type mask: XOR of first sender byte and low timestamp byte.
    // Both are in the header, so the receiver can reconstruct the mask.
    final typeMask = senderBytes[0] ^ (ms & 0xFF);
    final maskedType = type.value ^ typeMask;
    final effectiveFlags = flags | PacketFlags.typeHidden;

    // Header
    data.setUint8(0, version);
    data.setUint8(1, maskedType);
    data.setUint8(2, ttl);
    data.setUint8(3, effectiveFlags);

    // Timestamp (ms since epoch, big-endian)
    data.setUint32(4, (ms >> 32) & 0xFFFFFFFF, Endian.big);
    data.setUint32(8, ms & 0xFFFFFFFF, Endian.big);

    final result = Uint8List(totalSize);
    final headerBytes = data.buffer.asUint8List();
    result.setRange(0, headerSize, headerBytes);
    result.setRange(12, 20, senderBytes);

    // Recipient ID (8 bytes)
    final recipientBytes = _truncatedIdBytes(recipientId);
    result.setRange(20, 28, recipientBytes);

    // Payload length
    result[28] = (payload.length >> 8) & 0xFF;
    result[29] = payload.length & 0xFF;

    // Payload
    result.setRange(headerSize, headerSize + payload.length, payload);

    // Message ID (16 bytes — UUID without hyphens, as bytes)
    final msgIdBytes = _uuidToBytes(messageId);
    result.setRange(headerSize + payload.length, totalSize, msgIdBytes);

    return result;
  }

  /// Deserialize from binary.
  ///
  /// Automatically unmaskes the PacketType byte if [PacketFlags.typeHidden]
  /// is set, using the same sender ID + timestamp XOR mask from [serialize].
  ///
  /// If the [PacketFlags.hasSignature] flag is set, the last 64 bytes of the
  /// data are treated as an Ed25519 signature and stored in [signature].
  static MeshPacket? deserialize(Uint8List data) {
    if (data.length < headerSize + messageIdSize) return null;

    final bd = ByteData.sublistView(data);

    final version = bd.getUint8(0);
    final rawTypeByte = bd.getUint8(1);
    final ttl = bd.getUint8(2);
    final flags = bd.getUint8(3);

    // Check for signature: if hasSignature flag is set, last 64 bytes are sig
    Uint8List? signature;
    Uint8List effectiveData = data;
    if ((flags & PacketFlags.hasSignature) != 0) {
      if (data.length < headerSize + messageIdSize + 64) return null;
      signature = Uint8List.fromList(data.sublist(data.length - 64));
      effectiveData = Uint8List.fromList(data.sublist(0, data.length - 64));
    }

    // Timestamp
    final msHigh = bd.getUint32(4, Endian.big);
    final msLow = bd.getUint32(8, Endian.big);
    final ms = (msHigh << 32) | msLow;
    final timestamp = DateTime.fromMillisecondsSinceEpoch(ms);

    // Sender ID (8 bytes → hex string)
    final senderBytes = effectiveData.sublist(12, 20);
    final senderId = _bytesToHex(senderBytes);

    // Unmask the type byte if typeHidden flag is set
    final int typeByte;
    if ((flags & PacketFlags.typeHidden) != 0) {
      final typeMask = senderBytes[0] ^ (ms & 0xFF);
      typeByte = rawTypeByte ^ typeMask;
    } else {
      typeByte = rawTypeByte;
    }
    final type = PacketType.fromValue(typeByte);

    // Recipient ID
    final recipientBytes = effectiveData.sublist(20, 28);
    final recipientId = _bytesToHex(recipientBytes);

    // Payload length
    final payloadLen = (effectiveData[28] << 8) | effectiveData[29];
    if (effectiveData.length < headerSize + payloadLen + messageIdSize) return null;

    // Payload
    final payload = effectiveData.sublist(headerSize, headerSize + payloadLen);

    // Message ID (16 bytes → UUID string)
    final msgIdBytes =
        effectiveData.sublist(headerSize + payloadLen, headerSize + payloadLen + messageIdSize);
    final messageId = _bytesToUuid(msgIdBytes);

    // Strip typeHidden and hasSignature from flags — they're wire-only concerns
    final cleanFlags = flags & ~PacketFlags.typeHidden & ~PacketFlags.hasSignature;

    return MeshPacket(
      version: version,
      type: type,
      ttl: ttl,
      flags: cleanFlags,
      timestamp: timestamp,
      senderId: senderId,
      recipientId: recipientId,
      payload: Uint8List.fromList(payload),
      messageId: messageId,
      signature: signature,
    );
  }

  /// Convert a full UUID/userId to truncated 8-byte ID.
  ///
  /// Uses SHA-256 and takes the first 8 bytes for compact representation.
  /// Collision probability: ~2^-32 at 65,536 peers (negligible for cruise ships).
  static Future<String> truncateId(String fullId) async {
    final hash = await Sha256().hash(utf8.encode(fullId));
    return _bytesToHex(Uint8List.fromList(hash.bytes.sublist(0, 8)));
  }

  /// Synchronous truncation using simple hash (for packet creation).
  static String truncateIdSync(String fullId) {
    // FNV-1a 64-bit for deterministic truncation
    int hash = 0xcbf29ce484222325;
    for (int i = 0; i < fullId.length; i++) {
      hash ^= fullId.codeUnitAt(i);
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    final bytes = Uint8List(8);
    final bd = ByteData.sublistView(bytes);
    bd.setUint64(0, hash, Endian.big);
    return _bytesToHex(bytes);
  }

  // ==================== Signature Utilities ====================

  /// Sign serialized packet bytes. Returns new bytes with signature appended
  /// and [PacketFlags.hasSignature] flag set.
  ///
  /// The input [serialized] bytes must NOT already have hasSignature set.
  /// Returns null if the sign function fails or returns wrong length.
  static Future<Uint8List?> signSerialized(
    Uint8List serialized,
    Future<Uint8List?> Function(Uint8List) signFn,
  ) async {
    final sig = await signFn(serialized);
    if (sig == null || sig.length != 64) return null;
    // Create new buffer: serialized + signature
    final signed = Uint8List(serialized.length + 64);
    signed.setRange(0, serialized.length, serialized);
    signed.setRange(serialized.length, signed.length, sig);
    // Set hasSignature flag in byte 3
    signed[3] = signed[3] | PacketFlags.hasSignature;
    return signed;
  }

  /// Extract unsigned bytes and signature from signed packet data.
  /// Returns null if [PacketFlags.hasSignature] is not set or data is too short.
  static ({Uint8List unsigned, Uint8List signature})? extractSignature(
      Uint8List data) {
    if (data.length < headerSize + messageIdSize + 64) return null;
    final flags = data[3];
    if ((flags & PacketFlags.hasSignature) == 0) return null;

    final sig = Uint8List.fromList(data.sublist(data.length - 64));
    final unsigned = Uint8List.fromList(data.sublist(0, data.length - 64));
    // Clear hasSignature flag from the unsigned copy
    unsigned[3] = unsigned[3] & ~PacketFlags.hasSignature;
    return (unsigned: unsigned, signature: sig);
  }

  // ==================== Helpers ====================

  static Uint8List _truncatedIdBytes(String hexId) {
    if (hexId.length >= 16) {
      // Already a 16-char hex (8 bytes)
      return _hexToBytes(hexId.substring(0, 16));
    }
    // Pad or hash
    final padded = hexId.padRight(16, '0');
    return _hexToBytes(padded);
  }

  static Uint8List _uuidToBytes(String uuid) {
    final clean = uuid.replaceAll('-', '');
    if (clean.length >= 32) {
      return _hexToBytes(clean.substring(0, 32));
    }
    return _hexToBytes(clean.padRight(32, '0'));
  }

  static String _bytesToUuid(Uint8List bytes) {
    final hex = _bytesToHex(bytes);
    if (hex.length >= 32) {
      return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
          '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
          '${hex.substring(20, 32)}';
    }
    return hex;
  }

  static String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  /// Create a MeshPacket from a legacy JSON message for backward compat
  /// during migration.
  static MeshPacket? fromLegacyJson(Map<String, dynamic> json, String ownUserId) {
    final type = _legacyTypeToPacket(json['type'] as String? ?? 'message');
    final messageId = json['messageId'] as String? ?? json['message_id'] as String? ?? '';
    final senderId = json['sender_id'] as String? ?? ownUserId;
    final destinationId = json['destination_id'] as String? ?? broadcastRecipientId;
    final ttl = json['ttl'] as int? ?? 3;
    final content = json['content'] as String? ?? '';

    return MeshPacket(
      type: type,
      ttl: ttl,
      flags: 0,
      timestamp: DateTime.now(),
      senderId: truncateIdSync(senderId),
      recipientId: destinationId.isEmpty
          ? broadcastRecipientId
          : truncateIdSync(destinationId),
      payload: Uint8List.fromList(utf8.encode(content)),
      messageId: messageId,
    );
  }

  static PacketType _legacyTypeToPacket(String type) {
    switch (type) {
      case 'message':
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
        return PacketType.readReceipt;
      default:
        return PacketType.message;
    }
  }

  @override
  String toString() =>
      'MeshPacket(type=${type.name}, ttl=$ttl, sender=$senderId, '
      'recipient=$recipientId, payload=${payload.length}B, msgId=$messageId)';
}
