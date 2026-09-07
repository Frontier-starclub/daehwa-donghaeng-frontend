import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:daehwa_donghaeng/features/ocr/ocr_flow_controller.dart';
import 'package:daehwa_donghaeng/features/ocr/ocr_models.dart';
import 'package:daehwa_donghaeng/features/ocr/ocr_repository.dart';
import 'package:daehwa_donghaeng/features/ocr/mock_ocr_repository.dart';
import 'package:daehwa_donghaeng/features/ocr/prescription_image_picker.dart';

class TestPicker implements PrescriptionImagePicker {
  PrescriptionImage? value = PrescriptionImage(
    bytes: Uint8List.fromList([1]),
    filename: 'test.png',
    contentType: 'image/png',
  );
  @override
  Future<PrescriptionImage?> pick(ImageSource source) async => value;
  @override
  Future<PrescriptionImage?> recover() async => null;
}

class PendingOcr implements OcrRepository {
  final pending = Completer<List<MedicationDraft>>();
  @override
  Future<List<MedicationDraft>> recognize(PrescriptionImage image) =>
      pending.future;
}

void main() {
  test('cancel ignores late OCR result and preserves edited draft', () async {
    final repository = PendingOcr();
    final flow =
        OcrFlowController(repository: repository, picker: TestPicker());
    addTearDown(flow.dispose);
    flow.saveDraft(const MedicationDraft(name: '수정한 약'));
    await flow.pick(ImageSource.gallery);
    final request = flow.recognize();
    flow.go(OcrStep.photo);
    repository.pending.complete([const MedicationDraft(name: '늦게 온 약')]);
    await request;
    expect(flow.step, OcrStep.photo);
    expect(flow.items.single.name, '수정한 약');
  });

  test('dispose ignores pending OCR completion', () async {
    final repository = PendingOcr();
    final flow =
        OcrFlowController(repository: repository, picker: TestPicker());
    await flow.pick(ImageSource.gallery);
    final request = flow.recognize();
    flow.dispose();
    repository.pending.complete([const MedicationDraft(name: '약')]);
    await request;
  });

  for (final scenario in [
    MockOcrScenario.empty,
    MockOcrScenario.error,
    MockOcrScenario.timeout,
  ]) {
    test('$scenario offers error state', () async {
      final flow = OcrFlowController(
        repository: MockOcrRepository(scenario: scenario, delay: Duration.zero),
        picker: TestPicker(),
      );
      addTearDown(flow.dispose);
      await flow.pick(ImageSource.gallery);
      await flow.recognize();
      expect(flow.step, OcrStep.error);
      expect(flow.message, isNotEmpty);
      flow.saveDraft(const MedicationDraft(name: '직접 입력'));
      expect(flow.step, OcrStep.result);
    });
  }

  test('edit trims names; empty results cannot be confirmed', () {
    final flow = OcrFlowController(
      repository: const MockOcrRepository(),
      picker: TestPicker(),
    );
    addTearDown(flow.dispose);
    expect(
      () => flow.saveDraft(const MedicationDraft(name: '  ')),
      throwsArgumentError,
    );
    flow.saveDraft(const MedicationDraft(name: ' 약 A '));
    flow.saveDraft(const MedicationDraft(name: '약 B'), index: 0);
    expect(flow.items.single.name, '약 B');
    flow.removeDraft(0);
    flow.confirm();
    expect(flow.step, OcrStep.result);
  });

  test('photo picker cancellation retains existing image and step', () async {
    final picker = TestPicker();
    final flow = OcrFlowController(
      repository: const MockOcrRepository(),
      picker: picker,
    );
    addTearDown(flow.dispose);
    await flow.pick(ImageSource.gallery);
    final old = flow.image;
    picker.value = null;
    flow.go(OcrStep.capture);
    await flow.pick(ImageSource.camera);
    expect(flow.image, same(old));
    expect(flow.step, OcrStep.capture);
    expect(flow.picking, isFalse);
  });
}
