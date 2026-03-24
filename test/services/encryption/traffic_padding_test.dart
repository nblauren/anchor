import 'dart:typed_data';

import 'package:anchor/services/encryption/traffic_padding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TrafficPadding', () {
    group('pad', () {
      test('pads empty input to 64 bytes', () {
        final padded = TrafficPadding.pad(Uint8List(0));
        expect(padded.length, 64);
        // First 2 bytes = length prefix (0x00, 0x00).
        expect(padded[0], 0);
        expect(padded[1], 0);
      });

      test('pads 1-byte input to 64 bytes', () {
        final data = Uint8List.fromList([0xAB]);
        final padded = TrafficPadding.pad(data);
        expect(padded.length, 64);
        // Length prefix = 0x00 0x01.
        expect(padded[0], 0);
        expect(padded[1], 1);
        // Data byte at offset 2.
        expect(padded[2], 0xAB);
      });

      test('pads 62-byte input to 64 bytes (header + data = 64 exactly)', () {
        final data = Uint8List(62)..fillRange(0, 62, 0xCC);
        final padded = TrafficPadding.pad(data);
        expect(padded.length, 64);
      });

      test('pads 63-byte input to 128 bytes (header + data = 65 > 64)', () {
        final data = Uint8List(63)..fillRange(0, 63, 0xDD);
        final padded = TrafficPadding.pad(data);
        expect(padded.length, 128);
      });

      test('pads to correct block sizes', () {
        // Expected: smallest block ≥ data.length + 2 (header).
        final cases = <int, int>{
          0: 64, // 0 + 2 = 2 → 64
          1: 64, // 1 + 2 = 3 → 64
          62: 64, // 62 + 2 = 64 → 64
          63: 128, // 63 + 2 = 65 → 128
          126: 128, // 126 + 2 = 128 → 128
          127: 256, // 127 + 2 = 129 → 256
          254: 256, // 254 + 2 = 256 → 256
          255: 512, // 255 + 2 = 257 → 512
          510: 512, // 510 + 2 = 512 → 512
          511: 1024, // 511 + 2 = 513 → 1024
          1022: 1024,
          1023: 2048,
          2046: 2048,
          2047: 4096,
          4094: 4096,
          4095: 8192, // 4095 + 2 = 4097 → next 4096 multiple = 8192
        };

        for (final entry in cases.entries) {
          final data = Uint8List(entry.key);
          final padded = TrafficPadding.pad(data);
          expect(padded.length, entry.value,
              reason: 'Input size ${entry.key} should pad to ${entry.value}',);
        }
      });

      test('pads data > 4094 to next 4096-byte boundary', () {
        final data = Uint8List(5000);
        final padded = TrafficPadding.pad(data);
        // 5000 + 2 = 5002, next 4096 multiple = 8192.
        expect(padded.length, 8192);
      });

      test('messages of similar size pad to same block', () {
        // "hey" (3 bytes) and "hello there" (11 bytes) both pad to 64.
        final a = TrafficPadding.pad(Uint8List.fromList([1, 2, 3]));
        final b = TrafficPadding.pad(
            Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]),);
        expect(a.length, b.length);
        expect(a.length, 64);
      });

      test('throws for data > 65535 bytes', () {
        expect(
          () => TrafficPadding.pad(Uint8List(65536)),
          throwsArgumentError,
        );
      });
    });

    group('unpad', () {
      test('returns null for empty input', () {
        expect(TrafficPadding.unpad(Uint8List(0)), isNull);
      });

      test('returns null for 1-byte input (incomplete header)', () {
        expect(TrafficPadding.unpad(Uint8List.fromList([0x01])), isNull);
      });

      test('returns null if claimed length exceeds available data', () {
        // Header says 100 bytes but only 10 bytes available after header.
        final data = Uint8List(12);
        data[0] = 0;
        data[1] = 100; // Claims 100 bytes.
        expect(TrafficPadding.unpad(data), isNull);
      });

      test('returns empty data when length prefix is zero', () {
        final data = Uint8List(64); // All zeros, header = 0x0000.
        final result = TrafficPadding.unpad(data);
        expect(result, isNotNull);
        expect(result!.length, 0);
      });
    });

    group('round-trip', () {
      test('pad then unpad recovers original data for various sizes', () {
        for (final size in [
          0, 1, 2, 10, 32, 61, 62, 63, 64, 100, 126, 127, 128, 200, 254,
          255, 256, 500, 510, 511, 512, 1000, 1022, 1023, 1024, 2000, 2046,
          2047, 2048, 3000, 4000, 4094, 4095, 4096, 5000,
        ]) {
          final data = Uint8List(size);
          for (var i = 0; i < size; i++) {
            data[i] = i % 256;
          }

          final padded = TrafficPadding.pad(data);
          expect(padded.length, greaterThanOrEqualTo(size + 2),
              reason: 'Padded size must be >= original + header for size $size',);

          final recovered = TrafficPadding.unpad(padded);
          expect(recovered, isNotNull,
              reason: 'Unpad should succeed for size $size',);
          expect(recovered!.length, size,
              reason: 'Recovered length must match original for size $size',);
          expect(recovered, equals(data),
              reason: 'Recovered data must match original for size $size',);
        }
      });

      test('padding preserves original data bytes exactly', () {
        final data = Uint8List.fromList(
            List.generate(100, (i) => (i * 7 + 13) % 256),);
        final padded = TrafficPadding.pad(data);
        // Data starts at offset 2 (after 2-byte header).
        expect(padded.sublist(2, 102), equals(data));
      });
    });

    group('security properties', () {
      test('padded output is always a standard block size for small inputs', () {
        const blockSizes = {64, 128, 256, 512, 1024, 2048, 4096};
        // Test all sizes from 0 to 4094 (max that fits in a standard block).
        for (var size = 0; size <= 4094; size++) {
          final padded = TrafficPadding.pad(Uint8List(size));
          expect(blockSizes.contains(padded.length), isTrue,
              reason:
                  'Padded size ${padded.length} for input $size is not a standard block',);
        }
      });

      test('padded output for large inputs is a multiple of 4096', () {
        for (final size in [4095, 4096, 5000, 8000, 10000]) {
          final padded = TrafficPadding.pad(Uint8List(size));
          expect(padded.length % 4096, 0,
              reason: 'Padded size ${padded.length} for input $size '
                  'should be a multiple of 4096',);
        }
      });

      test('length prefix encodes correctly for large data', () {
        final data = Uint8List(1000);
        final padded = TrafficPadding.pad(data);
        // 1000 = 0x03E8 big-endian.
        expect(padded[0], 0x03);
        expect(padded[1], 0xE8);
      });

      test('zero fill does not leak original data', () {
        final data = Uint8List(10)..fillRange(0, 10, 0xFF);
        final padded = TrafficPadding.pad(data);
        // Bytes after data (offset 12 to end) should be zero.
        for (var i = 12; i < padded.length; i++) {
          expect(padded[i], 0,
              reason: 'Byte at offset $i should be zero fill',);
        }
      });
    });
  });
}
