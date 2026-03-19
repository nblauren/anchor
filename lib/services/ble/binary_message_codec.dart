import 'dart:convert';
import 'dart:typed_data';

import '../mesh/mesh_packet.dart';
import 'ble_models.dart';

/// Binary wire codec for BLE and LAN message transport.
///
/// Replaces JSON encoding/decoding with [MeshPacket] binary format.
/// Detection: first byte `{` (0x7B) → JSON (legacy), else → binary MeshPacket.
///
/// ## Payload Sub-Formats (per PacketType)
///
/// ### message (plaintext, encrypted flag NOT set)
/// ```
/// [1B] messageType index (MessageType enum)
/// [1B] flags: bit0=hasReplyTo, bit1=hasSenderName, bit2=hasSenderUserId
/// [if hasSenderName: 1B nameLen + N bytes name]
/// [if hasSenderUserId: 1B idLen + N bytes senderUserId]
/// [if hasReplyTo: 1B idLen + N bytes replyToId]
/// [rest] content UTF-8
/// ```
///
/// ### message (encrypted, PacketFlags.encrypted set)
/// ```
/// [1B] messageType index
/// [1B] flags: bit1=hasSenderName, bit2=hasSenderUserId
/// [if hasSenderName: 1B nameLen + N bytes name]
/// [if hasSenderUserId: 1B idLen + N bytes senderUserId]
/// [24B] nonce
/// [rest] ciphertext (encrypted inner: content + replyToId)
/// ```
///
/// ### handshake
/// ```
/// [1B] step (1, 2, or 3)
/// [rest] raw handshake bytes
/// ```
///
/// ### anchorDrop — empty payload (all info in header)
///
/// ### reaction
/// ```
/// [1B] actionLen
/// [N bytes] action string ("add" / "remove")
/// [1B] targetMsgIdLen
/// [N bytes] target message ID
/// [rest] emoji UTF-8
/// ```
///
/// ### readReceipt — payload is the message ID being acknowledged
///
/// ### peerAnnounce / neighborList — JSON in payload (complex nested data)
class BinaryMessageCodec {
  BinaryMessageCodec._();

  // ==================== Detection ====================

  /// Returns true if [data] is a binary MeshPacket (not JSON).
  static bool isBinary(Uint8List data) {
    if (data.isEmpty) return false;
    // JSON always starts with '{' (0x7B).  MeshPacket version byte is 0x01.
    // Binary photo chunks start with 0x03.
    return data[0] != 0x7B;
  }

  // ==================== Chat Message Encoding ====================

  /// Encode a plaintext chat message to binary MeshPacket bytes.
  static Uint8List encodeMessage({
    required String senderId,
    required String messageId,
    required MessageType messageType,
    required String content,
    String? senderName,
    String? replyToId,
    String? destinationUserId,
    int ttl = 3,
    bool meshEnabled = false,
  }) {
    final payload = _encodeChatPayload(
      messageType: messageType,
      content: content,
      senderName: senderName,
      senderUserId: senderId,
      replyToId: replyToId,
      encrypted: false,
    );

    final recipientId = (destinationUserId != null && destinationUserId.isNotEmpty)
        ? MeshPacket.truncateIdSync(destinationUserId)
        : MeshPacket.broadcastRecipientId;

    final packet = MeshPacket(
      type: PacketType.message,
      ttl: meshEnabled ? ttl : 1,
      flags: 0,
      timestamp: DateTime.now(),
      senderId: MeshPacket.truncateIdSync(senderId),
      recipientId: recipientId,
      payload: payload,
      messageId: messageId,
    );

    return packet.serialize();
  }

  /// Encode an encrypted chat message to binary MeshPacket bytes.
  static Uint8List encodeEncryptedMessage({
    required String senderId,
    required String messageId,
    required MessageType messageType,
    required Uint8List nonce,
    required Uint8List ciphertext,
    String? senderName,
    String? destinationUserId,
    int ttl = 3,
    bool meshEnabled = false,
  }) {
    final payload = _encodeEncryptedChatPayload(
      messageType: messageType,
      nonce: nonce,
      ciphertext: ciphertext,
      senderName: senderName,
      senderUserId: senderId,
    );

    final recipientId = (destinationUserId != null && destinationUserId.isNotEmpty)
        ? MeshPacket.truncateIdSync(destinationUserId)
        : MeshPacket.broadcastRecipientId;

    final packet = MeshPacket(
      type: PacketType.message,
      ttl: meshEnabled ? ttl : 1,
      flags: PacketFlags.encrypted,
      timestamp: DateTime.now(),
      senderId: MeshPacket.truncateIdSync(senderId),
      recipientId: recipientId,
      payload: payload,
      messageId: messageId,
    );

    return packet.serialize();
  }

