// Phase1 완료 기준 검증.
//
// 백엔드가 떠 있어야 한다:
//   cd ../daehwa-donghaeng && docker compose up -d
//
// 실행:
//   flutter test integration_test/round_trip_test.dart
//
// 검증 흐름: bootstrap → 약 등록 → 오늘의 약 조회 → 복약 응답

import 'package:daehwa_donghaeng/core/api_client.dart';
import 'package:daehwa_donghaeng/core/device_id_store.dart';
import 'package:daehwa_donghaeng/features/medication/medication_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ApiClient api;
  late MedicationRepository repository;
  late String deviceId;

  setUp(() async {
    // 테스트마다 새 사용자를 쓴다 — 기존 복약 기록에 영향받지 않게.
    SharedPreferences.setMockInitialValues({});
    final store = DeviceIdStore();
    deviceId = await store.readOrCreate();
    api = ApiClient(baseUrl: ApiClient.emulatorBaseUrl, deviceIdStore: store);
    repository = MedicationRepository(api);
  });

  tearDown(() => api.close());

  testWidgets('bootstrap → 약 등록 → 오늘의 약 → 복약 응답', (tester) async {
    await repository.bootstrap(deviceId: deviceId, displayName: '테스트');

    // 약 1건 등록 + 알림 시각 1건 설정
    final medications = await api.post(
      '/medications/batch',
      body: {
        'items': [
          {'name': '테스트약', 'dose_frequency_per_day': 1},
        ],
      },
    ) as List<dynamic>;
    final medicationId = (medications.first as Map<String, dynamic>)['id'];

    await api.put(
      '/medications/$medicationId/schedules',
      body: {
        'schedules': [
          {'time_slot': 'morning', 'remind_at': '08:00:00'},
        ],
      },
    );

    // 서버가 조회 시점에 오늘치 일정을 만들어 준다.
    final events = await repository.todayEvents();
    expect(events, isNotEmpty);
    expect(events.first.medicationName, '테스트약');
    expect(events.first.status, 'pending');

    final answered = await repository.respondToEvent(
      eventId: events.first.id,
      taken: true,
    );
    expect(answered.status, 'taken');
    expect(answered.wasTaken, isTrue);
  });
}
