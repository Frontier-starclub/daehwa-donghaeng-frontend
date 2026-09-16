import 'ocr_models.dart';

abstract interface class OcrRepository {
  Future<OcrResult> recognize(PrescriptionImage image);
}