  // ==================== Handshake Encoding ====================

  static Uint8List encodeHandshake({
    required String senderId,
    required int step,
    required Uint8List handshakePayload,
  }) {
    final payload = Uint8List(1 + handshakePayload.length);
    payload[0] = step;
    payload.setRange(1, payload.length, handshakePayload);

    final packet = MeshPacket(
      type: PacketType.handshake,
      ttl: 1,
      flags: 0,
      timestamp: DateTime.now(),
      senderId: MeshPacket.truncateIdSync(senderId),
      recipientId: MeshPacket.broadcastRecipientId,
      payload: payload,
      messageId: '',
    );

    return packet.serialize();
  }

  // ==================== Anchor Drop Encoding ====================

  static Uint8List encodeAnchorDrop({
    required String senderId,
    String? senderName,
    String? destinationUserId,
    int ttl = 3,
    bool meshEnabled = false,
  }) {
    // Payload: optional sender name for display
    final nameBytes = (senderName != null && senderName.isNotEmpty)
        ? utf8.encode(senderName)
        : Uint8List(0);
    final payload = Uint8List(1 + nameBytes.length);
    payload[0] = nameBytes.length;
    if (nameBytes.isNotEmpty) {
      payload.setRange(1, payload.length, nameBytes);
    }

    final recipientId = (destinationUserId != null && destinationUserId.isNotEmpty)
        ? MeshPacket.truncateIdSync(destinationUserId)
        : MeshPacket.broadcastRecipientId;

    final packet = MeshPacket(
      type: PacketType.anchorDrop,
      ttl: meshEnabled ? ttl : 1,
      flags: 0,
      timestamp: DateTime.now(),
      senderId: MeshPacket.truncateIdSync(senderId),
      recipientId: recipientId,
      payload: payload,
      messageId: '',
    );

    return packet.serialize();
  }

  // ==================== Reaction Encoding ====================

  static Uint8List encodeReaction({
    required String senderId,
    required String targetMessageId,
    required String emoji,
    required String action,
    String? senderName,
  }) {
    final actionBytes = utf8.encode(action);
    final msgIdBytes = utf8.encode(targetMessageId);
    final emojiBytes = utf8.encode(emoji);

    final payload = Uint8List(1 + actionBytes.length + 1 + msgIdBytes.length + emojiBytes.length);
    var offset = 0;
    payload[offset++] = actionBytes.length;
    payload.setRange(offset, offset + actionBytes.length, actionBytes);
    offset += actionBytes.length;
    payload[offset++] = msgIdBytes.length;
    payload.setRange(offset, offset + msgIdBytes.length, msgIdBytes);
    offset += msgIdBytes.length;
    payload.setRange(offset, offset + emojiBytes.length, emojiBytes);

    final packet = MeshPacket(
      type: PacketType.reaction,
      ttl: 1,
      flags: 0,
      timestamp: DateTime.now(),
      senderId: MeshPacket.truncateIdSync(senderId),
      recipientId: MeshPacket.broadcastRecipientId,
      payload: payload,
      messageId: '',
    );

    return packet.serialize();
  }

  // ==================== Gossip Sync Encoding ====================

  /// Encode a gossip sync payload (GCS + count) as a binary MeshPacket.
  static Uint8List encodeGossipSync({
    required String senderId,
    required Uint8List gcsBytes,
    required int messageCount,
  }) {
    // Payload: [4B messageCount big-endian] [rest: GCS bytes]
    final payload = Uint8List(4 + gcsBytes.length);
    final bd = ByteData.sublistView(payload);
    bd.setUint32(0, messageCount, Endian.big);
    payload.setRange(4, payload.length, gcsBytes);

    final packet = MeshPacket(
      type: PacketType.gossipSync,
      ttl: 1, // Never relay gossip — peer-to-peer only
      flags: 0,
      timestamp: DateTime.now(),
      senderId: MeshPacket.truncateIdSync(senderId),
      recipientId: MeshPacket.broadcastRecipientId,
      payload: payload,
      messageId: '',
    );

    return packet.serialize();
  }

