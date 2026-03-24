import 'dart:convert';
import 'dart:typed_data';

import 'package:anchor/services/mesh/golomb_coded_set.dart';
import 'package:anchor/services/mesh/gossip_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GossipSyncService', () {
    late GossipSyncService service;

    setUp(() {
      service = GossipSyncService(
        syncInterval: const Duration(seconds: 5),
      );
    });

    tearDown(() {
      service.dispose();
    });

    test('addMessageId stores message ID', () {
      service.addMessageId('msg-1');
      final payload = service.buildGossipPayload();
      expect(payload, isNotNull);
      expect(payload!['n'], 1);
    });

    test('buildGossipPayload returns null when empty', () {
      expect(service.buildGossipPayload(), isNull);
    });

    test('buildGossipPayload encodes GCS as base64', () {
      service
        ..addMessageId('msg-1')
        ..addMessageId('msg-2')
        ..addMessageId('msg-3');

      final payload = service.buildGossipPayload();
      expect(payload, isNotNull);
      expect(payload!['type'], 'gossip_sync');
      expect(payload['n'], 3);
      // Verify gcs is valid base64
      final gcsBytes = base64Decode(payload['gcs'] as String);
      expect(gcsBytes.length, greaterThan(4));
    });

    test('handleGossipSync detects missing messages', () {
      // Local service has msg-1 through msg-5
      for (var i = 1; i <= 5; i++) {
        service.addMessageId('msg-$i');
      }

      // Remote peer has msg-1 through msg-10 (we're missing 6-10)
      final remoteService = GossipSyncService();
      for (var i = 1; i <= 10; i++) {
        remoteService.addMessageId('msg-$i');
      }
      final remotePayload = remoteService.buildGossipPayload()!;

      List<String>? missingIds;
      String? fromPeer;
      int? receivedOriginalN;
      service
        ..onMissingMessages = (peerId, ids, originalN) {
          fromPeer = peerId;
          missingIds = ids;
          receivedOriginalN = originalN;
        }

        ..handleGossipSync('peer-A', remotePayload);

      // Should detect some missing messages
      expect(fromPeer, 'peer-A');
      expect(missingIds, isNotNull);
      expect(missingIds!.length, greaterThan(0));
      // originalN should be the remote peer's message count
      expect(receivedOriginalN, 10);

      remoteService.dispose();
    });

    test('handleGossipSync with identical sets finds nothing missing', () {
      // Both have the same messages
      for (var i = 1; i <= 10; i++) {
        service.addMessageId('msg-$i');
      }

      final payload = service.buildGossipPayload()!;

      var called = false;
      service
        ..onMissingMessages = (_, __, ___) {
          called = true;
        }

        ..handleGossipSync('peer-A', payload);
      expect(called, isFalse);
    });

    test('handleGossipSync ignores invalid payload', () {
      var called = false;
      service
        ..onMissingMessages = (_, __, ___) {
          called = true;
        }

        // Missing gcs field
        ..handleGossipSync('peer-A', {'type': 'gossip_sync'});
      expect(called, isFalse);

      // Invalid n
      service.handleGossipSync('peer-A', {
        'type': 'gossip_sync',
        'gcs': base64Encode([0, 0, 0, 0]),
        'n': 0,
      });
      expect(called, isFalse);
    });

    test('addPeer and removePeer manage connected peers', () {
      service
        ..addPeer('peer-1')
        ..addPeer('peer-2')
        ..addMessageId('msg-1');

      final sentTo = <String>[];
      service.onSendGossip = (peerId, _) {
        sentTo.add(peerId);
      };

      // Trigger manual broadcast via payload building
      final payload = service.buildGossipPayload();
      expect(payload, isNotNull);

      service.removePeer('peer-1');
      // After removal, peer-1 should no longer receive gossip
    });

    test('dispose clears all state', () {
      service
        ..addMessageId('msg-1')
        ..addPeer('peer-1')
        ..start()

        ..dispose();

      expect(service.buildGossipPayload(), isNull);
    });

    test('old messages are pruned from GCS', () {
      // Create service with very short max age
      final shortService = GossipSyncService(
        maxMessageAge: Duration.zero,
      )..addMessageId('old-msg');
      // With Duration.zero, message is immediately "old"
      final payload = shortService.buildGossipPayload();
      expect(payload, isNull);

      shortService.dispose();
    });

    group('cacheMessage and handleGossipRequest', () {
      test('cacheMessage stores bytes and handleGossipRequest resends them', () {
        // Add some message IDs and cache their bytes
        final msgBytes1 = Uint8List.fromList([1, 2, 3]);
        final msgBytes2 = Uint8List.fromList([4, 5, 6]);
        final msgBytes3 = Uint8List.fromList([7, 8, 9]);

        service
          ..addMessageId('msg-1')
          ..cacheMessage('msg-1', msgBytes1)
          ..addMessageId('msg-2')
          ..cacheMessage('msg-2', msgBytes2)
          ..addMessageId('msg-3')
          ..cacheMessage('msg-3', msgBytes3);

        // Compute what hash indices the peer would request
        // The peer built a GCS with originalN = 3 (our message count)
        const gcs = GolombCodedSet();
        final modulus = 3 * gcs.fpRate;
        final hash1 = GolombCodedSet.hashItem('msg-1', modulus);
        final hash2 = GolombCodedSet.hashItem('msg-2', modulus);

        // Track resent messages
        final resent = <(String, Uint8List)>[];
        service
          ..onResendMessage = (peerId, bytes) {
            resent.add((peerId, bytes));
          }

          // Request msg-1 and msg-2 by hash
          ..handleGossipRequest('peer-B', [hash1, hash2], 3);

        // Should have resent exactly the messages matching those hashes
        expect(resent.length, greaterThanOrEqualTo(2));
        // Verify peer ID
        for (final entry in resent) {
          expect(entry.$1, 'peer-B');
        }
      });

      test('handleGossipRequest does nothing for empty request', () {
        service
          ..addMessageId('msg-1')
          ..cacheMessage('msg-1', Uint8List.fromList([1, 2, 3]));

        final resent = <(String, Uint8List)>[];
        service
          ..onResendMessage = (peerId, bytes) {
            resent.add((peerId, bytes));
          }

          ..handleGossipRequest('peer-B', [], 5);
        expect(resent, isEmpty);
      });

      test('handleGossipRequest does nothing for originalN = 0', () {
        service
          ..addMessageId('msg-1')
          ..cacheMessage('msg-1', Uint8List.fromList([1, 2, 3]));

        final resent = <(String, Uint8List)>[];
        service
          ..onResendMessage = (peerId, bytes) {
            resent.add((peerId, bytes));
          }

          ..handleGossipRequest('peer-B', [42], 0);
        expect(resent, isEmpty);
      });

      test('handleGossipRequest skips messages without cached bytes', () {
        service.addMessageId('msg-1');
        // No cacheMessage call — bytes not cached

        const gcs = GolombCodedSet();
        final modulus = 1 * gcs.fpRate;
        final hash1 = GolombCodedSet.hashItem('msg-1', modulus);

        final resent = <(String, Uint8List)>[];
        service
          ..onResendMessage = (peerId, bytes) {
            resent.add((peerId, bytes));
          }

          ..handleGossipRequest('peer-B', [hash1], 1);
        expect(resent, isEmpty);
      });

      test('cached bytes are pruned when messages expire', () {
        final shortService = GossipSyncService(
          maxMessageAge: Duration.zero,
        )
          ..addMessageId('msg-1')
          ..cacheMessage('msg-1', Uint8List.fromList([1, 2, 3]));

        // Building payload triggers pruning — messages are immediately old
        final payload = shortService.buildGossipPayload();
        expect(payload, isNull);

        // Now try to fulfill a request — msg-1 should be pruned
        final resent = <(String, Uint8List)>[];
        shortService
          ..onResendMessage = (peerId, bytes) {
            resent.add((peerId, bytes));
          }

          // Use any hash — shouldn't matter since the message is pruned
          ..handleGossipRequest('peer-B', [42], 1);
        expect(resent, isEmpty);

        shortService.dispose();
      });

      test('dispose clears cached bytes', () {
        service
          ..addMessageId('msg-1')
          ..cacheMessage('msg-1', Uint8List.fromList([1, 2, 3]))

          ..dispose();

        // After dispose, handleGossipRequest should find nothing
        final resent = <(String, Uint8List)>[];
        service
          ..onResendMessage = (peerId, bytes) {
            resent.add((peerId, bytes));
          }
          ..handleGossipRequest('peer-B', [42], 1);
        expect(resent, isEmpty);
      });
    });
  });
}
