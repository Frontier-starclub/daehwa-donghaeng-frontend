import 'package:uuid/uuid.dart';
import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import '../../core/json_decode.dart';

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.sequence,
    this.clientMessageId,
  });
  final String id;
  final String role;
  final String content;
  final int sequence;
  final String? clientMessageId;
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] as String,
        role: json['role'] as String,
        content: json['content'] as String,
        sequence: json['sequence_no'] as int,
        clientMessageId: json['client_message_id'] as String?,
      );
}

class ChatSession {
  const ChatSession({
    required this.id,
    required this.status,
    required this.messages,
  });
  final String id;
  final String status;
  final List<ChatMessage> messages;
  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] as String,
        status: json['status'] as String,
        messages: (json['messages'] as List<dynamic>)
            .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence)),
      );
}

class ChatTurn {
  const ChatTurn(this.user, this.assistant);
  final ChatMessage user;
  final ChatMessage assistant;
  factory ChatTurn.fromJson(Map<String, dynamic> json) => ChatTurn(
        ChatMessage.fromJson(json['user_message'] as Map<String, dynamic>),
        ChatMessage.fromJson(json['assistant_message'] as Map<String, dynamic>),
      );
}

abstract interface class ChatDataSource {
  Future<ChatSession?> current();
  Future<ChatSession> start({required bool accepted});
  Future<ChatTurn> send(
    String sessionId, {
    required String clientMessageId,
    required String content,
  });
  Future<ChatSession> end(String sessionId);
}

class ChatRepository implements ChatDataSource {
  const ChatRepository(this.api);
  final ApiClient api;
  @override
  Future<ChatSession?> current() async => decodeResponse(
        await api.get('/chat/sessions/current'),
        (value) => value == null
            ? null
            : ChatSession.fromJson(value as Map<String, dynamic>),
      );
  @override
  Future<ChatSession> start({required bool accepted}) async => decodeResponse(
        await api.post(
          '/chat/sessions',
          body: {'decision': accepted ? 'accepted' : 'declined'},
        ),
        (value) => ChatSession.fromJson(value as Map<String, dynamic>),
      );
  @override
  Future<ChatTurn> send(
    String sessionId, {
    required String clientMessageId,
    required String content,
  }) async =>
      decodeResponse(
        await api.post(
          '/chat/sessions/$sessionId/messages',
          body: {'client_message_id': clientMessageId, 'content': content},
        ),
        (value) => ChatTurn.fromJson(value as Map<String, dynamic>),
      );
  @override
  Future<ChatSession> end(String sessionId) async => decodeResponse(
        await api.post('/chat/sessions/$sessionId/end'),
        (value) => ChatSession.fromJson(value as Map<String, dynamic>),
      );
}

class MockChatRepository implements ChatDataSource {
  ChatSession? _session;
  final Map<String, ChatTurn> _turns = {};
  @override
  Future<ChatSession?> current() async =>
      _session?.status == 'active' ? _session : null;
  @override
  Future<ChatSession> start({required bool accepted}) async {
    if (accepted && _session?.status == 'active') return _session!;
    _turns.clear();
    return _session = ChatSession(
      id: const Uuid().v4(),
      status: accepted ? 'active' : 'declined',
      messages: [
        if (accepted)
          ChatMessage(
            id: const Uuid().v4(),
            role: 'assistant',
            content: '오늘 하루 어떻게 보내셨어요?',
            sequence: 1,
          ),
      ],
    );
  }

  @override
  Future<ChatTurn> send(
    String sessionId, {
    required String clientMessageId,
    required String content,
  }) async {
    if (_session?.status != 'active' || _session?.id != sessionId) {
      throw const ApiException(
        statusCode: 409,
        code: 'CHAT_SESSION_CLOSED',
        message: '종료된 대화입니다.',
      );
    }
    if (_turns.containsKey(clientMessageId)) return _turns[clientMessageId]!;
    final count = _session!.messages.length;
    final turn = ChatTurn(
      ChatMessage(
        id: const Uuid().v4(),
        role: 'user',
        content: content,
        sequence: count + 1,
        clientMessageId: clientMessageId,
      ),
      ChatMessage(
        id: const Uuid().v4(),
        role: 'assistant',
        content: '말씀해 주셔서 고마워요. 오늘 가장 기억에 남는 일은 무엇인가요?',
        sequence: count + 2,
      ),
    );
    _turns[clientMessageId] = turn;
    _session = ChatSession(
      id: sessionId,
      status: 'active',
      messages: [..._session!.messages, turn.user, turn.assistant],
    );
    return turn;
  }

  @override
  Future<ChatSession> end(String sessionId) async => _session = ChatSession(
        id: sessionId,
        status: 'ended',
        messages: _session?.messages ?? [],
      );
}
