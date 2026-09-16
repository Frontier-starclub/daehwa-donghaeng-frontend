import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:daehwa_donghaeng/core/api_exception.dart';
import 'package:daehwa_donghaeng/design/tokens.dart';
import 'package:daehwa_donghaeng/features/chat/chat_repository.dart';
import 'package:daehwa_donghaeng/features/chat/chat_screen.dart';
import 'package:daehwa_donghaeng/features/dur/dur_repository.dart';
import 'package:daehwa_donghaeng/features/dur/dur_screen.dart';
import 'package:daehwa_donghaeng/features/medication/medication_models.dart';
import 'package:daehwa_donghaeng/features/medication/mock_medication_repository.dart';
import 'package:daehwa_donghaeng/features/medication/schedule_screen.dart';
import 'package:daehwa_donghaeng/features/ocr/ocr_models.dart';
import 'chat_controller_test.dart' show TestVoice;

class RetrySchedules extends MockMedicationRepository {
  int scheduleCalls = 0;
  int batchCalls = 0;
  @override
  Future<List<Medication>> saveMedications({
    String? scanId,
    required List<MedicationDraft> items,
  }) {
    batchCalls++;
    return super.saveMedications(scanId: scanId, items: items);
  }

  @override
  Future<void> saveSchedules(
    String medicationId,
    List<MedicationSchedule> schedules,
  ) async {
    scheduleCalls++;
    if (scheduleCalls == 1) throw ApiException.timeout('schedule');
    await super.saveSchedules(medicationId, schedules);
  }
}

class TestDur implements DurDataSource {
  TestDur({this.failFirst = false, this.status = 'no_warnings'});
  final bool failFirst;
  final String status;
  int calls = 0;
  @override
  Future<DurResult> check() async {
    calls++;
    if (failFirst && calls == 1) {
      throw const ApiException(
        statusCode: 502,
        code: 'DUR_PROVIDER_ERROR',
        message: '주의사항을 확인하지 못했습니다.',
      );
    }
    return DurResult(
      id: 'check',
      status: status,
      provider: 'remote',
      warnings: [
        if (status == 'warnings')
          const DurWarning(
            type: 'elderly_caution',
            medicationIds: ['demo-medication'],
            message: '서버 주의사항',
          ),
      ],
      disclaimer: '서버에서 받은 상담 안내',
    );
  }

  @override
  Future<DurResult> getResult(String id) => check();
}

void main() {
  Future<void> tap(WidgetTester tester, String label) async {
    final finder = find.text(label);
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(finder.last);
    await tester.tap(finder.last);
    await tester.pumpAndSettle();
  }

  testWidgets(
      'schedule failure retries only time settings, not medication registration',
      (tester) async {
    final repository = RetrySchedules();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => ScheduleScreen(
                    medication:
                        const Medication(id: 'demo-medication', name: '예시약 A'),
                    repository: repository,
                  ),
                ),
              ),
              child: const Text('설정 열기'),
            ),
          ),
        ),
      ),
    );
    await tap(tester, '설정 열기');
    final saveButton = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '이 시간으로 저장'));
    expect(
      saveButton.onPressed,
      isNull,
    ); // No assumed time from daily frequency.
    await tap(tester, '시간 추가하기');
    await tap(tester, '선택');
    await tap(tester, '이 시간으로 저장');
    expect(find.textContaining('응답이 늦어지고'), findsOneWidget);
    await tap(tester, '이 시간으로 저장');
    expect(repository.scheduleCalls, 2);
    expect(repository.batchCalls, 0);
    expect(find.text('설정 열기'), findsOneWidget);
  });
  testWidgets(
      'DUR retry preserves saved medication and renders server disclaimer',
      (tester) async {
    final medications = MockMedicationRepository();
    final dur = TestDur(failFirst: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: DurScreen(repository: dur, medications: medications),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('확인하지 못한 상태입니다.'), findsOneWidget);
    expect(find.text('조회된 주의사항이 없어요'), findsNothing);
    await tap(tester, '주의사항 다시 확인');
    expect(dur.calls, 2);
    expect(find.text('조회된 주의사항이 없어요'), findsOneWidget);
    expect(find.text('서버에서 받은 상담 안내'), findsOneWidget);
    expect((await medications.activeMedications()).length, 1);
  });
  testWidgets('warning result associates warning with saved medication name',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: DurScreen(
          repository: TestDur(status: 'warnings'),
          medications: MockMedicationRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('예시약 A'), findsOneWidget);
    expect(find.text('서버 주의사항'), findsOneWidget);
    expect(find.text('조회된 주의사항이 없어요'), findsNothing);
  });
  testWidgets(
      'large-font voice screen permits typing after microphone rejection',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final voice = TestVoice()..available = false;
    final repository = MockChatRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: ChatScreen(repository: repository, voice: voice),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, '네, 좋아요');
    await tap(tester, '마이크로 말하기');
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(TextField),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextField), '글로 인사해요');
    await tester.pumpAndSettle();
    await tap(tester, '이 내용 보내기');
    expect((await repository.current())!.messages.length, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(voice.stops, greaterThan(0));
  });
}
