import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:daehwa_donghaeng/main.dart';
import 'package:daehwa_donghaeng/features/medication/mock_medication_repository.dart';
import 'package:daehwa_donghaeng/features/ocr/mock_ocr_repository.dart';
import 'package:daehwa_donghaeng/features/ocr/ocr_models.dart';
import 'package:daehwa_donghaeng/features/ocr/prescription_image_picker.dart';

class WidgetPicker implements PrescriptionImagePicker {
  @override
  Future<PrescriptionImage?> recover() async => null;
  @override
  Future<PrescriptionImage?> pick(ImageSource source) async =>
      PrescriptionImage(
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=',
        ),
        filename: 'sample.png',
        contentType: 'image/png',
      );
}

void main() {
  testWidgets('small screen with large text supports manual entry',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      DaehwaApp(
        repository: MockMedicationRepository(),
        ocrRepository: const MockOcrRepository(delay: Duration.zero),
        imagePicker: WidgetPicker(),
        isMock: true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('약 등록하기'), 250,
        scrollable: find.byType(Scrollable).first,);
    await tester.pumpAndSettle();
    await tester.tap(find.text('약 등록하기'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('직접 입력하기'), 250,
        scrollable: find.byType(Scrollable).first,);
    await tester.pumpAndSettle();
    await tester.tap(find.text('직접 입력하기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '큰 글씨 테스트');
    await tester.scrollUntilVisible(find.text('확인'), 250,
        scrollable: find.byType(Scrollable).first,);
    await tester.pumpAndSettle();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('큰 글씨 테스트'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('큰 글씨 테스트'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  Future<void> openApp(WidgetTester tester) async {
    await tester.pumpWidget(
      DaehwaApp(
        repository: MockMedicationRepository(),
        ocrRepository: const MockOcrRepository(delay: Duration.zero),
        imagePicker: WidgetPicker(),
        isMock: true,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String label) async {
    final finder = find.text(label).last;
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('home → manual input → confirm → home without saving medication',
      (tester) async {
    await openApp(tester);
    await tap(tester, '약 등록하기');
    await tap(tester, '직접 입력하기');
    await tap(tester, '확인');
    expect(find.text('약 이름을 입력해 주세요.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '직접 입력한 약');
    await tap(tester, '확인');
    expect(find.text('직접 입력한 약'), findsOneWidget);
    await tap(tester, '이 내용이 맞아요');
    expect(find.textContaining('약 등록과 주의사항 조회는 아직'), findsOneWidget);
    await tap(tester, '홈으로');
    expect(find.text('오늘의 약'), findsOneWidget);
    expect(find.text('직접 입력한 약'), findsNothing);
  });

  testWidgets('gallery → review → OCR → edit → delete', (tester) async {
    await openApp(tester);
    await tap(tester, '약 등록하기');
    await tap(tester, '사진 찍기');
    await tap(tester, '앨범에서 선택');
    expect(find.text('글씨가 잘 보이나요?'), findsOneWidget);
    await tap(tester, '이 사진 사용');
    expect(find.text('예시약 B'), findsOneWidget);
    await tap(tester, '수정');
    await tester.enterText(find.byType(TextFormField).first, '고친 약');
    await tap(tester, '확인');
    expect(find.text('고친 약'), findsOneWidget);
    await tap(tester, '삭제');
    await tap(tester, '삭제');
    expect(find.text('고친 약'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
