import 'dart:typed_data';

// ---------------------------------------------------------------------------
// TrafficPadding
//
// Length-prefixed padding to fixed block sizes for traffic analysis resistance.
//
// Without padding, an eavesdropper can fingerprint message types by ciphertext
// size: a 3-char "hey" encrypts to ~95 bytes, a photo preview to ~15 KB, and
// a Noise handshake msg1 to ~65 bytes.  Padding all messages to the nearest
// block boundary makes messages within the same block indistinguishable.
//
// Block sizes: 64, 128, 256, 512, 1024, 2048, 4096 bytes.
// Messages larger than 4094 are padded to the next 4096-byte boundary.
//
// Format: [2-byte big-endian original data length][original data][zero fill]
//
// The 2-byte length prefix supports payloads up to 65535 bytes, which is
// sufficient for all BLE message types (max ~4 KB for photo chunks).
// The zero fill is deterministic and does not leak information.
// ---------------------------------------------------------------------------

class TrafficPadding {
  TrafficPadding._();

  /// 2-byte length prefix overhead.
  static const _headerSize = 2;

  static const _blockSizes = [64, 128, 256, 512, 1024, 2048, 4096];

  /// Pad [data] to the nearest block size.
  ///
  /// Output format: [uint16 BE data.length][data][zero fill to block boundary]
  /// Minimum output size is 64 bytes.
  static Uint8List pad(Uint8List data) {
    if (data.length > 65535) {
      throw ArgumentError('TrafficPadding: data too large '
          '(${data.length} bytes, max 65535)');
    }

    final minSize = data.length + _headerSize;

    // Find smallest block that fits header + data.
    final targetSize = _blockSizes.cast<int?>().firstWhere(
              (size) => size! >= minSize,
              orElse: () => null,
            ) ??
        _nextMultiple(minSize, 4096);

    final padded = Uint8List(targetSize);

    // Write 2-byte big-endian length prefix.
    padded[0] = (data.length >> 8) & 0xFF;
    padded[1] = data.length & 0xFF;

    // Copy original data after the header.
    padded.setRange(_headerSize, _headerSize + data.length, data);

    // Remaining bytes are already zero (Uint8List default).
    return padded;
  }

  /// Remove padding and recover original data.
  ///
  /// Returns null if the header is invalid or the claimed length exceeds
  /// the available data.
  static Uint8List? unpad(Uint8List data) {
    if (data.length < _headerSize) return null;

    // Read 2-byte big-endian original data length.
    final originalLen = (data[0] << 8) | data[1];

    // Validate: claimed length must fit within the padded data (minus header).
    if (originalLen > data.length - _headerSize) return null;

    return data.sublist(_headerSize, _headerSize + originalLen);
  }

  static int _nextMultiple(int value, int multiple) {
    return ((value + multiple - 1) ~/ multiple) * multiple;
  }
}