  /// Encode a gossip request (list of missing hash indices) as a binary MeshPacket.
  ///
  /// [originalN] is the message count of the sender when they built the GCS
  /// that we compared against. The receiver needs this to recompute the
  /// modulus and resolve hash indices back to message IDs.
  static Uint8List encodeGossipRequest({
    required String senderId,
    required String recipientId,
    required List<int> missingIndices,
    required int originalN,
  }) {
    // Payload: [4B originalN] [4B count] [4B × N indices, big-endian]
    final payload = Uint8List(8 + missingIndices.length * 4);
    final bd = ByteData.sublistView(payload);
    bd.setUint32(0, originalN, Endian.big);
    bd.setUint32(4, missingIndices.length, Endian.big);
    for (var i = 0; i < missingIndices.length; i++) {
      bd.setUint32(8 + i * 4, missingIndices[i], Endian.big);
    }

    final packet = MeshPacket(
      type: PacketType.gossipRequest,
      ttl: 1,
      flags: 0,
      timestamp: DateTime.now(),
      senderId: MeshPacket.truncateIdSync(senderId),
      recipientId: MeshPacket.truncateIdSync(recipientId),
      payload: payload,
      messageId: '',
    );

    return packet.serialize();
  }

  /// Decode a gossip sync payload from a MeshPacket.
  static DecodedGossipSync? decodeGossipSyncPayload(MeshPacket packet) {
    if (packet.type != PacketType.gossipSync) return null;
    if (packet.payload.length < 4) return null;
    final bd = ByteData.sublistView(packet.payload);
    final messageCount = bd.getUint32(0, Endian.big);
    final gcsBytes = Uint8List.fromList(packet.payload.sublist(4));
    return DecodedGossipSync(gcsBytes: gcsBytes, messageCount: messageCount);
  }

  /// Decode a gossip request payload from a MeshPacket.
  static DecodedGossipRequest? decodeGossipRequestPayload(MeshPacket packet) {
    if (packet.type != PacketType.gossipRequest) return null;
    if (packet.payload.length < 8) return null;
    final bd = ByteData.sublistView(packet.payload);
    final originalN = bd.getUint32(0, Endian.big);
    final count = bd.getUint32(4, Endian.big);
    if (packet.payload.length < 8 + count * 4) return null;
    final indices = <int>[];
    for (var i = 0; i < count; i++) {
      indices.add(bd.getUint32(8 + i * 4, Endian.big));
    }
    return DecodedGossipRequest(originalN: originalN, missingIndices: indices);
  }

  // ==================== Signing ====================

  /// Sign encoded packet bytes using Ed25519.
  ///
  /// Delegates to [MeshPacket.signSerialized] to append a 64-byte signature
  /// and set the [PacketFlags.hasSignature] flag.
  static Future<Uint8List?> signPacket(
    Uint8List encodedPacket,
    Future<Uint8List?> Function(Uint8List) signFn,
  ) =>
      MeshPacket.signSerialized(encodedPacket, signFn);

  // ==================== Decoding ====================

  /// Decode a binary MeshPacket and return a structured result.
  ///
  /// Returns null if the data is not a valid MeshPacket.
  static DecodedBinaryMessage? decode(Uint8List data) {
    final packet = MeshPacket.deserialize(data);
    if (packet == null) return null;

    return DecodedBinaryMessage(
      packet: packet,
      senderIdTruncated: packet.senderId,
      recipientIdTruncated: packet.recipientId,
    );
  }

