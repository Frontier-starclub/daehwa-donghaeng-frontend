import 'dart:typed_data';

class PrescriptionImage {
  const PrescriptionImage({
    required this.bytes,
    required this.filename,
    required this.contentType,
  });
  final Uint8List bytes;
  final String filename;
  final String contentType;
  static const maxBytes = 10 * 1024 * 1024;
}

/// 사용자 확인 전 임시 결과. 서버에 저장된 Medication과 구분한다.
class MedicationDraft {
  const MedicationDraft({required this.name, this.doseFrequencyPerDay});
  final String name;
  final int? doseFrequencyPerDay;
}
