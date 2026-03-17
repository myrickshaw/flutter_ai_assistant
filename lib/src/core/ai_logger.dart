import 'dart:developer' as dev;

/// Centralized logger for the AI Assistant package.
///
/// Logging is disabled by default. Enable it by setting [enableLogging]
/// to `true` in [AiAssistantConfig], or by calling [AiLogger.enable()]
/// directly.
///
/// All log output uses `dart:developer` [log], which appears in DevTools
/// and is automatically stripped from release builds.
class AiLogger {
  static bool _enabled = false;

  static const String _name = 'flutter_ai_assistant';

  /// Whether logging is currently enabled.
  static bool get isEnabled => _enabled;

  /// Enable logging.
  static void enable() => _enabled = true;

  /// Disable logging.
  static void disable() => _enabled = false;

  /// Log a message at the default level.
  static void log(String message, {String? tag}) {
    if (!_enabled) return;
    final prefix = tag != null ? '[$tag] ' : '';
    dev.log('$prefix$message', name: _name);
  }

  /// Log a warning.
  static void warn(String message, {String? tag}) {
    if (!_enabled) return;
    final prefix = tag != null ? '[$tag] ' : '';
    dev.log('⚠ $prefix$message', name: _name, level: 900);
  }

  /// Log an error with optional stack trace.
  static void error(String message, {Object? error, StackTrace? stackTrace, String? tag}) {
    if (!_enabled) return;
    final prefix = tag != null ? '[$tag] ' : '';
    dev.log(
      '✖ $prefix$message',
      name: _name,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
