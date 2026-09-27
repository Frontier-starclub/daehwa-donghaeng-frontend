import 'dart:convert';
import 'package:daehwa_donghaeng/core/api_client.dart';
import 'package:daehwa_donghaeng/core/device_id_store.dart';
import 'package:daehwa_donghaeng/features/medication/medication_models.dart';
import 'package:daehwa_donghaeng/features/medication/medication_repository.dart';
import 'package:daehwa_donghaeng/features/medication/schedule_screen.dart';
import 'package:daehwa_donghaeng/features/settings/profile_repository.dart';
import 'package:daehwa_donghaeng/features/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('loaded schedule can be cleared without removing medication',
      (tester) async {
    Object? saved;
    final api = ApiClient(
      baseUrl: 'http://fixture/api/v1',
      deviceIdStore: DeviceIdStore(),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/api/v1/medications/m1/schedules');
        if (request.method == 'PUT') {
          saved = jsonDecode(request.body);
          return http.Response('[]', 200);
        }
        return http.Response(
            jsonEncode([
              {'time_slot': 'morning', 'remind_at': '08:00:00'},
            ]),
            200,);
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(
        home: ScheduleScreen(
      medication: const Medication(id: 'm1', name: '가상약'),
      repository: MedicationRepository(api),
    ),),);
    await tester.pumpAndSettle();
    expect(find.text('08:00'), findsOneWidget);
    await tester.tap(find.text('이 시간 삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이 시간으로 저장'));
    await tester.pumpAndSettle();
    expect(saved, {'schedules': []});
  });

  testWidgets('onboarding works with all optional consent off', (tester) async {
    Map<String, dynamic>? saved;
    var done = false;
    final api = ApiClient(
      baseUrl: 'http://fixture/api/v1',
      deviceIdStore: DeviceIdStore(),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/consents')) {
          saved = jsonDecode(request.body);
        }
        return http.Response(
            jsonEncode({
              'consent': {},
              'chat_reminder_enabled': false,
              'chat_reminder_at': '19:00:00',
            }),
            200,);
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
      repository: ProfileRepository(api),
      onboarding: true,
      onDone: () => done = true,
    ),),);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('이 설정으로 시작하기'), 300);
    await tester.tap(find.text('이 설정으로 시작하기'));
    await tester.pumpAndSettle();
    expect(done, isTrue);
    expect(saved!['onboarding_completed'], isTrue);
    expect(saved!['analysis_allowed'], isFalse);
    expect(saved!['caregiver_share_allowed'], isFalse);
  });
}
