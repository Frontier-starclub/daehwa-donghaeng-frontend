import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:daehwa_donghaeng/core/api_client.dart';
import 'package:daehwa_donghaeng/core/api_exception.dart';
import 'package:daehwa_donghaeng/core/device_id_store.dart';
import 'package:daehwa_donghaeng/features/onboarding/user_repository.dart';
import 'package:daehwa_donghaeng/features/ocr/http_ocr_repository.dart';
import 'package:daehwa_donghaeng/features/ocr/ocr_models.dart';
import 'package:daehwa_donghaeng/features/medication/medication_models.dart';
import 'package:daehwa_donghaeng/features/medication/medication_repository.dart';
import 'package:daehwa_donghaeng/features/dur/dur_repository.dart';
import 'package:daehwa_donghaeng/features/chat/chat_repository.dart';
import 'package:uuid/uuid.dart';

class RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('RUN_BACKEND_INTEGRATION');
  test(
    'real backend: bootstrap → OCR → save → schedule → DUR → chat → recover',
    () async {
      await HttpOverrides.runWithHttpOverrides(
        () async {
          SharedPreferences.setMockInitialValues({});
          final store = DeviceIdStore();
          final api = ApiClient(
            baseUrl: const String.fromEnvironment(
              'TEST_API_BASE_URL',
              defaultValue: 'http://127.0.0.1:18090/api/v1',
            ),
            deviceIdStore: store,
          );
          addTearDown(api.close);
          final watch = Stopwatch()..start();
          final users = UserRepository(api, store);
          await users.register('프론트 통합 테스트');
          final ocr = HttpOcrRepository(api: api);
          final image = PrescriptionImage(
            bytes: base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=',
            ),
            filename: 'fixture.png',
            contentType: 'image/png',
          );
          final scan = await ocr.recognize(image);
          expect(scan.scanId, isNotEmpty);
          expect(scan.provider, 'mock');
          final meds = MedicationRepository(api);
          final saved = await meds.saveMedications(
            scanId: scan.scanId,
            items: scan.items,
          );
          expect(saved.length, 2);
          final manual = await meds.saveMedications(
            items: [const MedicationDraft(name: '직접 입력 검증')],
          );
          expect(manual.single.name, '직접 입력 검증');
          expect((await meds.activeMedications()).length, 3);
          await meds.saveSchedules(saved.first.id, [
            const MedicationSchedule(timeSlot: 'morning', remindAt: '08:00:00'),
          ]);
          final events = await meds.todayEvents();
          expect(events.length, 1);
          await meds.respondToEvent(eventId: events.single.id, taken: true);
          expect((await meds.todayEvents()).single.wasTaken, isTrue);
          final dur = DurRepository(api);
          final checked = await dur.check();
          expect(checked.status, 'no_warnings');
          expect(checked.disclaimer, isNotEmpty);
          expect((await dur.getResult(checked.id)).id, checked.id);
          final chat = ChatRepository(api);
          final session = await chat.start(accepted: true);
          final clientId = const Uuid().v4();
          final turn = await chat.send(
            session.id,
            clientMessageId: clientId,
            content: '오늘 산책했어요',
          );
          final duplicate = await chat.send(
            session.id,
            clientMessageId: clientId,
            content: '오늘 산책했어요',
          );
          expect(duplicate.user.id, turn.user.id);
          expect(duplicate.assistant.id, turn.assistant.id);
          expect((await chat.current())!.messages.length, 3);
          await chat.end(session.id);
          await chat.end(session.id);
          expect(await chat.current(), isNull);
          expect((await chat.start(accepted: false)).status, 'declined');

          // Development-only scenario requests verify UI error contracts without external AI.
          await expectLater(
            api.uploadImage(
              '/medication-scans',
              bytes: image.bytes,
              filename: image.filename,
              contentType: image.contentType,
              query: {'scenario': 'empty'},
            ),
            throwsA(
              isA<ApiException>().having((e) => e.code, 'code', 'OCR_EMPTY'),
            ),
          );
          await expectLater(
            api.post('/dur-checks', body: {}, query: {'scenario': 'failure'}),
            throwsA(
              isA<ApiException>()
                  .having((e) => e.code, 'code', 'DUR_PROVIDER_ERROR'),
            ),
          );
          final warning = DurResult.fromJson(
            await api.post(
              '/dur-checks',
              body: {},
              query: {'scenario': 'warning'},
            ) as Map<String, dynamic>,
          );
          expect(warning.warnings.single.type, 'demo_warning');
          expect((await meds.activeMedications()).length, 3);
          watch.stop();
          // ignore: avoid_print
          print(
            'Backend HTTP flow passed in ${watch.elapsedMilliseconds} ms (mock AI, isolated SQLite)',
          );
        },
        RealHttp(),
      );
    },
    skip: !enabled,
  );
}
