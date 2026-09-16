import 'dart:async';
import 'package:daehwa_donghaeng/core/api_exception.dart';
import 'package:daehwa_donghaeng/features/medication/medication_models.dart';
import 'package:daehwa_donghaeng/features/medication/mock_medication_repository.dart';
import 'package:daehwa_donghaeng/features/medication/registration_controller.dart';
import 'package:daehwa_donghaeng/features/ocr/ocr_models.dart';
import 'package:flutter_test/flutter_test.dart';

class PendingSave extends MockMedicationRepository {
  final pending = Completer<List<Medication>>();
  int calls = 0;
  String? receivedScanId;
  @override
  Future<List<Medication>> saveMedications({
    String? scanId,
    required List<MedicationDraft> items,
  }) {
    calls++;
    receivedScanId = scanId;
    return pending.future;
  }
}

void main() {
  const drafts = [MedicationDraft(name: '사용자가 확인한 약')];
  test('double submit sends one batch and cannot resubmit a committed batch',
      () async {
    final repository = PendingSave();
    final registration = RegistrationController(repository);
    addTearDown(registration.dispose);
    final first = registration.save(scanId: 'scan-1', items: drafts);
    await registration.save(scanId: 'scan-1', items: drafts);
    expect(repository.calls, 1);
    expect(repository.receivedScanId, 'scan-1');
    repository.pending
        .complete([const Medication(id: 'saved-1', name: '사용자가 확인한 약')]);
    await first;
    await registration.save(items: drafts);
    expect(repository.calls, 1);
    expect(registration.status, RegistrationStatus.saved);
  });
  for (final failure in [
    ApiException.timeout('test'),
    ApiException.network('test'),
    ApiException.malformed('test'),
  ]) {
    test('${failure.code} does not retry a potentially committed batch',
        () async {
      final repository = PendingSave();
      final registration = RegistrationController(repository);
      addTearDown(registration.dispose);
      final request = registration.save(items: drafts);
      repository.pending.completeError(failure);
      await request;
      expect(registration.status, RegistrationStatus.uncertain);
      await registration.save(items: drafts);
      expect(repository.calls, 1);
    });
  }
  test('known validation rejection preserves editable state', () async {
    final repository = PendingSave();
    final registration = RegistrationController(repository);
    addTearDown(registration.dispose);
    final request = registration.save(items: drafts);
    repository.pending.completeError(
      const ApiException(
        statusCode: 422,
        code: 'VALIDATION_ERROR',
        message: '입력을 확인해 주세요.',
      ),
    );
    await request;
    expect(registration.status, RegistrationStatus.editing);
  });
  test('disposing registration ignores late completion', () async {
    final repository = PendingSave();
    final registration = RegistrationController(repository);
    final request = registration.save(items: drafts);
    registration.dispose();
    repository.pending.complete([const Medication(id: 'saved', name: '약')]);
    await request;
  });
}
