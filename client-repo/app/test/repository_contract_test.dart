import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:daehwa_donghaeng/core/api_client.dart';
import 'package:daehwa_donghaeng/core/device_id_store.dart';
import 'package:daehwa_donghaeng/core/api_exception.dart';
import 'package:daehwa_donghaeng/features/ocr/http_ocr_repository.dart';
import 'package:daehwa_donghaeng/features/ocr/ocr_models.dart';
import 'package:daehwa_donghaeng/features/medication/medication_repository.dart';
import 'package:daehwa_donghaeng/features/medication/medication_models.dart';
import 'package:daehwa_donghaeng/features/dur/dur_repository.dart';
import 'package:daehwa_donghaeng/features/onboarding/user_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const imageData =
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=';
  http.Response jsonResponse(Object value, [int status = 200]) => http.Response(
        jsonEncode(value),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  test(
      'OCR scan and drug identifiers survive to batch; rename clears identifiers',
      () async {
    final api = ApiClient(
      baseUrl: 'http://test/api/v1',
      deviceIdStore: DeviceIdStore(),
      httpClient: MockClient((request) async {
        expect(request.headers['X-Device-ID'], isNotEmpty);
        expect(request.url.query, isEmpty);
        if (request.url.path.endsWith('/medication-scans')) {
          expect(latin1.decode(request.bodyBytes), contains('name="image"'));
          return jsonResponse({
            'id': 'scan-123',
            'provider': 'remote',
            'items': [
              {
                'name': '정확한 약 10mg',
                'item_seq': '12345',
                'ingredient_name': '성분',
                'ingredient_code': 'A01',
                'confidence': 0.92,
                'dose_frequency_per_day': 2,
              },
            ],
          });
        }
        expect(request.url.path, '/api/v1/medications/batch');
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['scan_id'], 'scan-123');
        expect(payload['items'][0]['item_seq'], '12345');
        expect(payload['items'][0]['ingredient_code'], 'A01');
        return jsonResponse(
          [
            {'id': 'med-123', 'name': '정확한 약 10mg'},
          ],
          201,
        );
      }),
    );
    addTearDown(api.close);
    final result = await HttpOcrRepository(api: api).recognize(
      PrescriptionImage(
        bytes: base64Decode(imageData),
        filename: 'label.png',
        contentType: 'image/png',
      ),
    );
    final unchanged =
        result.items.single.edited(name: '정확한 약 10mg', frequency: 3);
    expect(unchanged.confidence, 0.92);
    final changed = unchanged.edited(name: '다른 약', frequency: 1);
    expect(changed.toJson(), containsPair('item_seq', null));
    expect(changed.ingredientName, isNull);
    expect(changed.ingredientCode, isNull);
    expect(changed.confidence, isNull);
    await MedicationRepository(api)
        .saveMedications(scanId: result.scanId, items: [unchanged]);
  });
  test(
      'manual save has no scan; schedules and DUR use the existing backend contract',
      () async {
    final paths = <String>[];
    final api = ApiClient(
      baseUrl: 'http://test/api/v1',
      deviceIdStore: DeviceIdStore(),
      httpClient: MockClient((request) async {
        paths.add(request.url.path);
        final payload = jsonDecode(request.body);
        if (request.url.path.endsWith('/batch')) {
          expect(payload['scan_id'], isNull);
          return jsonResponse(
            [
              {'id': 'new-med', 'name': '직접 입력'},
            ],
            201,
          );
        }
        if (request.url.path.endsWith('/schedules')) {
          expect(request.method, 'PUT');
          expect(payload['schedules'], [
            {'time_slot': 'morning', 'remind_at': '08:30:00'},
          ]);
          return jsonResponse([]);
        }
        expect(payload, isEmpty); // Backend includes all active drugs.
        return jsonResponse(
          {
            'id': 'check',
            'status': 'no_warnings',
            'provider': 'remote',
            'warnings': [],
            'disclaimer': '서버 상담 안내',
          },
          201,
        );
      }),
    );
    addTearDown(api.close);
    final medications = MedicationRepository(api);
    await medications
        .saveMedications(items: [const MedicationDraft(name: '직접 입력')]);
    await medications.saveSchedules(
      'new-med',
      [const MedicationSchedule(timeSlot: 'morning', remindAt: '08:30:00')],
    );
    expect((await DurRepository(api).check()).disclaimer, '서버 상담 안내');
    expect(paths, [
      '/api/v1/medications/batch',
      '/api/v1/medications/new-med/schedules',
      '/api/v1/dur-checks',
    ]);
  });
  test('malformed successful batch response becomes an ambiguous API error',
      () async {
    final api = ApiClient(
      baseUrl: 'http://test',
      deviceIdStore: DeviceIdStore(),
      httpClient:
          MockClient((_) async => jsonResponse({'unexpected': true}, 201)),
    );
    addTearDown(api.close);
    await expectLater(
      MedicationRepository(api)
          .saveMedications(items: [const MedicationDraft(name: '약')]),
      throwsA(
        isA<ApiException>()
            .having((error) => error.code, 'code', 'MALFORMED_RESPONSE'),
      ),
    );
  });
  test(
      'bootstrap persists name only after server success and uses the same device ID',
      () async {
    final store = DeviceIdStore();
    final identifiers =
        await Future.wait(List.generate(10, (_) => store.readOrCreate()));
    expect(identifiers.toSet().length, 1);
    var fail = true;
    final api = ApiClient(
      baseUrl: 'http://test/api/v1',
      deviceIdStore: store,
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body);
        expect(body['device_id'], request.headers['X-Device-ID']);
        return fail
            ? jsonResponse({'code': 'UNAVAILABLE', 'message': '실패'}, 503)
            : jsonResponse({'id': 'user'});
      }),
    );
    addTearDown(api.close);
    final users = UserRepository(api, store);
    await expectLater(users.register('테스트'), throwsA(isA<ApiException>()));
    expect(await users.savedName(), isNull);
    fail = false;
    await users.register('테스트');
    expect(await users.savedName(), '테스트');
  });
}
