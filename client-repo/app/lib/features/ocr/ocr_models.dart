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
  const MedicationDraft({
    required this.name,
    this.doseFrequencyPerDay,
    this.ingredientName,
    this.ingredientCode,
    this.itemSeq,
    this.confidence,
  });
  final String name;
  final int? doseFrequencyPerDay;
  final String? ingredientName;
  final String? ingredientCode;
  final String? itemSeq;
  final double? confidence;

  MedicationDraft edited({required String name, int? frequency}) {
    final unchanged = name.trim() == this.name.trim();
    return MedicationDraft(
      name: name.trim(),
      doseFrequencyPerDay: frequency,
      ingredientName: unchanged ? ingredientName : null,
      ingredientCode: unchanged ? ingredientCode : null,
      itemSeq: unchanged ? itemSeq : null,
      confidence: unchanged ? confidence : null,
    );
  }

  factory MedicationDraft.fromJson(Map<String, dynamic> json) =>
      MedicationDraft(
        name: json['name'] as String,
        doseFrequencyPerDay: json['dose_frequency_per_day'] as int?,
        ingredientName: json['ingredient_name'] as String?,
        ingredientCode: json['ingredient_code'] as String?,
        itemSeq: json['item_seq'] as String?,
        confidence: (json['confidence'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'dose_frequency_per_day': doseFrequencyPerDay,
        'ingredient_name': ingredientName,
        'ingredient_code': ingredientCode,
        'item_seq': itemSeq,
        'confidence': confidence,
      };
}

class OcrResult {
  const OcrResult({required this.items, this.scanId, this.provider});
  final List<MedicationDraft> items;
  final String? scanId;
  final String? provider;

  factory OcrResult.fromJson(Map<String, dynamic> json) => OcrResult(
        scanId: json['id'] as String,
        provider: json['provider'] as String,
        items: (json['items'] as List<dynamic>)
            .map(
              (item) => MedicationDraft.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
      );
}
