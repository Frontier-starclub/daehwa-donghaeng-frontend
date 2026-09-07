import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import 'api_exception.dart';
import 'device_id_store.dart';

/// 백엔드 API 클라이언트.
///
/// 화면 코드가 헤더나 오류 처리를 직접 다루지 않도록 여기서 전부 흡수한다.
/// 39개 화면이 각자 http 호출을 짜면 통합 단계에서 수습이 안 되므로, 모든
/// 네트워크 호출은 이 클래스를 거친다.
///
/// 계약 (`docs/api/README.md`):
///   - base URL: Android 에뮬레이터 기준 http://10.0.2.2:8090/api/v1
///   - bootstrap 이후 모든 요청에 X-Device-ID 헤더 필요
class ApiClient {
  ApiClient({
    required this.baseUrl,
    required DeviceIdStore deviceIdStore,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  })  : _deviceIdStore = deviceIdStore,
        _http = httpClient ?? http.Client();

  /// Android 에뮬레이터에서 호스트를 가리키는 주소.
  /// 실기기 테스트에서는 개발 PC의 LAN IP로 바꿔서 넘긴다.
  static const String emulatorBaseUrl = 'http://10.0.2.2:8090/api/v1';

  final String baseUrl;
  final DeviceIdStore _deviceIdStore;
  final http.Client _http;

  /// OCR은 vision 호출이 뒤에 있어 수 초가 걸린다. 짧게 잡지 않는다.
  final Duration timeout;

  Future<Map<String, String>> _headers({bool json = true}) async {
    final deviceId = await _deviceIdStore.readOrCreate();
    return {
      'X-Device-ID': deviceId,
      if (json) 'Content-Type': 'application/json; charset=utf-8',
    };
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> get(String path, {Map<String, String>? query}) => _send(
        () async => _http.get(_uri(path, query), headers: await _headers()),
      );

  Future<dynamic> post(
    String path, {
    Object? body,
    Map<String, String>? query,
  }) =>
      _send(
        () async => _http.post(
          _uri(path, query),
          headers: await _headers(),
          body: body == null ? null : jsonEncode(body),
        ),
      );

  Future<dynamic> put(String path, {Object? body}) => _send(
        () async => _http.put(
          _uri(path),
          headers: await _headers(),
          body: body == null ? null : jsonEncode(body),
        ),
      );

  Future<dynamic> patch(String path, {Object? body}) => _send(
        () async => _http.patch(
          _uri(path),
          headers: await _headers(),
          body: body == null ? null : jsonEncode(body),
        ),
      );

  /// 약봉투 이미지 업로드.
  ///
  /// 필드명은 `image`, 형식은 JPEG/PNG, 최대 10MiB (백엔드 계약).
  Future<dynamic> uploadImage(
    String path, {
    required List<int> bytes,
    required String filename,
    required String contentType,
    Map<String, String>? query,
  }) =>
      _send(() async {
        final request = http.MultipartRequest('POST', _uri(path, query))
          ..headers.addAll(await _headers(json: false))
          ..files.add(
            http.MultipartFile.fromBytes(
              'image',
              bytes,
              filename: filename,
              contentType: MediaType.parse(contentType),
            ),
          );
        return http.Response.fromStream(await _http.send(request));
      });

  Future<dynamic> _send(Future<http.Response> Function() request) async {
    final http.Response response;
    try {
      response = await request().timeout(timeout);
    } on TimeoutException catch (error) {
      throw ApiException.timeout(error);
    } on SocketException catch (error) {
      throw ApiException.network(error);
    } on http.ClientException catch (error) {
      throw ApiException.network(error);
    }

    final hasBody = response.bodyBytes.isNotEmpty;
    dynamic decoded;
    if (hasBody) {
      try {
        decoded = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException catch (error) {
        throw ApiException.malformed(error);
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return decoded;
    }

    // 백엔드 오류 본문은 {code, message, details?} 형태다.
    if (decoded is Map<String, dynamic> && decoded['code'] is String) {
      throw ApiException(
        statusCode: response.statusCode,
        code: decoded['code'] as String,
        message: decoded['message'] as String? ?? '문제가 발생했어요.',
        details: decoded['details'],
      );
    }

    throw ApiException(
      statusCode: response.statusCode,
      code: 'UNEXPECTED_ERROR',
      message: '문제가 발생했어요. 잠시 후 다시 시도해 주세요.',
      details: decoded,
    );
  }

  void close() => _http.close();
}
