import 'package:flutter/foundation.dart';
import '../../core/api_exception.dart';
import '../ocr/ocr_models.dart';
import 'medication_models.dart';
import 'medication_repository.dart';

enum RegistrationStatus { editing, saving, saved, uncertain }

class RegistrationController extends ChangeNotifier {
  RegistrationController(this.repository);
  final MedicationDataSource repository;
  RegistrationStatus status = RegistrationStatus.editing;
  List<Medication> medications = [];
  String? error;
  bool _disposed = false;

  Future<void> save({
    String? scanId,
    required List<MedicationDraft> items,
  }) async {
    if (status != RegistrationStatus.editing || items.isEmpty) return;
    status = RegistrationStatus.saving;
    error = null;
    notifyListeners();
    try {
      final result = await repository.saveMedications(
        scanId: scanId,
        items: List.of(items),
      );
      if (_disposed) return;
      if (result.length != items.length) {
        throw ApiException.malformed('Incomplete save response');
      }
      medications = result;
      status = RegistrationStatus.saved;
    } catch (failure) {
      if (_disposed) return;
      // Batch POST has no idempotency contract. A lost response may follow a commit.
      final knownRejection = failure is ApiException &&
          failure.statusCode >= 400 &&
          failure.statusCode < 500;
      status = knownRejection
          ? RegistrationStatus.editing
          : RegistrationStatus.uncertain;
      error = knownRejection
          ? (failure).message
          : '저장 결과를 확인하지 못했어요. 중복 등록을 피하려면 먼저 내 약 목록을 확인해 주세요.';
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
