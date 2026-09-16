import 'dart:async';
import 'package:flutter/material.dart';
import '../../design/tokens.dart';
import 'chat_controller.dart';
import 'chat_repository.dart';
import 'voice_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.repository,
    required this.voice,
    this.isMock = false,
  });
  final ChatDataSource repository;
  final VoiceService voice;
  final bool isMock;
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  late final ChatController _chat;
  final _text = TextEditingController();
  final _scroll = ScrollController();
  int _messageCount = 0;
  bool _backgrounded = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chat = ChatController(repository: widget.repository, voice: widget.voice)
      ..addListener(_sync);
    _chat.restore();
  }

  void _sync() {
    if (_text.text != _chat.draft) {
      _text.value = TextEditingValue(
        text: _chat.draft,
        selection: TextSelection.collapsed(offset: _chat.draft.length),
      );
    }
    if (_messageCount != _chat.messages.length) {
      _messageCount = _chat.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _backgrounded = true;
      unawaited(_chat.suspend());
    } else if (state == AppLifecycleState.resumed && _backgrounded) {
      _backgrounded = false;
      unawaited(_chat.restore());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chat.removeListener(_sync);
    _chat.dispose();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('이야기 나누기')),
        body: SafeArea(
          child: AnimatedBuilder(
            animation: _chat,
            builder: (context, _) => ListView(
              controller: _scroll,
              padding: const EdgeInsets.all(AppSpacing.screenH),
              children: [
                if (widget.isMock) const Text('예시 대화 · 실제 AI 답변이 아닙니다.'),
                if (_chat.phase == ChatPhase.invitation) ...[
                  Text(
                    '잠깐 이야기 나눌까요?',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: () => _chat.start(accepted: true),
                    child: const Text('네, 좋아요'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton(
                    onPressed: () => _chat.start(accepted: false),
                    child: const Text('다음에 할게요'),
                  ),
                ],
                for (final message in _chat.messages) ...[
                  Container(
                    margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: message.role == 'user'
                          ? const Color(0xFFE9F1FA)
                          : AppColors.surface,
                      border: Border.all(color: AppColors.border),
                      borderRadius: BorderRadius.circular(AppSizing.radius),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          message.role == 'user' ? '나' : '대화동행',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          message.content,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (message.role == 'assistant')
                          TextButton(
                            onPressed: _chat.phase == ChatPhase.idle &&
                                    !_chat.hasPending
                                ? () => _chat.read(message.content)
                                : null,
                            child: const Text('다시 듣기'),
                          ),
                      ],
                    ),
                  ),
                ],
                Semantics(
                  liveRegion: true,
                  child: Text(
                    switch (_chat.phase) {
                      ChatPhase.loading =>
                        _chat.error == null ? '대화를 준비하고 있어요' : '대화를 확인하지 못했어요',
                      ChatPhase.listening => '듣고 있어요. 편하게 말씀해 주세요',
                      ChatPhase.sending => '답변을 기다리고 있어요',
                      ChatPhase.speaking => '답변을 읽고 있어요',
                      ChatPhase.idle => '말씀하시거나 글로 입력해 주세요',
                      ChatPhase.ended => '다음에 또 이야기해요',
                      ChatPhase.invitation => '',
                    },
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
                if (_chat.error != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _chat.error!,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
                if (_chat.phase == ChatPhase.loading) ...[
                  const SizedBox(height: AppSpacing.md),
                  if (_chat.error == null)
                    const Center(child: CircularProgressIndicator())
                  else
                    OutlinedButton(
                      onPressed: _chat.restore,
                      child: const Text('대화 다시 불러오기'),
                    ),
                ],
                if (_chat.session?.status == 'active' &&
                    _chat.phase != ChatPhase.ended) ...[
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _text,
                    enabled: _chat.canEdit,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: 2000,
                    style: Theme.of(context).textTheme.bodyLarge,
                    decoration: const InputDecoration(
                      labelText: '보낼 내용',
                      hintText: '인식한 내용을 확인하거나 직접 입력하세요',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: _chat.updateDraft,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  if (_chat.phase == ChatPhase.listening)
                    FilledButton(
                      onPressed: _chat.stopListening,
                      child: const Text('말하기 마치기'),
                    )
                  else if (_chat.phase == ChatPhase.speaking)
                    FilledButton(
                      onPressed: _chat.stopSpeaking,
                      child: const Text('읽어주기 중지'),
                    )
                  else
                    OutlinedButton(
                      onPressed: _chat.canEdit ? _chat.listen : null,
                      child: const Text('마이크로 말하기'),
                    ),
                  const SizedBox(height: AppSpacing.sm),
                  FilledButton(
                    onPressed: _chat.phase == ChatPhase.idle &&
                            (_chat.hasPending || _chat.draft.trim().isNotEmpty)
                        ? _chat.send
                        : null,
                    child: Text(
                      _chat.hasPending ? '같은 내용 다시 보내기' : '이 내용 보내기',
                    ),
                  ),
                  if (_chat.hasPending)
                    const Text(
                      '전송한 내용을 유지하고 있어요. 다시 보내도 같은 메시지로 처리됩니다.',
                    ),
                  const SizedBox(height: AppSpacing.md),
                  TextButton(
                    onPressed: _chat.busy ? null : _chat.end,
                    child: const Text('대화 마치기'),
                  ),
                ],
                if (_chat.phase == ChatPhase.ended) ...[
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: () => _chat.start(accepted: true),
                    child: const Text('새 대화 시작'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('홈으로'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}
