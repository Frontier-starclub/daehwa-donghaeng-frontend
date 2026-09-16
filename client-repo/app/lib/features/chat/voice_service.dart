import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

abstract interface class VoiceService {
  Future<bool> listen({
    required void Function(String) onText,
    required void Function() onDone,
    required void Function(String) onError,
  });
  Future<void> stopListening();
  Future<void> speak(String text);
  Future<void> stopSpeaking();
  Future<void> dispose();
}

/// App-owned engine; initialize STT once and route callbacks to the active screen.
class DeviceVoiceService implements VoiceService {
  final SpeechToText _speech = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  void Function()? _onDone;
  void Function(String)? _onError;
  bool _initialized = false;
  bool _closed = false;
  int _generation = 0;

  @override
  Future<bool> listen({
    required void Function(String) onText,
    required void Function() onDone,
    required void Function(String) onError,
  }) async {
    final ticket = ++_generation;
    _onDone = onDone;
    _onError = onError;
    if (!_initialized) {
      _initialized = await _speech.initialize(
        options: [SpeechToText.androidNoBluetooth],
        onStatus: (status) {
          if (!_closed && status == 'done') _onDone?.call();
        },
        onError: (_) {
          if (!_closed) _onError?.call('음성을 인식하지 못했어요. 다시 말하거나 글로 입력해 주세요.');
        },
      );
    }
    if (!_initialized || _closed || ticket != _generation) return false;
    final locales = await _speech.locales();
    if (_closed || ticket != _generation) return false;
    final korean = locales.where(
      (locale) =>
          locale.localeId.replaceAll('_', '-').toLowerCase().startsWith('ko'),
    );
    if (korean.isEmpty) return false;
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        localeId: korean.first.localeId,
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 4),
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
      onResult: (result) {
        if (_closed || ticket != _generation) return;
        onText(result.recognizedWords);
        if (result.finalResult) onDone();
      },
    );
    return true;
  }

  @override
  Future<void> stopListening() async {
    await _speech.stop();
  }

  @override
  Future<void> speak(String text) async {
    if (_closed) return;
    final ticket = ++_generation;
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(0.45);
    await _tts.awaitSpeakCompletion(true);
    if (_closed || ticket != _generation) return;
    final result = await _tts.speak(text).timeout(const Duration(seconds: 90));
    if (result == 0) throw StateError('TTS unavailable');
  }

  @override
  Future<void> stopSpeaking() async {
    _generation++;
    await _tts.stop();
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    _generation++;
    _onDone = null;
    _onError = null;
    try {
      await _speech.cancel();
    } catch (_) {/* Engine may never have initialized. */}
    try {
      await _tts.stop();
    } catch (_) {/* Unsupported platforms retain text UI. */}
  }
}
