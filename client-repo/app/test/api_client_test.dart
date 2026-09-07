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
      httpClient: MockClient((request) async {
        called = true;
        expect(request.headers['X-Device-ID'], 'test-device');
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
}
