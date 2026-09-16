import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../core/api_exception.dart';
import 'chat_repository.dart';
import 'voice_service.dart';

enum ChatPhase {
  loading,
  invitation,
  idle,
  listening,
  sending,
  speaking,
  ended
}

class ChatController extends ChangeNotifier {
  ChatController({required this.repository, required this.voice});
  final ChatDataSource repository;
  final VoiceService voice;
  ChatPhase phase = ChatPhase.loading;
  ChatSession? session;
  List<ChatMessage> messages = [];
  String draft = '';
  String? error;
  String? _pendingId;
  String? _pendingContent;
  int _generation = 0;
  bool _disposed = false;
  bool _suspended = false;
  bool get hasPending => _pendingId != null;
  bool get busy => phase == ChatPhase.loading || phase == ChatPhase.sending;
  bool get canEdit => phase == ChatPhase.idle && !hasPending;
  bool _current(int ticket) =>
      !_disposed && !_suspended && ticket == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _message(Object failure) =>
      failure is ApiException ? failure.message : '대화를 처리하지 못했어요. 다시 시도해 주세요.';

  Future<void> restore() async {
    if (_disposed) return;
    _suspended = false;
    final ticket = ++_generation;
    phase = ChatPhase.loading;
    error = null;
    _notify();
    try {
      final restored = await repository.current();
      if (!_current(ticket)) return;
      session = restored;
      messages = List.of(restored?.messages ?? []);
      if (restored == null ||
          messages.any(
            (message) =>
                message.clientMessageId == _pendingId && _pendingId != null,
          )) {
        _pendingId = null;
        _pendingContent = null;
        draft = '';
      }
      phase = restored == null ? ChatPhase.invitation : ChatPhase.idle;
    } catch (failure) {
      if (!_current(ticket)) return;
      error = _message(failure);
      // Do not create a second session when recovery itself failed.
      phase = ChatPhase.loading;
    }
    if (_current(ticket)) _notify();
  }

  Future<void> start({required bool accepted}) async {
    if (phase != ChatPhase.invitation && phase != ChatPhase.ended) return;
    final ticket = ++_generation;
    phase = ChatPhase.loading;
    error = null;
    _notify();
    try {
      final created = await repository.start(accepted: accepted);
      if (!_current(ticket)) return;
      session = created;
      messages = List.of(created.messages);
      phase = created.status == 'active' ? ChatPhase.idle : ChatPhase.ended;
      _notify();
      if (created.status == 'active' && messages.isNotEmpty) {
        await read(messages.last.content);
      }
    } catch (failure) {
      if (!_current(ticket)) return;
      error = _message(failure);
      phase = ChatPhase.invitation;
      _notify();
    }
  }

  void updateDraft(String value) {
    if (!canEdit) return;
    _generation++;
    draft = value;
    error = null;
    _notify();
  }

  Future<void> listen() async {
    if (!canEdit) return;
    final ticket = ++_generation;
    phase = ChatPhase.listening;
    error = null;
    _notify();
    try {
      await voice.stopSpeaking();
      if (!_current(ticket)) return;
      final available = await voice.listen(
        onText: (text) {
          if (_current(ticket)) {
            draft = text;
            _notify();
          }
        },
        onDone: () {
          if (_current(ticket)) {
            phase = ChatPhase.idle;
            _notify();
          }
        },
        onError: (message) {
          if (_current(ticket)) {
            error = message;
            phase = ChatPhase.idle;
            _notify();
          }
        },
      );
      if (_current(ticket) && !available) {
        error = '마이크 권한과 한국어 음성 인식을 확인해 주세요. 글로 입력해도 대화할 수 있어요.';
        phase = ChatPhase.idle;
        _notify();
      }
    } catch (_) {
      if (!_current(ticket)) return;
      error = '마이크를 사용할 수 없어요. 글로 입력하거나 기기 설정을 확인해 주세요.';
      phase = ChatPhase.idle;
      _notify();
    }
  }

  Future<void> stopListening() async {
    if (phase != ChatPhase.listening) return;
    final ticket = _generation;
    try {
      await voice.stopListening();
    } catch (_) {/* Preserve any recognized text. */}
    if (_current(ticket)) {
      phase = ChatPhase.idle;
      _notify();
    }
  }

  Future<void> send() async {
    if (phase != ChatPhase.idle || session == null) return;
    final content = _pendingContent ?? draft.trim();
    if (content.isEmpty || content.length > 2000) {
      error = '보낼 내용을 1~2000자로 입력해 주세요.';
      _notify();
      return;
    }
    _pendingId ??= const Uuid().v4();
    _pendingContent = content;
    final ticket = ++_generation;
    phase = ChatPhase.sending;
    error = null;
    _notify();
    try {
      final turn = await repository.send(
        session!.id,
        clientMessageId: _pendingId!,
        content: content,
      );
      if (!_current(ticket)) return;
      final byId = {
        for (final message in messages) message.id: message,
        turn.user.id: turn.user,
        turn.assistant.id: turn.assistant,
      };
      messages = byId.values.toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      _pendingId = null;
      _pendingContent = null;
      draft = '';
      phase = ChatPhase.idle;
      _notify();
      await read(turn.assistant.content);
    } catch (failure) {
      if (!_current(ticket)) return;
      error = _message(failure);
      if (failure is ApiException &&
          (failure.code == 'CHAT_SESSION_CLOSED' ||
              failure.code == 'CHAT_SESSION_NOT_FOUND')) {
        _pendingId = null;
        _pendingContent = null;
        phase = ChatPhase.ended;
      } else {
        phase = ChatPhase.idle;
      }
      _notify();
    }
  }

  Future<void> read(String content) async {
    if (phase != ChatPhase.idle || hasPending) return;
    final ticket = ++_generation;
    phase = ChatPhase.speaking;
    _notify();
    try {
      await voice.stopListening();
      if (!_current(ticket)) return;
      await voice.speak(content);
    } catch (_) {
      if (_current(ticket)) error = '음성으로 읽지 못했어요. 화면의 답변을 확인해 주세요.';
    } finally {
      if (_current(ticket)) {
        phase = ChatPhase.idle;
        _notify();
      }
    }
  }

  Future<void> stopSpeaking() async {
    if (phase != ChatPhase.speaking) return;
    final ticket = ++_generation;
    try {
      await voice.stopSpeaking();
    } catch (_) {/* Text remains visible. */}
    if (_current(ticket)) {
      phase = ChatPhase.idle;
      _notify();
    }
  }

  Future<void> end() async {
    if (busy || session == null) return;
    final ticket = ++_generation;
    phase = ChatPhase.loading;
    error = null;
    _notify();
    await _stopAudio();
    if (!_current(ticket)) return;
    try {
      final ended = await repository.end(session!.id);
      if (!_current(ticket)) return;
      session = ended;
      _pendingId = null;
      _pendingContent = null;
      draft = '';
      phase = ChatPhase.ended;
    } catch (failure) {
      if (!_current(ticket)) return;
      error = _message(failure);
      phase = ChatPhase.idle;
    }
    if (_current(ticket)) _notify();
  }

  Future<void> _stopAudio() async {
    // Issue both stops before another screen can use the shared engine.
    await Future.wait([
      voice.stopListening().catchError((Object _) {}),
      voice.stopSpeaking().catchError((Object _) {}),
    ]);
  }

  Future<void> suspend() async {
    _suspended = true;
    _generation++;
    await _stopAudio();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_stopAudio());
    super.dispose();
  }
}
