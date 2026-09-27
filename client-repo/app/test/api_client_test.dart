import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:daehwa_donghaeng/core/api_client.dart';
import 'package:daehwa_donghaeng/core/api_exception.dart';
import 'package:daehwa_donghaeng/core/device_id_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => SharedPreferences.setMockInitialValues({'device_id': 'test-device'}),
  );

  test('timeout is converted to retryable ApiException', () async {
    final pending = Completer<http.Response>();
    final api = ApiClient(
      baseUrl: 'http://localhost',
      deviceIdStore: DeviceIdStore(),
      timeout: const Duration(milliseconds: 10),
      httpClient: MockClient((_) => pending.future),
    );
    addTearDown(api.close);
    await expectLater(
      api.get('/slow'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.code, 'code', 'REQUEST_TIMEOUT')
            .having((error) => error.isRetryable, 'retryable', true),
      ),
    );
    pending.complete(http.Response('{}', 200));
  });

  test('multipart uses injected client, device header and image field',
      () async {
    var called = false;
    final api = ApiClient(
      baseUrl: 'http://localhost',
      deviceIdStore: DeviceIdStore(),
      testAccessToken: 'team-test-token',
      httpClient: MockClient((request) async {
        called = true;
        expect(request.headers['X-Device-ID'], 'test-device');
        expect(request.headers['Authorization'], 'Bearer team-test-token');
        expect(
          request.headers['content-type'],
          contains('multipart/form-data'),
        );
        expect(request.body, contains('name="image"'));
        expect(request.body, contains('filename="test.png"'));
        return http.Response('{"ok":true}', 200);
      }),
    );
    addTearDown(api.close);
    expect(
      await api.uploadImage(
        '/scan',
        bytes: [1, 2, 3],
        filename: 'test.png',
        contentType: 'image/png',
      ),
      {'ok': true},
    );
    expect(called, isTrue);
  });

  test('shared access token accompanies JSON calls including bootstrap',
      () async {
    final methods = <String>[];
    final api = ApiClient(
      baseUrl: 'https://test.example/api/v1',
      deviceIdStore: DeviceIdStore(),
      testAccessToken: 'team-test-token',
      httpClient: MockClient((request) async {
        methods.add(request.method);
        expect(request.headers['Authorization'], 'Bearer team-test-token');
        expect(request.headers['X-Device-ID'], 'test-device');
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);
    await api.post('/users/bootstrap', body: {'display_name': '테스트'});
    await api.get('/users/me');
    await api.put('/users/me', body: {});
    await api.patch('/medications/id', body: {});
    await api.delete('/caregivers/links/id');
    expect(methods, ['POST', 'GET', 'PUT', 'PATCH', 'DELETE']);
  });

  test('local development sends no shared access token by default', () async {
    final api = ApiClient(
      baseUrl: 'http://localhost',
      deviceIdStore: DeviceIdStore(),
      httpClient: MockClient((request) async {
        expect(request.headers.containsKey('Authorization'), isFalse);
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);
    await api.get('/users/me');
  });
}
