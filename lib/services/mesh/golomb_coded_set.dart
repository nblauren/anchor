import 'dart:typed_data';

/// A Golomb-Coded Set (GCS) — a space-efficient compressed representation of
/// a set of items, used for gossip-based message sync.
///
/// ## How it works
///
/// 1. Each item is hashed to a value in [0, N*P) where N = number of items
///    and P = false-positive rate parameter (larger P = lower FP rate).
/// 2. Hashed values are sorted and delta-encoded (store gaps between values).
/// 3. Each gap is Golomb-Rice coded: quotient in unary + remainder in binary.
///
/// ## Why GCS over Bloom filters for gossip sync?
///
/// - **Smaller**: GCS is ~1.5x more compact than Bloom filters at the same FPP.
/// - **Decodable**: Unlike Bloom filters, a GCS can be decoded back into the
///   set of hashed values — enabling set difference (reconciliation).
/// - **One-shot**: Built once, transmitted, then discarded. No incremental inserts.
///
/// ## Usage in Anchor
///
/// During gossip sync, a peer encodes its recent message IDs into a GCS and
/// sends it to a neighbor. The neighbor decodes the GCS, computes the set
/// difference against its own message IDs, and requests the missing messages.
///
/// ## Parameters
///
/// - [fpRate] controls the false-positive probability: `1/fpRate`.
///   Default 19 gives ~5.3% FPP, matching Bitchat's choice.
///   Higher values give lower FPP but larger encoding.
class GolombCodedSet {
  /// False-positive rate parameter. FPP ≈ 1/fpRate.
  final int fpRate;

  /// Default FP parameter — matches Bitchat's SipHash/GCS implementation.
  static const defaultFpRate = 19;

  const GolombCodedSet({this.fpRate = defaultFpRate});

  /// Encode a set of items into a GCS byte array.
  ///
  /// Returns the compressed GCS bytes. The encoding format is:
  /// - 4 bytes: N (number of items, big-endian uint32)
  /// - Remaining: Golomb-Rice coded sorted deltas
  Uint8List encode(List<String> items) {
    if (items.isEmpty) {
      return Uint8List(4); // N = 0
    }

    final n = items.length;
    final modulus = n * fpRate;

    // Hash items to [0, modulus) and sort
    final hashes = items.map((item) => _hash(item, modulus)).toList()..sort();

    // Delta-encode
    final deltas = <int>[hashes[0]];
    for (var i = 1; i < hashes.length; i++) {
      deltas.add(hashes[i] - hashes[i - 1]);
    }

    // Golomb-Rice encode deltas
    // Write N as 4-byte big-endian header
    final writer = _BitWriter()
      ..writeBytes([
        (n >> 24) & 0xFF,
        (n >> 16) & 0xFF,
        (n >> 8) & 0xFF,
        n & 0xFF,
      ]);

    for (final delta in deltas) {
      _golombRiceEncode(writer, delta, fpRate);
    }

    return writer.toBytes();
  }

  /// Decode a GCS byte array back into sorted hash values.
  ///
  /// Returns the sorted list of hash values (not the original items — those
  /// are not recoverable, but the hashes can be compared for set difference).
  List<int> decode(Uint8List data) {
    if (data.length < 4) return [];

    final n = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
    if (n == 0) return [];

    final reader = _BitReader(data, 32); // skip 4-byte header

    final hashes = <int>[];
    var running = 0;
    for (var i = 0; i < n; i++) {
      final delta = _golombRiceDecode(reader, fpRate);
      running += delta;
      hashes.add(running);
    }

    return hashes;
  }

  /// Hash a set of items and return sorted hash values (for local comparison).
  List<int> hashItems(List<String> items) {
    if (items.isEmpty) return [];
    final modulus = items.length * fpRate;
    return items.map((item) => _hash(item, modulus)).toList()..sort();
  }

