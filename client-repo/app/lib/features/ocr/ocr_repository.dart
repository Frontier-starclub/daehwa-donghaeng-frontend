import 'ocr_models.dart';

abstract interface class OcrRepository {
  Future<List<MedicationDraft>> recognize(PrescriptionImage image);
}
