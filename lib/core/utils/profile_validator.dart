import 'package:anchor/core/constants/profile_constants.dart';

/// Centralised validation for all user-entered profile fields.
///
/// Every method returns `null` when the value is valid, or a human-readable
/// error string otherwise.  The same logic is shared between form-field
/// validators in the UI and the bloc-level guard in [ProfileBloc].
class ProfileValidator {
  ProfileValidator._();

  // ── Nickname ─────────────────────────────────────────────────────────────

  static const int nicknameMinLength = 1;
  static const int nicknameMaxLength = 32;

  /// Letters, digits, spaces, and common punctuation (. , - _).
  static final RegExp _allowedNicknameChars =
      RegExp(r'^[a-zA-Z0-9 .,\-_]+$');

  /// Matches emoji, symbols, and invisible Unicode categories.
  /// Covers common emoji ranges, variation selectors, zero-width joiners,
  /// combining marks, and directional overrides.
  static final RegExp _disallowedUnicode = RegExp(
    r'[\u{1F600}-\u{1F64F}]'  // Emoticons
    r'|[\u{1F300}-\u{1F5FF}]' // Misc Symbols & Pictographs
    r'|[\u{1F680}-\u{1F6FF}]' // Transport & Map
    r'|[\u{1F1E0}-\u{1F1FF}]' // Flags
    r'|[\u{2600}-\u{26FF}]'   // Misc Symbols
    r'|[\u{2700}-\u{27BF}]'   // Dingbats
    r'|[\u{FE00}-\u{FE0F}]'   // Variation Selectors
    r'|[\u{200B}-\u{200F}]'   // Zero-width & directional
    r'|[\u{202A}-\u{202E}]'   // Directional overrides
    r'|[\u{2060}-\u{206F}]'   // Invisible operators
    r'|[\u{E0001}-\u{E007F}]' // Tags block
    r'|[\u{FFF0}-\u{FFFF}]'   // Specials
    r'|[\u{1F900}-\u{1F9FF}]' // Supplemental Symbols
    r'|[\u{1FA00}-\u{1FA6F}]' // Chess Symbols
    r'|[\u{1FA70}-\u{1FAFF}]' // Symbols Extended-A
    r'|[\u{2B50}]'            // Star
    r'|[\u{203C}\u{2049}]'    // Double exclamation / interrobang
    r'|[\u{20E3}]'            // Combining Enclosing Keycap
    r'|[\u{FE0E}\u{FE0F}]',  // Text/Emoji variation
    unicode: true,
  );

  static String? validateNickname(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your name';
    }

    final trimmed = value.trim();

    if (value != trimmed) {
      return 'Name cannot have leading or trailing spaces';
    }

    if (trimmed.length < nicknameMinLength) {
      return 'Name must be at least $nicknameMinLength character';
    }

    if (trimmed.length > nicknameMaxLength) {
      return 'Name must be $nicknameMaxLength characters or fewer';
    }

    if (_disallowedUnicode.hasMatch(trimmed)) {
      return 'Name cannot contain emoji or special Unicode characters';
    }

    if (!_allowedNicknameChars.hasMatch(trimmed)) {
      return 'Name can only contain letters, numbers, spaces, and . , - _';
    }

    return null;
  }

  // ── Age ──────────────────────────────────────────────────────────────────

  static const int ageMin = 18;
  static const int ageMax = 120;

  /// Validates a required age field.
  static String? validateAge(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your age';
    }

    final age = int.tryParse(value.trim());
    if (age == null) {
      return 'Age must be a whole number';
    }

    if (age < ageMin || age > ageMax) {
      return 'Please enter a valid age ($ageMin–$ageMax)';
    }

    return null;
  }

  // ── Bio ──────────────────────────────────────────────────────────────────

  static const int bioMaxLength = 300;

  /// Repeated character spam pattern (e.g. "aaaaaaa" — 6+ of the same char).
  static final RegExp _repeatedChars = RegExp(r'(.)\1{5,}');

  /// Very simple URL pattern to detect link spam.
  static final RegExp _urlPattern =
      RegExp(r'https?://\S+', caseSensitive: false);

  static const int _maxUrlsInBio = 1;

  /// Normalises and validates a bio string. Returns null when valid.
  /// [sanitized] receives the cleaned text (collapsed whitespace) when valid.
  static String? validateBio(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null; // bio is optional
    }

    final cleaned = _collapseWhitespace(value);

    if (cleaned.length > bioMaxLength) {
      return 'Bio must be $bioMaxLength characters or fewer';
    }

    if (_repeatedChars.hasMatch(cleaned)) {
      return 'Bio contains too many repeated characters';
    }

    final urlCount = _urlPattern.allMatches(cleaned).length;
    if (urlCount > _maxUrlsInBio) {
      return 'Bio can contain at most $_maxUrlsInBio link';
    }

    return null;
  }

  /// Sanitises the bio before storage: trims + collapses internal whitespace.
  static String sanitizeBio(String raw) => _collapseWhitespace(raw);

  static String _collapseWhitespace(String s) =>
      s.trim().replaceAll(RegExp(r'\s+'), ' ');

  // ── Position ─────────────────────────────────────────────────────────────

  static String? validatePosition(int? value) {
    if (value == null) return null; // optional
    if (!ProfileConstants.positionMap.containsKey(value)) {
      return 'Invalid position selection';
    }
    return null;
  }

  // ── Interests ────────────────────────────────────────────────────────────

  static String? validateInterests(List<int>? ids) {
    if (ids == null || ids.isEmpty) return null; // optional

    if (ids.length > ProfileConstants.maxInterestSelections) {
      return 'You can select at most ${ProfileConstants.maxInterestSelections} interests';
    }

    for (final id in ids) {
      if (!ProfileConstants.interestMap.containsKey(id)) {
        return 'Invalid interest selection';
      }
    }

    return null;
  }
}
