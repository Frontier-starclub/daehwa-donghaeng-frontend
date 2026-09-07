/// 백엔드 `MedicationEventOut` / `MedicationOut` 대응 모델.
library;

class MedicationEvent {
  const MedicationEvent({
    required this.id,
    required this.medicationId,
    required this.medicationName,
    required this.timeSlot,
    required this.remindAt,
    required this.status,
  });

  final String id;
  final String medicationId;
  final String medicationName;
  final String timeSlot;

  /// "08:00:00" 형태의 로컬 알림 시각.
  final String remindAt;

  /// pending | taken | not_taken
  final String status;

  bool get isAnswered => status != 'pending';
  bool get wasTaken => status == 'taken';

  /// "08:00" — 초를 떼고 화면에 쓸 형태.
  String get displayTime =>
      remindAt.length >= 5 ? remindAt.substring(0, 5) : remindAt;

  /// 화면설계서 문구 기준. IT 용어를 쓰지 않는다.
  String get timeSlotLabel => switch (timeSlot) {
        'morning' => '아침',
        'lunch' => '점심',
        'dinner' => '저녁',
        'bedtime' => '자기 전',
        _ => '',
      };

  factory MedicationEvent.fromJson(Map<String, dynamic> json) =>
      MedicationEvent(
        id: json['id'] as String,
        medicationId: json['medication_id'] as String,
        medicationName: json['medication_name'] as String,
        timeSlot: json['time_slot'] as String,
        remindAt: json['remind_at'] as String,
        status: json['status'] as String,
      );
}

class Medication {
  const Medication({
    required this.id,
    required this.name,
    this.doseFrequencyPerDay,
  });

  final String id;
  final String name;
  final int? doseFrequencyPerDay;

  factory Medication.fromJson(Map<String, dynamic> json) => Medication(
        id: json['id'] as String,
        name: json['name'] as String,
        doseFrequencyPerDay: json['dose_frequency_per_day'] as int?,
      );
}
