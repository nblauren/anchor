import 'dart:developer' as developer;

/// Simple logging utility
class Logger {
  Logger._();

  static void debug(String message, [String? tag]) {
    _log('DEBUG', message, tag);
  }

  static void info(String message, [String? tag]) {
    _log('INFO', message, tag);
  }

  static void warning(String message, [String? tag]) {
    _log('WARNING', message, tag);
  }

  static void error(String message, [Object? error, StackTrace? stackTrace, String? tag]) {
    _log('ERROR', message, tag);
    if (error != null) {
      developer.log(
        'Error: $error',
        name: tag ?? 'Anchor',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static void _log(String level, String message, String? tag) {
    final timestamp = DateTime.now().toIso8601String();
    developer.log(
      '[$level] $message',
      time: DateTime.now(),
      name: tag ?? 'Anchor',
    );
  }
}