  /// Extract chat message fields from a decoded MeshPacket.
  static DecodedChatMessage? decodeChatPayload(MeshPacket packet) {
    if (packet.type != PacketType.message) return null;
    final p = packet.payload;
    if (p.length < 2) return null;

    final messageType = MessageType.values[p[0] < MessageType.values.length ? p[0] : 0];
    final flags = p[1];
    final hasReplyTo = (flags & 0x01) != 0;
    final hasSenderName = (flags & 0x02) != 0;
    final hasSenderUserId = (flags & 0x04) != 0;

    var offset = 2;
    String? senderName;
    if (hasSenderName && offset < p.length) {
      final nameLen = p[offset++];
      if (offset + nameLen <= p.length) {
        senderName = utf8.decode(p.sublist(offset, offset + nameLen));
        offset += nameLen;
      }
    }

    String? senderUserId;
    if (hasSenderUserId && offset < p.length) {
      final idLen = p[offset++];
      if (offset + idLen <= p.length) {
        senderUserId = utf8.decode(p.sublist(offset, offset + idLen));
        offset += idLen;
      }
    }

    if (packet.isEncrypted) {
      // Encrypted: [24B nonce] [rest ciphertext]
      if (offset + 24 > p.length) return null;
      final nonce = Uint8List.fromList(p.sublist(offset, offset + 24));
      offset += 24;
      final ciphertext = Uint8List.fromList(p.sublist(offset));
      return DecodedChatMessage(
        messageType: messageType,
        senderName: senderName,
        senderUserId: senderUserId,
        isEncrypted: true,
        nonce: nonce,
        ciphertext: ciphertext,
      );
    }

    // Plaintext
    String? replyToId;
    if (hasReplyTo && offset < p.length) {
      final idLen = p[offset++];
      if (offset + idLen <= p.length) {
        replyToId = utf8.decode(p.sublist(offset, offset + idLen));
        offset += idLen;
      }
    }
    final content = utf8.decode(p.sublist(offset));
    return DecodedChatMessage(
      messageType: messageType,
      senderName: senderName,
      senderUserId: senderUserId,
      content: content,
      replyToId: replyToId,
      isEncrypted: false,
    );
  }

  /// Extract handshake fields from a decoded MeshPacket.
  static DecodedHandshake? decodeHandshakePayload(MeshPacket packet) {
    if (packet.type != PacketType.handshake) return null;
    if (packet.payload.isEmpty) return null;
    return DecodedHandshake(
      step: packet.payload[0],
      payload: Uint8List.fromList(packet.payload.sublist(1)),
    );
  }

  /// Extract reaction fields from a decoded MeshPacket.
  static DecodedReaction? decodeReactionPayload(MeshPacket packet) {
    if (packet.type != PacketType.reaction) return null;
    final p = packet.payload;
    if (p.isEmpty) return null;

    var offset = 0;
    final actionLen = p[offset++];
    if (offset + actionLen > p.length) return null;
    final action = utf8.decode(p.sublist(offset, offset + actionLen));
    offset += actionLen;

    if (offset >= p.length) return null;
    final msgIdLen = p[offset++];
    if (offset + msgIdLen > p.length) return null;
    final targetMessageId = utf8.decode(p.sublist(offset, offset + msgIdLen));
    offset += msgIdLen;

    final emoji = utf8.decode(p.sublist(offset));
    return DecodedReaction(
      targetMessageId: targetMessageId,
      emoji: emoji,
      action: action,
    );
  }

  // ==================== Internal Payload Builders ====================

  static Uint8List _encodeChatPayload({
    required MessageType messageType,
    required String content,
    String? senderName,
    String? senderUserId,
    String? replyToId,
    required bool encrypted,
  }) {
    final contentBytes = utf8.encode(content);
    final nameBytes = (senderName != null && senderName.isNotEmpty)
        ? utf8.encode(senderName)
        : null;
    final userIdBytes = (senderUserId != null && senderUserId.isNotEmpty)
        ? utf8.encode(senderUserId)
        : null;
    final replyBytes = (replyToId != null && replyToId.isNotEmpty)
        ? utf8.encode(replyToId)
        : null;

    int flags = 0;
    if (replyBytes != null) flags |= 0x01;
    if (nameBytes != null) flags |= 0x02;
    if (userIdBytes != null) flags |= 0x04;

    // Calculate total size
    var size = 2; // messageType + flags
    if (nameBytes != null) size += 1 + nameBytes.length;
    if (userIdBytes != null) size += 1 + userIdBytes.length;
    if (replyBytes != null) size += 1 + replyBytes.length;
    size += contentBytes.length;

    final result = Uint8List(size);
    var offset = 0;
    result[offset++] = messageType.index;
    result[offset++] = flags;
    if (nameBytes != null) {
      result[offset++] = nameBytes.length;
      result.setRange(offset, offset + nameBytes.length, nameBytes);
      offset += nameBytes.length;
    }
    if (userIdBytes != null) {
      result[offset++] = userIdBytes.length;
      result.setRange(offset, offset + userIdBytes.length, userIdBytes);
      offset += userIdBytes.length;
    }
    if (replyBytes != null) {
      result[offset++] = replyBytes.length;
      result.setRange(offset, offset + replyBytes.length, replyBytes);
      offset += replyBytes.length;
    }
    result.setRange(offset, offset + contentBytes.length, contentBytes);

    return result;
  }

