import 'dart:developer' as developer;

/// Simple logging utility with in-memory circular buffer for in-app debug viewing
class Logger {
  Logger._();

  static const int _maxBufferSize = 200;
  static final List<String> _buffer = [];

  static void debug(String message, [String? tag]) {
    _log('DEBUG', message, tag);
  }

  static void info(String message, [String? tag]) {
    _log('INFO', message, tag);
  }

  static void warning(String message, [String? tag]) {
    _log('WARNING', message, tag);
  }

  static void error(String message,
      [Object? error, StackTrace? stackTrace, String? tag]) {
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

  /// Returns recent log entries as a single string, newest first.
  static String getRecentLogs() {
    if (_buffer.isEmpty) return '';
    return _buffer.reversed.join('\n');
  }

  /// Clears the in-memory log buffer.
  static void clearBuffer() => _buffer.clear();

  static void _log(String level, String message, String? tag) {
    final now = DateTime.now();
    final entry =
        '${now.toIso8601String()} [${tag ?? 'Anchor'}] [$level] $message';

    if (_buffer.length >= _maxBufferSize) _buffer.removeAt(0);
    _buffer.add(entry);

    developer.log(
      '[$level] $message',
      time: now,
      name: tag ?? 'Anchor',
    );
  }
}
