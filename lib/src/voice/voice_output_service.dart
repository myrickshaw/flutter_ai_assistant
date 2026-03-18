import 'package:flutter_tts/flutter_tts.dart';

import '../core/ai_logger.dart';

/// Common Hindi/Hinglish particles used for language detection.
const _hindiParticles = <String>{
  'hai',
  'ka',
  'ke',
  'ki',
  'ko',
  'mein',
  'me',
  'aapka',
  'aapki',
  'kiya',
  'karo',
  'krdo',
  'krna',
  'karna',
  'bata',
  'batao',
  'dikhao',
  'dikha',
  'chahiye',
  'wala',
  'wali',
  'wale',
  'haan',
  'nahi',
  'nhi',
  'aur',
  'ya',
  'se',
  'par',
  'pe',
  'tak',
  'bhi',
  'toh',
  'to',
  'kya',
  'kaise',
  'kitna',
  'kitne',
  'kitni',
  'kaun',
  'kab',
  'kaha',
  'kahan',
  'mera',
  'meri',
  'mere',
  'tera',
  'teri',
  'tere',
  'uska',
  'uski',
  'unka',
  'unki',
  'yeh',
  'woh',
  'abhi',
  'pehle',
  'baad',
  'saath',
  'liye',
  'dedo',
  'mangao',
};

/// Devanagari Unicode range for script detection.
final _devanagariRegex = RegExp(r'[\u0900-\u097F]');

/// Wraps the flutter_tts package for text-to-speech output.
///
/// Features:
/// - Auto-detects Hindi vs English from response text and switches TTS language
/// - Supports summary mode that speaks only the first sentence for long responses
class VoiceOutputService {
  final FlutterTts _tts = FlutterTts();
  bool _isInitialized = false;
  bool _isSpeaking = false;
  String _currentLanguage = 'en-US';

  /// Whether the TTS engine is currently speaking.
  bool get isSpeaking => _isSpeaking;

  /// Initialize the TTS engine with sensible defaults.
  Future<void> initialize({double speechRate = 0.5, double pitch = 1.0}) async {
    if (_isInitialized) return;

    AiLogger.log(
      'Initializing TTS (rate=$speechRate, pitch=$pitch)',
      tag: 'VoiceOut',
    );
    await _tts.setSpeechRate(speechRate);
    await _tts.setPitch(pitch);

    _tts.setStartHandler(() => _isSpeaking = true);
    _tts.setCompletionHandler(() {
      AiLogger.log('TTS playback completed', tag: 'VoiceOut');
      _isSpeaking = false;
    });
    _tts.setCancelHandler(() {
      AiLogger.log('TTS playback cancelled', tag: 'VoiceOut');
      _isSpeaking = false;
    });
    _tts.setErrorHandler((error) {
      AiLogger.error('TTS error: $error', tag: 'VoiceOut');
      _isSpeaking = false;
    });

    _isInitialized = true;
    AiLogger.log('TTS initialized', tag: 'VoiceOut');
  }

  /// Detect the dominant language of [text].
  ///
  /// Returns `'hi-IN'` if Devanagari script is present or if common
  /// Hindi/Hinglish particles make up a significant portion of the words.
  /// Otherwise returns `'en-US'`.
  static String detectLanguage(String text) {
    // Devanagari script → definitely Hindi.
    if (_devanagariRegex.hasMatch(text)) return 'hi-IN';

    // Check for Hindi/Hinglish particles in romanized text.
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();

    if (words.isEmpty) return 'en-US';

    final hindiCount = words.where((w) => _hindiParticles.contains(w)).length;
    // If ≥25% of words are Hindi particles, treat as Hindi.
    if (hindiCount / words.length >= 0.25) return 'hi-IN';

    return 'en-US';
  }

  /// Set the TTS language, only calling the engine if it actually changed.
  Future<void> _ensureLanguage(String language) async {
    if (language == _currentLanguage) return;
    AiLogger.log(
      'TTS switching language: $_currentLanguage → $language',
      tag: 'VoiceOut',
    );
    await _tts.setLanguage(language);
    _currentLanguage = language;
  }

  /// Speak the given text with auto-detected language.
  ///
  /// If already speaking, stops the current utterance first.
  Future<void> speak(String text) async {
    if (!_isInitialized) await initialize();

    if (_isSpeaking) {
      AiLogger.log('TTS already speaking — stopping first', tag: 'VoiceOut');
      await stop();
    }

    await _ensureLanguage(detectLanguage(text));
    AiLogger.log(
      'TTS speaking (lang=$_currentLanguage): '
      '"${text.length > 80 ? '${text.substring(0, 80)}…' : text}"',
      tag: 'VoiceOut',
    );
    await _tts.speak(text);
  }

  /// Speak a concise summary of [text].
  ///
  /// If [text] is short (≤ [maxChars]), speaks it fully. For longer text,
  /// extracts and speaks only the first sentence — the full response is
  /// available in the chat bubble.
  Future<void> speakSummary(String text, {int maxChars = 120}) async {
    if (text.length <= maxChars) {
      return speak(text);
    }

    // Extract first sentence.
    final sentenceEnd = RegExp(r'[.!?\n]');
    final match = sentenceEnd.firstMatch(text);
    final summary = match != null
        ? text.substring(0, match.end).trim()
        : text.substring(0, maxChars);

    AiLogger.log(
      'TTS summary (${summary.length}/${text.length} chars)',
      tag: 'VoiceOut',
    );
    return speak(summary);
  }

  /// Stop speaking.
  Future<void> stop() async {
    AiLogger.log('TTS stop requested', tag: 'VoiceOut');
    await _tts.stop();
    _isSpeaking = false;
  }

  /// Dispose resources.
  void dispose() {
    AiLogger.log('Disposing TTS', tag: 'VoiceOut');
    _tts.stop();
  }
}
