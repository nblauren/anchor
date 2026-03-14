import 'dart:typed_data';

import 'package:anchor/services/ble/ble_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ── BroadcastPayload ──────────────────────────────────────────────────────

  group('BroadcastPayload', () {
    test('toJson includes all non-null fields', () {
      final thumb = Uint8List.fromList([1, 2, 3]);
      final payload = BroadcastPayload(
        userId: 'user-1',
        name: 'Alice',
        age: 30,
        bio: 'Hello',
        position: 2,
        interests: '0,3,7',
        thumbnailBytes: thumb,
      );

      final json = payload.toJson();

      expect(json['userId'], 'user-1');
      expect(json['name'], 'Alice');
      expect(json['age'], 30);
      expect(json['bio'], 'Hello');
      expect(json['position'], 2);
      expect(json['interests'], '0,3,7');
      expect(json['thumbnailBytes'], [1, 2, 3]);
    });

    test('toJson omits null position and interests', () {
      final payload = BroadcastPayload(userId: 'u', name: 'Bob');

      final json = payload.toJson();

      expect(json.containsKey('position'), isFalse);
      expect(json.containsKey('interests'), isFalse);
    });

    test('fromJson round-trip preserves all fields', () {
      final thumb = Uint8List.fromList([10, 20, 30]);
      final original = BroadcastPayload(
        userId: 'user-42',
        name: 'Charlie',
        age: 25,
        bio: 'Test bio',
        position: 1,
        interests: '2,5',
        thumbnailBytes: thumb,
      );

      final restored = BroadcastPayload.fromJson(original.toJson());

      expect(restored.userId, original.userId);
      expect(restored.name, original.name);
      expect(restored.age, original.age);
      expect(restored.bio, original.bio);
      expect(restored.position, original.position);
      expect(restored.interests, original.interests);
      expect(restored.thumbnailBytes, orderedEquals(thumb));
    });

    test('fromJson handles absent thumbnail', () {
      final json = {
        'userId': 'u',
        'name': 'Dave',
        'thumbnailBytes': null,
      };
      final payload = BroadcastPayload.fromJson(json);
      expect(payload.thumbnailBytes, isNull);
    });
  });

  // ── DiscoveredPeer distance / signal ─────────────────────────────────────

  group('DiscoveredPeer.distanceEstimate', () {
    DiscoveredPeer peer(int rssi) => DiscoveredPeer(
          peerId: 'p',
          name: 'Test',
          rssi: rssi,
          timestamp: DateTime.now(),
        );

    test('returns null when rssi is null', () {
      final p = DiscoveredPeer(peerId: 'p', name: 'T', timestamp: DateTime.now());
      expect(p.distanceEstimate, isNull);
    });

    test('>= -50 → Very close', () => expect(peer(-40).distanceEstimate, 'Very close'));
    test('>= -60 → Nearby', () => expect(peer(-55).distanceEstimate, 'Nearby'));
    test('>= -70 → In range', () => expect(peer(-65).distanceEstimate, 'In range'));
    test('< -70 → Far away', () => expect(peer(-80).distanceEstimate, 'Far away'));
  });

  group('DiscoveredPeer.signalQuality', () {
    DiscoveredPeer peer(int rssi) => DiscoveredPeer(
          peerId: 'p',
          name: 'T',
          rssi: rssi,
          timestamp: DateTime.now(),
        );

    test('>= -50 → Excellent', () => expect(peer(-45).signalQuality, 'Excellent'));
    test('>= -60 → Good', () => expect(peer(-58).signalQuality, 'Good'));
    test('>= -70 → Fair', () => expect(peer(-68).signalQuality, 'Fair'));
    test('< -70 → Weak', () => expect(peer(-90).signalQuality, 'Weak'));
  });

  group('DiscoveredPeer.copyWith', () {
    test('preserves unchanged fields', () {
      final original = DiscoveredPeer(
        peerId: 'p1',
        name: 'Eve',
        age: 28,
        bio: 'bio',
        rssi: -55,
        timestamp: DateTime(2024, 1, 1),
        isRelayed: false,
        hopCount: 0,
      );

      final copy = original.copyWith(rssi: -70);

      expect(copy.peerId, 'p1');
      expect(copy.name, 'Eve');
      expect(copy.age, 28);
      expect(copy.bio, 'bio');
      expect(copy.rssi, -70); // updated
      expect(copy.hopCount, 0);
      expect(copy.isRelayed, false);
    });

    test('copyWith isRelayed = true', () {
      final original = DiscoveredPeer(
        peerId: 'p2',
        name: 'Frank',
        timestamp: DateTime.now(),
      );
      final relayed = original.copyWith(isRelayed: true, hopCount: 2);
      expect(relayed.isRelayed, isTrue);
      expect(relayed.hopCount, 2);
    });
  });

  // ── ReceivedPhoto ─────────────────────────────────────────────────────────

  group('ReceivedPhoto.formattedSize', () {
    ReceivedPhoto photo(int size) => ReceivedPhoto(
          fromPeerId: 'p',
          messageId: 'm',
          photoBytes: Uint8List(size),
          timestamp: DateTime.now(),
        );

    test('< 1024 → bytes', () => expect(photo(500).formattedSize, '500 B'));
    test('1024–1M → KB', () => expect(photo(2048).formattedSize, '2.0 KB'));
    test('>= 1M → MB', () => expect(photo(1500000).formattedSize, '1.4 MB'));
  });

  // ── ReceivedPhotoPreview.formattedOriginalSize ────────────────────────────

  group('ReceivedPhotoPreview.formattedOriginalSize', () {
    ReceivedPhotoPreview preview(int size) => ReceivedPhotoPreview(
          fromPeerId: 'p',
          messageId: 'm',
          photoId: 'ph',
          thumbnailBytes: Uint8List(10),
          originalSize: size,
          timestamp: DateTime.now(),
        );

    test('< 1024 → bytes', () => expect(preview(512).formattedOriginalSize, '512 B'));
    test('KB range', () => expect(preview(15000).formattedOriginalSize, '14.6 KB'));
    test('MB range', () => expect(preview(2500000).formattedOriginalSize, '2.4 MB'));
  });

  // ── PhotoTransferProgress ─────────────────────────────────────────────────

  group('PhotoTransferProgress', () {
    test('progressPercent rounds to nearest int', () {
      final p = PhotoTransferProgress(
        messageId: 'm',
        peerId: 'p',
        progress: 0.756,
        status: PhotoTransferStatus.inProgress,
      );
      expect(p.progressPercent, 76);
    });

    test('isComplete when status = completed', () {
      final p = PhotoTransferProgress(
        messageId: 'm',
        peerId: 'p',
        progress: 1.0,
        status: PhotoTransferStatus.completed,
      );
      expect(p.isComplete, isTrue);
      expect(p.isFailed, isFalse);
    });

    test('isFailed when status = failed', () {
      final p = PhotoTransferProgress(
        messageId: 'm',
        peerId: 'p',
        progress: 0.0,
        status: PhotoTransferStatus.failed,
        errorMessage: 'BLE write failed',
      );
      expect(p.isFailed, isTrue);
      expect(p.isComplete, isFalse);
    });

    test('copyWith updates fields, preserves rest', () {
      final orig = PhotoTransferProgress(
        messageId: 'msg-1',
        peerId: 'peer-1',
        progress: 0.5,
        status: PhotoTransferStatus.inProgress,
      );
      final updated = orig.copyWith(progress: 1.0, status: PhotoTransferStatus.completed);
      expect(updated.messageId, 'msg-1');
      expect(updated.peerId, 'peer-1');
      expect(updated.progress, 1.0);
      expect(updated.status, PhotoTransferStatus.completed);
    });
  });

  // ── MessagePayload round-trip ─────────────────────────────────────────────

  group('MessagePayload', () {
    test('toJson/fromJson round-trip', () {
      final payload = MessagePayload(
        messageId: 'msg-abc',
        type: MessageType.photoPreview,
        content: '{"photo_id":"xyz","size":1024}',
      );

      final restored = MessagePayload.fromJson(payload.toJson());
      expect(restored.messageId, payload.messageId);
      expect(restored.type, payload.type);
      expect(restored.content, payload.content);
    });

    test('wifiTransferReady round-trip', () {
      final payload = MessagePayload(
        messageId: 'transfer-1',
        type: MessageType.wifiTransferReady,
        content: 'transfer-id-xyz',
      );
      final restored = MessagePayload.fromJson(payload.toJson());
      expect(restored.type, MessageType.wifiTransferReady);
    });
  });
}
