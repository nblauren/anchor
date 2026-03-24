import 'dart:typed_data';

import 'package:anchor/services/mesh/golomb_coded_set.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gcs = GolombCodedSet();

  group('GolombCodedSet', () {
    test('encode empty set produces 4-byte header with N=0', () {
      final encoded = gcs.encode([]);
      expect(encoded.length, 4);
      expect(encoded[0], 0);
      expect(encoded[1], 0);
      expect(encoded[2], 0);
      expect(encoded[3], 0);
    });

    test('decode empty set returns empty list', () {
      final encoded = gcs.encode([]);
      final decoded = gcs.decode(encoded);
      expect(decoded, isEmpty);
    });

    test('encode/decode single item round-trips', () {
      final items = ['hello'];
      final encoded = gcs.encode(items);
      final decoded = gcs.decode(encoded);
      final hashes = gcs.hashItems(items);
      expect(decoded, hashes);
    });

    test('encode/decode multiple items round-trips', () {
      final items = ['msg-001', 'msg-002', 'msg-003', 'msg-004', 'msg-005'];
      final encoded = gcs.encode(items);
      final decoded = gcs.decode(encoded);
      final hashes = gcs.hashItems(items);
      expect(decoded, hashes);
    });

    test('encode/decode 100 items round-trips', () {
      final items = List.generate(100, (i) => 'message-id-$i');
      final encoded = gcs.encode(items);
      final decoded = gcs.decode(encoded);
      final hashes = gcs.hashItems(items);
      expect(decoded, hashes);
    });

    test('GCS is more compact than raw UUID storage', () {
      final items = List.generate(100, (i) => 'uuid-$i-abcdef-123456');
      final encoded = gcs.encode(items);
      // 100 UUIDs × ~30 chars = ~3000 bytes raw
      // GCS should be much smaller
      expect(encoded.length, lessThan(500));
    });

    test('header correctly encodes N', () {
      final items = List.generate(300, (i) => 'item-$i');
      final encoded = gcs.encode(items);
      final n = (encoded[0] << 24) |
          (encoded[1] << 16) |
          (encoded[2] << 8) |
          encoded[3];
      expect(n, 300);
    });

    test('setDifference finds items in remote not in local', () {
      final remote = [5, 10, 15, 20, 25];
      final local = [5, 15, 25];
      final missing = GolombCodedSet.setDifference(remote, local);
      // Indices 1 (10), 3 (20) are missing from local
      expect(missing, [1, 3]);
    });

    test('setDifference with identical sets returns empty', () {
      final hashes = [5, 10, 15, 20];
      final missing = GolombCodedSet.setDifference(hashes, hashes);
      expect(missing, isEmpty);
    });

    test('setDifference with empty local returns all remote indices', () {
      final remote = [5, 10, 15];
      final missing = GolombCodedSet.setDifference(remote, []);
      expect(missing, [0, 1, 2]);
    });

    test('setDifference with empty remote returns empty', () {
      final missing = GolombCodedSet.setDifference([], [5, 10, 15]);
      expect(missing, isEmpty);
    });

    test('hashItems returns sorted list', () {
      final items = ['z-item', 'a-item', 'm-item'];
      final hashes = gcs.hashItems(items);
      for (var i = 1; i < hashes.length; i++) {
        expect(hashes[i], greaterThanOrEqualTo(hashes[i - 1]));
      }
    });

    test('practical gossip sync: receiver finds missing messages', () {
      // Peer A has messages 1-50
      final peerAMessages = List.generate(50, (i) => 'msg-${i + 1}');
      // Peer B has messages 1-40 (missing 41-50)
      final peerBMessages = List.generate(40, (i) => 'msg-${i + 1}');

      // Peer A encodes its message set
      final encoded = gcs.encode(peerAMessages);

      // Peer B decodes and compares using sender's N for modulus
      final remoteHashes = gcs.decode(encoded);
      final remoteN = peerAMessages.length;
      final modulus = remoteN * gcs.fpRate;

      // Peer B re-hashes its own items with the same modulus
      final localHashes = peerBMessages
          .map((item) => GolombCodedSet.hashItem(item, modulus))
          .toList()
        ..sort();

      final missing =
          GolombCodedSet.setDifference(remoteHashes, localHashes);
      // Should find ~10 missing items (allow for hash collisions)
      expect(missing.length, greaterThanOrEqualTo(8));
      expect(missing.length, lessThanOrEqualTo(12));
    });

    test('custom fpRate produces valid output', () {
      const customGcs = GolombCodedSet(fpRate: 10);
      final items = ['a', 'b', 'c', 'd', 'e'];
      final encoded = customGcs.encode(items);
      final decoded = customGcs.decode(encoded);
      final hashes = customGcs.hashItems(items);
      expect(decoded, hashes);
    });

    test('decode with insufficient data returns empty', () {
      expect(gcs.decode(Uint8List(2)), isEmpty);
      expect(gcs.decode(Uint8List(0)), isEmpty);
    });
  });
}