  /// Compute the set difference: items in [remoteHashes] not in [localHashes].
  ///
  /// Both lists must be sorted. Returns indices into [remoteHashes] of items
  /// not found in [localHashes]. Due to GCS's FPP, some "missing" items may
  /// actually be present (false negatives in the diff are impossible; false
  /// positives in the diff mean we might request an already-held message,
  /// which is harmless).
  static List<int> setDifference(List<int> remoteHashes, List<int> localHashes) {
    final missing = <int>[];
    var li = 0;

    for (var ri = 0; ri < remoteHashes.length; ri++) {
      final rh = remoteHashes[ri];
      // Advance local pointer past hashes smaller than remote
      while (li < localHashes.length && localHashes[li] < rh) {
        li++;
      }
      // If no match, this remote hash is missing locally
      if (li >= localHashes.length || localHashes[li] != rh) {
        missing.add(ri);
      }
    }

    return missing;
  }

  // ==================== Internal ====================

  /// Hash a single item against a given modulus. Exposed for testing and
  /// for receivers to re-hash their own items using the sender's modulus.
  static int hashItem(String item, int modulus) => _hash(item, modulus);

  /// SipHash-inspired hash function mapping an item to [0, modulus).
  /// Uses FNV-1a for simplicity (no crypto dependency); collision resistance
  /// isn't critical here since we're just building a probabilistic set.
  static int _hash(String item, int modulus) {
    if (modulus <= 0) return 0;
    var hash = 0x811c9dc5;
    for (var i = 0; i < item.length; i++) {
      hash ^= item.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    // Map to [0, modulus) using modular arithmetic
    return (hash & 0x7FFFFFFF) % modulus;
  }

  /// Golomb-Rice encode: quotient in unary, remainder in log2(P) bits.
  static void _golombRiceEncode(_BitWriter writer, int value, int p) {
    final q = value ~/ p;
    final r = value % p;
    final log2P = _log2(p);

    // Unary encoding of quotient: q ones followed by a zero
    for (var i = 0; i < q; i++) {
      writer.writeBit(1);
    }
    writer.writeBit(0);

    // Binary encoding of remainder in log2P bits
    for (var i = log2P - 1; i >= 0; i--) {
      writer.writeBit((r >> i) & 1);
    }
  }

  /// Golomb-Rice decode.
  static int _golombRiceDecode(_BitReader reader, int p) {
    final log2P = _log2(p);

    // Read unary quotient
    var q = 0;
    while (reader.readBit() == 1) {
      q++;
    }

    // Read binary remainder
    var r = 0;
    for (var i = 0; i < log2P; i++) {
      r = (r << 1) | reader.readBit();
    }

    return q * p + r;
  }

  /// Ceiling of log2 for Golomb-Rice remainder bit count.
  static int _log2(int value) {
    if (value <= 1) return 1;
    var bits = 0;
    var v = value - 1;
    while (v > 0) {
      bits++;
      v >>= 1;
    }
    return bits;
  }
}

/// Bitwise writer for Golomb-Rice encoding.
class _BitWriter {
  final List<int> _bytes = [];
  int _currentByte = 0;
  int _bitIndex = 7; // MSB first

  void writeBit(int bit) {
    if (bit != 0) {
      _currentByte |= 1 << _bitIndex;
    }
    _bitIndex--;
    if (_bitIndex < 0) {
      _bytes.add(_currentByte);
      _currentByte = 0;
      _bitIndex = 7;
    }
  }

  void writeBytes(List<int> bytes) {
    // Flush current partial byte first
    if (_bitIndex != 7) {
      _bytes.add(_currentByte);
      _currentByte = 0;
      _bitIndex = 7;
    }
    _bytes.addAll(bytes);
  }

  Uint8List toBytes() {
    final result = List<int>.from(_bytes);
    if (_bitIndex != 7) {
      result.add(_currentByte); // flush partial byte
    }
    return Uint8List.fromList(result);
  }
}

/// Bitwise reader for Golomb-Rice decoding.
class _BitReader {
  final Uint8List _data;
  int _bitOffset;

  _BitReader(this._data, this._bitOffset);

  int readBit() {
    final byteIndex = _bitOffset ~/ 8;
    final bitIndex = 7 - (_bitOffset % 8); // MSB first
    if (byteIndex >= _data.length) return 0;
    _bitOffset++;
    return (_data[byteIndex] >> bitIndex) & 1;
  }
}
