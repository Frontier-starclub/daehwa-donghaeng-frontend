import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:daehwa_donghaeng/core/api_exception.dart';
import 'package:daehwa_donghaeng/features/chat/chat_controller.dart';
import 'package:daehwa_donghaeng/features/chat/chat_repository.dart';
import 'package:daehwa_donghaeng/features/chat/voice_service.dart';

class TestVoice implements VoiceService {
  bool available = true;
  bool failSpeaking = false;
  int stops = 0;
  int spoken = 0;
  void Function(String)? textCallback;
  void Function()? doneCallback;
  Completer<void>? speaking;
  @override
  Future<bool> listen({
    required void Function(String) onText,
    required void Function() onDone,
    required void Function(String) onError,
  }) async {
    textCallback = onText;
    doneCallback = onDone;
    return available;
  }

  @override
  Future<void> speak(String text) async {
    spoken++;
    if (failSpeaking) throw StateError('no voice');
    await speaking?.future;
  }

  @override
  Future<void> stopListening() async {
    stops++;
  }

  @override
  Future<void> stopSpeaking() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    stops++;
  }
}

class RetryChat extends MockChatRepository {
  final ids = <String>[];
  final bodies = <String>[];
  bool failOnce = true;
  Completer<void>? pending;
  @override
  Future<ChatTurn> send(
    String sessionId, {
    required String clientMessageId,
    required String content,
  }) async {
    ids.add(clientMessageId);
    bodies.add(content);
    // Simulate server commit followed by a lost response.
    final result = await super
        .send(sessionId, clientMessageId: clientMessageId, content: content);
    await pending?.future;
    if (failOnce) {
      failOnce = false;
      throw ApiException.timeout('lost reply');
    }
    return result;
  }
}

void main() {
  Future<ChatController> active({
    ChatDataSource? repository,
    TestVoice? voice,
  }) async {
    final controller = ChatController(
      repository: repository ?? MockChatRepository(),
      voice: voice ?? TestVoice(),
    );
    addTearDown(controller.dispose);
    await controller.restore();
    await controller.start(accepted: true);
    return controller;
  }

  test('retry preserves message ID and body after a committed response is lost',
      () async {
    final repository = RetryChat();
    final chat = await active(repository: repository);
    chat.updateDraft('오늘 산책했어요');
    await chat.send();
    expect(chat.hasPending, isTrue);
    chat.updateDraft('바꾼 문장');
    expect(chat.draft, '오늘 산책했어요');
    await chat.send();
    expect(repository.ids[0], repository.ids[1]);
    expect(repository.bodies, ['오늘 산책했어요', '오늘 산책했어요']);
    expect(chat.messages.length, 3);
    expect((await repository.current())!.messages.length, 3);
    expect(chat.hasPending, isFalse);
  });
  test('microphone rejection keeps text input usable', () async {
    final voice = TestVoice()..available = false;
    final chat = await active(voice: voice);
    await chat.listen();
    expect(chat.canEdit, isTrue);
    expect(chat.error, contains('마이크'));
    chat.updateDraft('글로 이야기해요');
    await chat.send();
    expect(chat.messages.last.role, 'assistant');
  });
  test(
      'STT result requires explicit send; late result cannot replace a sending draft',
      () async {
    final voice = TestVoice();
    final repository = RetryChat()..failOnce = false;
    final chat = await active(voice: voice, repository: repository);
    await chat.listen();
    voice.textCallback!('인식한 문장');
    voice.doneCallback!();
    expect(repository.ids, isEmpty);
    expect(chat.draft, '인식한 문장');
    await chat.send();
    voice.textCallback!('늦은 인식');
    expect(chat.draft, isEmpty);
  });
  test('TTS failure preserves response and allows another typed message',
      () async {
    final voice = TestVoice()..failSpeaking = true;
    final chat = await active(voice: voice);
    expect(chat.messages, isNotEmpty);
    expect(chat.canEdit, isTrue);
    expect(chat.error, contains('음성'));
  });
  test('active session recovers without replaying old audio', () async {
    final repository = MockChatRepository();
    final previous = await repository.start(accepted: true);
    final voice = TestVoice();
    final chat = ChatController(repository: repository, voice: voice);
    addTearDown(chat.dispose);
    await chat.restore();
    expect(chat.session!.id, previous.id);
    expect(voice.spoken, 0);
  });
  test('suspension ignores late reply and recovery reconciles pending message',
      () async {
    final repository = RetryChat()..failOnce = false;
    final chat = await active(repository: repository);
    repository.pending = Completer<void>();
    chat.updateDraft('백그라운드 전송');
    final sending = chat.send();
    await Future<void>.delayed(Duration.zero);
    await chat.suspend();
    repository.pending!.complete();
    await sending;
    expect(chat.messages.length, 1);
    await chat.restore();
    expect(chat.messages.length, 3);
    expect(chat.hasPending, isFalse);
  });
  test('double send is suppressed; disposal ignores a pending response',
      () async {
    final repository = RetryChat()..failOnce = false;
    final voice = TestVoice();
    final chat = ChatController(repository: repository, voice: voice);
    await chat.restore();
    await chat.start(accepted: true);
    repository.pending = Completer<void>();
    chat.updateDraft('한 번만');
    final sending = chat.send();
    await chat.send();
    expect(repository.ids.length, 1);
    chat.dispose();
    repository.pending!.complete();
    await sending;
    expect(chat.messages.length, 1);
  });
  test('decline and end use distinct server actions', () async {
    final repository = MockChatRepository();
    final chat = ChatController(repository: repository, voice: TestVoice());
    addTearDown(chat.dispose);
    await chat.restore();
    await chat.start(accepted: false);
    expect(chat.session!.status, 'declined');
    await chat.start(accepted: true);
    await chat.end();
    expect(chat.session!.status, 'ended');
    expect(await repository.current(), isNull);
  });
}
