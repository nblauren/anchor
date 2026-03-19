import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:anchor/services/ble/binary_message_codec.dart';
import 'package:anchor/services/ble/ble_models.dart';
import 'package:anchor/services/mesh/mesh_packet.dart';

void main() {
  // Valid UUIDs for tests (MeshPacket._uuidToBytes requires hex-decodable IDs)
  const uuid1 = '550e8400-e29b-41d4-a716-446655440000';
  const uuid2 = '660e8400-e29b-41d4-a716-446655440000';
  const uuid3 = '770e8400-e29b-41d4-a716-446655440000';

  group('BinaryMessageCodec', () {
    group('isBinary', () {
      test('returns false for JSON data starting with {', () {
        final json = Uint8List.fromList(utf8.encode('{"type":"message"}'));
        expect(BinaryMessageCodec.isBinary(json), isFalse);
      });

      test('returns true for binary data starting with version byte', () {
        final binary = Uint8List.fromList([0x01, 0x01, 0x03, 0x00]);
        expect(BinaryMessageCodec.isBinary(binary), isTrue);
      });

      test('returns false for empty data', () {
        expect(BinaryMessageCodec.isBinary(Uint8List(0)), isFalse);
      });

      test('returns true for photo chunk prefix 0x03', () {
        final photo = Uint8List.fromList([0x03, 0x00, 0x01]);
        expect(BinaryMessageCodec.isBinary(photo), isTrue);
      });
    });

    group('plaintext chat message roundtrip', () {
      test('encode and decode basic message', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-abc-123',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Hello world!',
        );

        expect(BinaryMessageCodec.isBinary(encoded), isTrue);

        final decoded = BinaryMessageCodec.decode(encoded);
        expect(decoded, isNotNull);
        expect(decoded!.packet.type, PacketType.message);
        expect(decoded.packet.messageId, contains('550e8400'));

        final chat = BinaryMessageCodec.decodeChatPayload(decoded.packet);
        expect(chat, isNotNull);
        expect(chat!.messageType, MessageType.text);
        expect(chat.content, 'Hello world!');
        expect(chat.isEncrypted, isFalse);
        expect(chat.senderName, isNull);
        expect(chat.replyToId, isNull);
      });

      test('encode and decode with sender name', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-abc-123',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Hi there',
          senderName: 'Alex',
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final chat = BinaryMessageCodec.decodeChatPayload(decoded!.packet);
        expect(chat!.senderName, 'Alex');
        expect(chat.content, 'Hi there');
      });

      test('encode and decode with reply-to', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-abc-123',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Reply content',
          replyToId: uuid2,
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final chat = BinaryMessageCodec.decodeChatPayload(decoded!.packet);
        expect(chat!.replyToId, uuid2);
        expect(chat.content, 'Reply content');
      });

      test('encode and decode with all optional fields', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-abc-123',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Full message',
          senderName: 'Jordan',
          replyToId: uuid3,
          destinationUserId: 'dest-user-456',
          ttl: 5,
          meshEnabled: true,
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        expect(decoded!.packet.ttl, 5);

        final chat = BinaryMessageCodec.decodeChatPayload(decoded.packet);
        expect(chat!.senderName, 'Jordan');
        expect(chat.replyToId, uuid3);
        expect(chat.content, 'Full message');
      });

      test('encode and decode emoji content', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-abc-123',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Hey! \u{1F3F3}\u{FE0F}\u{200D}\u{1F308}\u{2693} How are you?',
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final chat = BinaryMessageCodec.decodeChatPayload(decoded!.packet);
        expect(chat!.content, contains('How are you?'));
      });

      test('encode and decode empty content', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-abc-123',
          messageId: uuid1,
          messageType: MessageType.text,
          content: '',
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final chat = BinaryMessageCodec.decodeChatPayload(decoded!.packet);
        expect(chat!.content, '');
      });
    });

    group('encrypted chat message roundtrip', () {
      test('encode and decode encrypted message', () {
        final nonce = Uint8List(24);
        for (var i = 0; i < 24; i++) {
          nonce[i] = i;
        }
        final ciphertext = Uint8List.fromList(utf8.encode('encrypted-data-here'));

        final encoded = BinaryMessageCodec.encodeEncryptedMessage(
          senderId: 'user-sender-123',
          messageId: uuid2,
          messageType: MessageType.text,
          nonce: nonce,
          ciphertext: ciphertext,
          senderName: 'Sam',
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        expect(decoded, isNotNull);
        expect(decoded!.packet.isEncrypted, isTrue);

        final chat = BinaryMessageCodec.decodeChatPayload(decoded.packet);
        expect(chat, isNotNull);
        expect(chat!.isEncrypted, isTrue);
        expect(chat.senderName, 'Sam');
        expect(chat.nonce, nonce);
        expect(chat.ciphertext, ciphertext);
        expect(chat.content, isNull);
      });

      test('encrypted without sender name', () {
        final nonce = Uint8List(24);
        final ciphertext = Uint8List.fromList([1, 2, 3, 4, 5]);

        final encoded = BinaryMessageCodec.encodeEncryptedMessage(
          senderId: 'user-xyz-456',
          messageId: uuid1,
          messageType: MessageType.photo,
          nonce: nonce,
          ciphertext: ciphertext,
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final chat = BinaryMessageCodec.decodeChatPayload(decoded!.packet);
        expect(chat!.isEncrypted, isTrue);
        expect(chat.senderName, isNull);
        expect(chat.messageType, MessageType.photo);
      });
    });

    group('handshake roundtrip', () {
      test('encode and decode handshake', () {
        final hsPayload = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02]);

        final encoded = BinaryMessageCodec.encodeHandshake(
          senderId: 'user-initiator-abc',
          step: 1,
          handshakePayload: hsPayload,
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        expect(decoded, isNotNull);
        expect(decoded!.packet.type, PacketType.handshake);

        final hs = BinaryMessageCodec.decodeHandshakePayload(decoded.packet);
        expect(hs, isNotNull);
        expect(hs!.step, 1);
        expect(hs.payload, hsPayload);
      });

      test('handshake steps 1, 2, 3', () {
        for (final step in [1, 2, 3]) {
          final payload = Uint8List.fromList(List.generate(32, (i) => i + step));
          final encoded = BinaryMessageCodec.encodeHandshake(
            senderId: 'user-hs-test',
            step: step,
            handshakePayload: payload,
          );

          final decoded = BinaryMessageCodec.decode(encoded);
          final hs = BinaryMessageCodec.decodeHandshakePayload(decoded!.packet);
          expect(hs!.step, step);
          expect(hs.payload, payload);
        }
      });
    });

    group('anchor drop roundtrip', () {
      test('encode and decode anchor drop', () {
        final encoded = BinaryMessageCodec.encodeAnchorDrop(
          senderId: 'user-anchor-abc',
          senderName: 'Riley',
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        expect(decoded, isNotNull);
        expect(decoded!.packet.type, PacketType.anchorDrop);
      });

      test('anchor drop with mesh routing', () {
        final encoded = BinaryMessageCodec.encodeAnchorDrop(
          senderId: 'user-anchor-abc',
          destinationUserId: 'dest-user-xyz',
          ttl: 4,
          meshEnabled: true,
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        expect(decoded!.packet.ttl, 4);
      });
    });

    group('reaction roundtrip', () {
      test('encode and decode reaction', () {
        final encoded = BinaryMessageCodec.encodeReaction(
          senderId: 'user-reactor-abc',
          targetMessageId: uuid1,
          emoji: '\u{2764}\u{FE0F}',
          action: 'add',
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        expect(decoded, isNotNull);
        expect(decoded!.packet.type, PacketType.reaction);

        final reaction = BinaryMessageCodec.decodeReactionPayload(decoded.packet);
        expect(reaction, isNotNull);
        expect(reaction!.targetMessageId, uuid1);
        expect(reaction.emoji, '\u{2764}\u{FE0F}');
        expect(reaction.action, 'add');
      });

      test('reaction remove action', () {
        final encoded = BinaryMessageCodec.encodeReaction(
          senderId: 'user-reactor-abc',
          targetMessageId: uuid2,
          emoji: '\u{1F525}',
          action: 'remove',
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final reaction = BinaryMessageCodec.decodeReactionPayload(decoded!.packet);
        expect(reaction!.action, 'remove');
        expect(reaction.emoji, '\u{1F525}');
      });
    });

    group('size comparison with JSON', () {
      test('binary message is significantly smaller than JSON', () {
        const senderId = 'b13a7445-1234-5678-9abc-def012345678';
        const messageId = '550e8400-e29b-41d4-a716-446655440000';

        final binary = BinaryMessageCodec.encodeMessage(
          senderId: senderId,
          messageId: messageId,
          messageType: MessageType.text,
          content: 'hello',
        );

        final jsonStr = jsonEncode({
          'type': 'message',
          'sender_id': senderId,
          'message_type': 0,
          'message_id': messageId,
          'content': 'hello',
          'timestamp': DateTime.now().toIso8601String(),
        });
        final jsonBytes = utf8.encode(jsonStr);

        expect(binary.length, lessThan(jsonBytes.length),
            reason: 'Binary ${binary.length}B should be smaller than JSON ${jsonBytes.length}B');
      });
    });

    group('edge cases', () {
      test('decode returns null for too-short data', () {
        final short = Uint8List.fromList([0x01, 0x01]);
        expect(BinaryMessageCodec.decode(short), isNull);
      });

      test('decodeChatPayload returns null for wrong packet type', () {
        final encoded = BinaryMessageCodec.encodeHandshake(
          senderId: 'user-test-abc',
          step: 1,
          handshakePayload: Uint8List.fromList([1, 2, 3]),
        );
        final decoded = BinaryMessageCodec.decode(encoded);
        expect(BinaryMessageCodec.decodeChatPayload(decoded!.packet), isNull);
      });

      test('decodeHandshakePayload returns null for wrong packet type', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-test-abc',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'hi',
        );
        final decoded = BinaryMessageCodec.decode(encoded);
        expect(BinaryMessageCodec.decodeHandshakePayload(decoded!.packet), isNull);
      });

      test('long content (max BLE MTU scenario)', () {
        final longContent = 'A' * 500;
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-test-long',
          messageId: uuid1,
          messageType: MessageType.text,
          content: longContent,
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final chat = BinaryMessageCodec.decodeChatPayload(decoded!.packet);
        expect(chat!.content, longContent);
      });

      test('sender name with unicode', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-test-unicode',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'test',
          senderName: '\u{65E5}\u{672C}\u{8A9E}\u{540D}\u{524D}',
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final chat = BinaryMessageCodec.decodeChatPayload(decoded!.packet);
        expect(chat!.senderName, '\u{65E5}\u{672C}\u{8A9E}\u{540D}\u{524D}');
      });
    });

    group('Ed25519 packet signing', () {
      test('signPacket appends 64 bytes and sets hasSignature flag', () async {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-sign-test',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Signed message',
        );

        // Verify hasSignature is NOT set before signing
        expect(encoded[3] & PacketFlags.hasSignature, 0);

        // Mock sign function: returns 64 bytes of 0xAA
        final fakeSig = Uint8List(64)..fillRange(0, 64, 0xAA);
        final signed = await BinaryMessageCodec.signPacket(
          encoded,
          (_) async => fakeSig,
        );

        expect(signed, isNotNull);
        expect(signed!.length, encoded.length + 64);
        // hasSignature flag must be set
        expect(signed[3] & PacketFlags.hasSignature, PacketFlags.hasSignature);
        // Last 64 bytes must be the signature
        expect(signed.sublist(signed.length - 64), fakeSig);
      });

      test('signPacket returns null when sign function returns null', () async {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-sign-null',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Test',
        );

        final signed = await BinaryMessageCodec.signPacket(
          encoded,
          (_) async => null,
        );

        expect(signed, isNull);
      });

      test('signPacket returns null when sign function returns wrong length',
          () async {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-sign-bad',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Test',
        );

        final signed = await BinaryMessageCodec.signPacket(
          encoded,
          (_) async => Uint8List(32), // Wrong length, should be 64
        );

        expect(signed, isNull);
      });

      test('signed packet can be deserialized with signature preserved',
          () async {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-deser-sig',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Hello signed',
        );

        final fakeSig = Uint8List(64);
        for (var i = 0; i < 64; i++) {
          fakeSig[i] = i;
        }

        final signed = await MeshPacket.signSerialized(
          encoded,
          (_) async => fakeSig,
        );

        expect(signed, isNotNull);

        final packet = MeshPacket.deserialize(signed!);
        expect(packet, isNotNull);
        expect(packet!.signature, isNotNull);
        expect(packet.signature!.length, 64);
        expect(packet.signature, fakeSig);
        // hasSignature should be stripped from flags
        expect(packet.flags & PacketFlags.hasSignature, 0);

        // Payload should still decode correctly
        final chat = BinaryMessageCodec.decodeChatPayload(packet);
        expect(chat, isNotNull);
        expect(chat!.content, 'Hello signed');
      });

      test('unsigned packet deserializes with null signature', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-no-sig',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'No signature',
        );

        final packet = MeshPacket.deserialize(encoded);
        expect(packet, isNotNull);
        expect(packet!.signature, isNull);
      });

      test('extractSignature round-trips with signSerialized', () async {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-extract-test',
          messageId: uuid2,
          messageType: MessageType.text,
          content: 'Extract test',
        );

        final fakeSig = Uint8List(64);
        for (var i = 0; i < 64; i++) {
          fakeSig[i] = 0xBB;
        }

        final signed = await MeshPacket.signSerialized(
          encoded,
          (_) async => fakeSig,
        );
        expect(signed, isNotNull);

        final parts = MeshPacket.extractSignature(signed!);
        expect(parts, isNotNull);
        expect(parts!.signature, fakeSig);
        // The unsigned bytes should match the original (hasSignature cleared)
        expect(parts.unsigned.length, encoded.length);
        // The unsigned bytes should NOT have hasSignature set
        expect(parts.unsigned[3] & PacketFlags.hasSignature, 0);
      });

      test('extractSignature returns null for unsigned data', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-no-extract',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'Not signed',
        );

        final parts = MeshPacket.extractSignature(encoded);
        expect(parts, isNull);
      });

      test('extractSignature returns null for too-short data', () {
        final tooShort = Uint8List(30); // Less than header + messageId + 64
        final parts = MeshPacket.extractSignature(tooShort);
        expect(parts, isNull);
      });
    });

    group('gossip request roundtrip', () {
      test('encode and decode gossip request with originalN', () {
        final encoded = BinaryMessageCodec.encodeGossipRequest(
          senderId: uuid1,
          recipientId: uuid2,
          missingIndices: [10, 42, 999],
          originalN: 50,
        );

        expect(BinaryMessageCodec.isBinary(encoded), isTrue);

        final decoded = BinaryMessageCodec.decode(encoded);
        expect(decoded, isNotNull);
        expect(decoded!.packet.type, PacketType.gossipRequest);

        final req = BinaryMessageCodec.decodeGossipRequestPayload(decoded.packet);
        expect(req, isNotNull);
        expect(req!.originalN, 50);
        expect(req.missingIndices, [10, 42, 999]);
      });

      test('gossip request with empty indices', () {
        final encoded = BinaryMessageCodec.encodeGossipRequest(
          senderId: uuid1,
          recipientId: uuid2,
          missingIndices: [],
          originalN: 10,
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final req = BinaryMessageCodec.decodeGossipRequestPayload(decoded!.packet);
        expect(req, isNotNull);
        expect(req!.originalN, 10);
        expect(req.missingIndices, isEmpty);
      });

      test('gossip request with large originalN', () {
        final encoded = BinaryMessageCodec.encodeGossipRequest(
          senderId: uuid1,
          recipientId: uuid2,
          missingIndices: [1, 2, 3],
          originalN: 100000,
        );

        final decoded = BinaryMessageCodec.decode(encoded);
        final req = BinaryMessageCodec.decodeGossipRequestPayload(decoded!.packet);
        expect(req, isNotNull);
        expect(req!.originalN, 100000);
        expect(req.missingIndices.length, 3);
      });

      test('decodeGossipRequestPayload returns null for too-short payload', () {
        // Create a gossip request packet with a truncated payload
        final packet = MeshPacket(
          type: PacketType.gossipRequest,
          ttl: 1,
          flags: 0,
          timestamp: DateTime.now(),
          senderId: MeshPacket.truncateIdSync(uuid1),
          recipientId: MeshPacket.truncateIdSync(uuid2),
          payload: Uint8List.fromList([0, 0, 0]), // Only 3 bytes, need at least 8
          messageId: '',
        );
        expect(BinaryMessageCodec.decodeGossipRequestPayload(packet), isNull);
      });

      test('decodeGossipRequestPayload returns null for wrong packet type', () {
        final encoded = BinaryMessageCodec.encodeMessage(
          senderId: 'user-test-abc',
          messageId: uuid1,
          messageType: MessageType.text,
          content: 'hi',
        );
        final decoded = BinaryMessageCodec.decode(encoded);
        expect(BinaryMessageCodec.decodeGossipRequestPayload(decoded!.packet), isNull);
      });
    });
  });
}