  static Uint8List _encodeEncryptedChatPayload({
    required MessageType messageType,
    required Uint8List nonce,
    required Uint8List ciphertext,
    String? senderName,
    String? senderUserId,
  }) {
    final nameBytes = (senderName != null && senderName.isNotEmpty)
        ? utf8.encode(senderName)
        : null;
    final userIdBytes = (senderUserId != null && senderUserId.isNotEmpty)
        ? utf8.encode(senderUserId)
        : null;

    int flags = 0;
    if (nameBytes != null) flags |= 0x02;
    if (userIdBytes != null) flags |= 0x04;

    var size = 2 + 24 + ciphertext.length; // header + nonce + ciphertext
    if (nameBytes != null) size += 1 + nameBytes.length;
    if (userIdBytes != null) size += 1 + userIdBytes.length;

    final result = Uint8List(size);
    var offset = 0;
    result[offset++] = messageType.index;
    result[offset++] = flags;
    if (nameBytes != null) {
      result[offset++] = nameBytes.length;
      result.setRange(offset, offset + nameBytes.length, nameBytes);
      offset += nameBytes.length;
    }
    if (userIdBytes != null) {
      result[offset++] = userIdBytes.length;
      result.setRange(offset, offset + userIdBytes.length, userIdBytes);
      offset += userIdBytes.length;
    }
    result.setRange(offset, offset + 24, nonce);
    offset += 24;
    result.setRange(offset, offset + ciphertext.length, ciphertext);

    return result;
  }
}

// ==================== Decoded Message Types ====================

/// Top-level decoded binary message wrapping a MeshPacket.
class DecodedBinaryMessage {
  const DecodedBinaryMessage({
    required this.packet,
    required this.senderIdTruncated,
    required this.recipientIdTruncated,
  });

  final MeshPacket packet;
  final String senderIdTruncated;
  final String recipientIdTruncated;
}

/// Decoded chat message payload.
class DecodedChatMessage {
  const DecodedChatMessage({
    required this.messageType,
    this.senderName,
    this.senderUserId,
    this.content,
    this.replyToId,
    required this.isEncrypted,
    this.nonce,
    this.ciphertext,
  });

  final MessageType messageType;
  final String? senderName;

  /// Full sender app userId (stable UUID). Equivalent to JSON's `sender_id`.
  /// Used to resolve the canonical peer ID when the BLE Central UUID is unknown.
  final String? senderUserId;
  final String? content;
  final String? replyToId;
  final bool isEncrypted;

  /// Present only when [isEncrypted] is true.
  final Uint8List? nonce;
  final Uint8List? ciphertext;
}

/// Decoded handshake payload.
class DecodedHandshake {
  const DecodedHandshake({
    required this.step,
    required this.payload,
  });

  final int step;
  final Uint8List payload;
}

/// Decoded reaction payload.
class DecodedReaction {
  const DecodedReaction({
    required this.targetMessageId,
    required this.emoji,
    required this.action,
  });

  final String targetMessageId;
  final String emoji;
  final String action;
}

/// Decoded gossip sync payload.
class DecodedGossipSync {
  const DecodedGossipSync({
    required this.gcsBytes,
    required this.messageCount,
  });

  final Uint8List gcsBytes;
  final int messageCount;
}

/// Decoded gossip request payload.
class DecodedGossipRequest {
  const DecodedGossipRequest({
    required this.originalN,
    required this.missingIndices,
  });

  /// The message count of the peer who sent the GCS we compared against.
  /// Needed to recompute modulus = originalN * fpRate for hash resolution.
  final int originalN;
  final List<int> missingIndices;
}
