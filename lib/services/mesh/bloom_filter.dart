import 'dart:math';
import 'dart:typed_data';

/// A space-efficient probabilistic data structure for message deduplication.
///
/// Used by [MessageRouter] and [MeshRelayService] to track seen message IDs
/// without unbounded memory growth. A Bloom filter can tell you:
/// - "Definitely NOT seen" (no false negatives)
/// - "Probably seen" (configurable false positive rate)
///
/// For mesh networking, false positives (occasionally dropping a duplicate)
/// are acceptable — the gossip protocol's redundancy means the same message
/// arrives via multiple paths, compensating for any single drop.
///
/// ## Sizing
///
/// For 10,000 expected messages and 1% false positive rate:
/// - Bit array: ~96,000 bits (12 KB)
/// - Hash functions: 7
///
/// This is dramatically smaller than storing 10,000 UUID strings (~360 KB).
class BloomFilter {
  /// Create a Bloom filter with the given capacity and false positive rate.
  ///
  /// [expectedInsertions] — expected number of unique items to insert.
  /// [falsePositiveRate] — target FPP (e.g. 0.01 for 1%).
  factory BloomFilter({
    required int expectedInsertions,
    double falsePositiveRate = 0.01,
  }) {
    assert(expectedInsertions > 0, 'expectedInsertions must be positive');
    assert(falsePositiveRate > 0 && falsePositiveRate < 1, 'falsePositiveRate must be between 0 and 1 exclusive');

    // Optimal bit array size: m = -n*ln(p) / (ln(2))^2
    final m = (-(expectedInsertions * log(falsePositiveRate)) /
            (log(2) * log(2)))
        .ceil();

    // Optimal number of hash functions: k = (m/n) * ln(2)
    final k = ((m / expectedInsertions) * log(2)).ceil().clamp(1, 20);

    return BloomFilter._(
      bitArray: Uint8List((m + 7) ~/ 8), // round up to nearest byte
      bitCount: m,
      hashCount: k,
      expectedInsertions: expectedInsertions,
    );
  }

  BloomFilter._({
    required this.bitArray,
    required this.bitCount,
    required this.hashCount,
    required this.expectedInsertions,
  });

  final Uint8List bitArray;
  final int bitCount;
  final int hashCount;
  final int expectedInsertions;
  int _insertionCount = 0;

  /// Number of items inserted so far.
  int get insertionCount => _insertionCount;

  /// Whether the filter is getting full (>80% of expected capacity).
  bool get isNearCapacity => _insertionCount > expectedInsertions * 0.8;

  /// Add an item to the filter.
  void add(String item) {
    final hashes = _getHashes(item);
    for (final hash in hashes) {
      final index = hash % bitCount;
      bitArray[index ~/ 8] |= 1 << (index % 8);
    }
    _insertionCount++;
  }

  /// Check if an item MIGHT be in the filter.
  ///
  /// Returns:
  /// - `false` — item is DEFINITELY not in the filter (no false negatives)
  /// - `true` — item is PROBABLY in the filter (may be false positive)
  bool mightContain(String item) {
    final hashes = _getHashes(item);
    for (final hash in hashes) {
      final index = hash % bitCount;
      if ((bitArray[index ~/ 8] & (1 << (index % 8))) == 0) {
        return false;
      }
    }
    return true;
  }

  /// Reset the filter, clearing all bits.
  void clear() {
    bitArray.fillRange(0, bitArray.length, 0);
    _insertionCount = 0;
  }

  /// Current estimated false positive rate based on insertion count.
  double get estimatedFpp {
    if (_insertionCount == 0) return 0;
    // FPP ≈ (1 - e^(-kn/m))^k
    final exponent = -hashCount * _insertionCount / bitCount;
    return pow(1 - exp(exponent), hashCount).toDouble();
  }

  // ==================== Hashing ====================

  /// Generate [hashCount] hash values using double hashing.
  ///
  /// Uses the Kirsch-Mitzenmacher technique: h_i(x) = h1(x) + i*h2(x)
  /// which gives independent hash functions from just two base hashes.
  List<int> _getHashes(String item) {
    final h1 = _fnv1a32(item);
    final h2 = _murmur3Seed(item, 0x9747b28c);
    return List.generate(hashCount, (i) => (h1 + i * h2) & 0x7FFFFFFF);
  }

  /// FNV-1a 32-bit hash.
  static int _fnv1a32(String data) {
    var hash = 0x811c9dc5;
    for (var i = 0; i < data.length; i++) {
      hash ^= data.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }

  /// MurmurHash3 simplified 32-bit with seed.
  static int _murmur3Seed(String data, int seed) {
    var hash = seed;
    for (var i = 0; i < data.length; i++) {
      var k = data.codeUnitAt(i);
      k = (k * 0xcc9e2d51) & 0xFFFFFFFF;
      k = ((k << 15) | (k >> 17)) & 0xFFFFFFFF;
      k = (k * 0x1b873593) & 0xFFFFFFFF;
      hash ^= k;
      hash = ((hash << 13) | (hash >> 19)) & 0xFFFFFFFF;
      hash = (hash * 5 + 0xe6546b64) & 0xFFFFFFFF;
    }
    hash ^= data.length;
    hash ^= hash >> 16;
    hash = (hash * 0x85ebca6b) & 0xFFFFFFFF;
    hash ^= hash >> 13;
    hash = (hash * 0xc2b2ae35) & 0xFFFFFFFF;
    hash ^= hash >> 16;
    return hash & 0x7FFFFFFF;
  }
}

/// A self-rotating Bloom filter that automatically resets when near capacity.
///
/// Uses two filters: a "current" and a "previous". When the current filter
/// reaches capacity, it becomes the previous, and a fresh filter is created.
/// Lookups check both filters, so recently-seen items are still caught
/// during the transition window.
///
/// This prevents unbounded false positive rate growth without losing all
/// dedup state at once (which would cause a flood of duplicate messages).
class RotatingBloomFilter {
  RotatingBloomFilter({
    required this.expectedInsertions,
    this.falsePositiveRate = 0.01,
  })  : _current = BloomFilter(
          expectedInsertions: expectedInsertions,
          falsePositiveRate: falsePositiveRate,
        ),
        _previous = null;

  final int expectedInsertions;
  final double falsePositiveRate;

  BloomFilter _current;
  BloomFilter? _previous;

  /// Add an item. Automatically rotates if the current filter is near capacity.
  void add(String item) {
    if (_current.isNearCapacity) {
      _rotate();
    }
    _current.add(item);
  }

  /// Check if an item might be in either the current or previous filter.
  bool mightContain(String item) {
    return _current.mightContain(item) ||
        (_previous?.mightContain(item) ?? false);
  }

  /// Total insertions across both filters.
  int get totalInsertions =>
      _current.insertionCount + (_previous?.insertionCount ?? 0);

  void _rotate() {
    _previous = _current;
    _current = BloomFilter(
      expectedInsertions: expectedInsertions,
      falsePositiveRate: falsePositiveRate,
    );
  }

  /// Clear all state.
  void clear() {
    _current.clear();
    _previous = null;
  }
}
