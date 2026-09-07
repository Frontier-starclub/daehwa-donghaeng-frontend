/// 백엔드가 내려주는 오류를 앱 쪽 타입으로 옮긴 것.
///
/// 백엔드는 실패 시 항상 `{code, message, details?}` 형태를 준다
/// (`apps/backend/app/errors.py`). `message`는 한국어 사용자 문구이므로
/// 화면에서 그대로 보여줘도 된다 — 앱에서 문구를 새로 지어내지 않는다.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.details,
  });

  final int statusCode;
  final String code;
  final String message;
  final Object? details;

  factory ApiException.timeout(Object cause) => ApiException(
        statusCode: 0,
        code: 'REQUEST_TIMEOUT',
        message: '응답이 늦어지고 있어요. 다시 시도해 주세요.',
        details: cause,
      );

  /// 네트워크가 끊겼거나 서버에 닿지 못한 경우.
  factory ApiException.network(Object cause) => ApiException(
        statusCode: 0,
        code: 'NETWORK_ERROR',
        message: '연결이 되지 않았어요. 잠시 후 다시 시도해 주세요.',
        details: cause,
      );

  /// 응답은 왔지만 형태를 해석하지 못한 경우.
  factory ApiException.malformed(Object cause) => ApiException(
        statusCode: 0,
        code: 'MALFORMED_RESPONSE',
        message: '잠시 문제가 있었어요. 다시 시도해 주세요.',
        details: cause,
      );

  /// 다시 시도해볼 만한 실패인지. 화면에 [다시 시도] 버튼을 띄울지 판단할 때 쓴다.
  bool get isRetryable =>
      code == 'NETWORK_ERROR' || statusCode == 0 || statusCode >= 500;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}
