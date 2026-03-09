/// Fixed ID → label mappings for position and interests.
///
/// Only numeric IDs are transmitted over BLE (compact payload).
/// UI decodes IDs back to human-readable strings using these maps.
class ProfileConstants {
  ProfileConstants._();

  // ── Position ──────────────────────────────────────────────────────────────

  /// Single-select position IDs.
  static const Map<int, String> positionMap = {
    0: 'Top',
    1: 'Bottom',
    2: 'Versatile',
    3: 'Versatile Top',
    4: 'Versatile Bottom',
    5: 'Side',
    6: 'Prefer not to say',
  };

  static const int maxPositionId = 6;

  /// Returns the human-readable label for [id], or null if unknown.
  static String? positionLabel(int? id) =>
      id == null ? null : positionMap[id];

  // ── Interests ─────────────────────────────────────────────────────────────

  /// Multi-select interest IDs (0–11). Up to 10 may be chosen.
  static const Map<int, String> interestMap = {
    0: 'Casual/Hookups',
    1: 'Dates/Romance',
    2: 'Friends/Chat',
    3: 'Party/Nightlife',
    4: 'Gym/Fitness',
    5: 'Travel/Adventure',
    6: 'Kink/Fetish',
    7: 'Vanilla',
    8: 'Oral',
    9: 'Anal',
    10: 'Group Play',
    11: 'Cuddling/Affection',
  };

  static const int maxInterestId = 11;
  static const int maxInterestSelections = 10;

  /// Returns the human-readable label for [id], or null if unknown.
  static String? interestLabel(int id) => interestMap[id];

  /// Decodes a comma-separated string of IDs (e.g. "0,3,7") into labels.
  /// Unknown IDs are silently dropped.
  static List<String> decodeInterests(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    return raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .where((id) => id != null && interestMap.containsKey(id))
        .map((id) => interestMap[id]!)
        .toList();
  }

  /// Encodes a list of interest IDs as a compact comma-separated string.
  /// Invalid IDs are silently dropped. Result is empty string when list is empty.
  static String encodeInterests(List<int> ids) {
    final valid = ids
        .where((id) => interestMap.containsKey(id))
        .toSet() // deduplicate
        .toList()
      ..sort();
    return valid.join(',');
  }

  /// Parses a comma-separated interests string into a sorted list of valid IDs.
  static List<int> parseInterests(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    return raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .where((id) => id != null && interestMap.containsKey(id))
        .cast<int>()
        .toSet()
        .toList()
      ..sort();
  }
}
