import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../core/ai_logger.dart';

/// Wraps the speech_to_text package for voice input.
///
/// Handles initialization, permission requests, and speech-to-text
/// conversion. The controller calls this when the user taps the mic button.
///
/// Supports multi-locale recognition: prefers Hindi (`hi_IN`) for
/// Hinglish-speaking users, falling back to `en_IN` then `en_US`.
class VoiceInputService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isInitialized = false;

  /// Cached list of locales available on this device (populated on first init).
  List<stt.LocaleName>? _deviceLocales;

  /// The locale ID that was resolved and will be used for listening.
  String? _resolvedLocaleId;

  /// Whether the speech recognizer is currently listening.
  bool get isListening => _speech.isListening;

  /// Whether the speech recognizer is available on this device.
  bool get isAvailable => _isInitialized;

  /// The locale that was selected for recognition after [initialize].
  String? get resolvedLocaleId => _resolvedLocaleId;

  /// Initialize the speech recognizer and request permissions.
  ///
  /// Call once before first use. Returns true if available.
  Future<bool> initialize() async {
    if (_isInitialized) return true;
    AiLogger.log('Initializing speech recognizer…', tag: 'VoiceIn');
    _isInitialized = await _speech.initialize();
    if (_isInitialized) {
      _deviceLocales = await _speech.locales();
      AiLogger.log(
        'Available locales: ${_deviceLocales!.map((l) => l.localeId).join(', ')}',
        tag: 'VoiceIn',
      );
    }
    AiLogger.log(
      'Speech recognizer initialized: available=$_isInitialized',
      tag: 'VoiceIn',
    );
    return _isInitialized;
  }

  /// Pick the best locale from [preferred] that is available on the device.
  ///
  /// Returns the first match from [preferred] found in the device's supported
  /// locales (case-insensitive, also matches language prefix — e.g. `hi_IN`
  /// matches a device locale `hi-IN` or `hi`). Falls back to the first
  /// preferred locale if nothing matches (the OS may still handle it).
  String _resolveBestLocale(List<String> preferred) {
    if (_deviceLocales == null || _deviceLocales!.isEmpty) {
      return preferred.first;
    }

    final deviceIds = _deviceLocales!
        .map((l) => l.localeId.toLowerCase())
        .toSet();

    for (final pref in preferred) {
      final normalized = pref.toLowerCase().replaceAll('-', '_');
      // Exact match (e.g. hi_in)
      if (deviceIds.contains(normalized)) return pref;
      // Hyphen variant (e.g. hi-in)
      final hyphen = normalized.replaceAll('_', '-');
      if (deviceIds.contains(hyphen)) return pref;
      // Language-only prefix match (e.g. hi)
      final lang = normalized.split('_').first;
      if (deviceIds.any(
        (d) => d.split('_').first == lang || d.split('-').first == lang,
      )) {
        return pref;
      }
    }

    return preferred.first;
  }

  /// Start listening for speech input.
  ///
  /// [onResult] is called with the recognized text and confidence (0.0–1.0)
  /// when the user stops speaking.
  /// [onPartial] is called with partial recognition results while speaking.
  /// [preferredLocales] ordered list of locale IDs to try (default: Hindi first).
  Future<void> startListening({
    required void Function(String finalText, double confidence) onResult,
    void Function(String partialText)? onPartial,
    List<String> preferredLocales = const ['hi_IN', 'en_IN', 'en_US'],
  }) async {
    if (!_isInitialized) {
      final ok = await initialize();
      if (!ok) return;
    }

    _resolvedLocaleId = _resolveBestLocale(preferredLocales);
    AiLogger.log(
      'Starting speech listening (locale=$_resolvedLocaleId)',
      tag: 'VoiceIn',
    );

    await _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          final confidence = result.confidence;
          AiLogger.log(
            'Speech final result: "${result.recognizedWords}" '
            '(confidence=${confidence.toStringAsFixed(2)})',
            tag: 'VoiceIn',
          );
          onResult(result.recognizedWords, confidence);
        } else {
          onPartial?.call(result.recognizedWords);
        }
      },
      localeId: _resolvedLocaleId!,
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        cancelOnError: true,
        partialResults: true,
      ),
    );
  }

  /// Stop listening.
  Future<void> stopListening() async {
    AiLogger.log('Stopping speech listening', tag: 'VoiceIn');
    await _speech.stop();
  }

  /// Cancel the current listening session without processing results.
  Future<void> cancel() async {
    AiLogger.log('Cancelling speech listening', tag: 'VoiceIn');
    await _speech.cancel();
  }

  /// Dispose resources.
  void dispose() {
    AiLogger.log('Disposing speech recognizer', tag: 'VoiceIn');
    _speech.stop();
  }
}
