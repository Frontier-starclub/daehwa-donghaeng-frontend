import 'medication_models.dart';
import 'medication_repository.dart';
import '../ocr/ocr_models.dart';
import 'package:uuid/uuid.dart';

/// 서버에 기록하지 않는 프론트엔드 시연 데이터.
class MockMedicationRepository implements MedicationDataSource {
  final List<Medication> _medications = [
    const Medication(id: 'demo-medication', name: '예시약 A'),
  ];
  final List<MedicationEvent> _events = [
    const MedicationEvent(
      id: 'demo-event',
      medicationId: 'demo-medication',
      medicationName: '예시약 A',
      timeSlot: 'morning',
      remindAt: '08:00:00',
      status: 'pending',
    ),
  ];

  @override
  Future<List<MedicationEvent>> todayEvents() async =>
      List.unmodifiable(_events);

  @override
  Future<List<Medication>> activeMedications() async =>
      List.unmodifiable(_medications);

  @override
  Future<List<Medication>> saveMedications({
    String? scanId,
    required List<MedicationDraft> items,
  }) async {
    final saved = items
        .map(
          (item) => Medication(
            id: const Uuid().v4(),
            name: item.name,
            doseFrequencyPerDay: item.doseFrequencyPerDay,
          ),
        )
        .toList();
    _medications.addAll(saved);
    return saved;
  }

  @override
  Future<void> saveSchedules(
    String medicationId,
    List<MedicationSchedule> schedules,
  ) async {
    final medication =
        _medications.firstWhere((item) => item.id == medicationId);
    _events.removeWhere((item) => item.medicationId == medicationId);
    _events.addAll(
      schedules.map(
        (item) => MedicationEvent(
          id: const Uuid().v4(),
          medicationId: medicationId,
          medicationName: medication.name,
          timeSlot: item.timeSlot,
          remindAt: item.remindAt,
          status: 'pending',
        ),
      ),
    );
    _events.sort((a, b) => a.remindAt.compareTo(b.remindAt));
  }

  @override
  Future<MedicationEvent> respondToEvent({
    required String eventId,
    required bool taken,
  }) async {
    final index = _events.indexWhere((event) => event.id == eventId);
    final old = _events[index];
    final updated = MedicationEvent(
      id: old.id,
      medicationId: old.medicationId,
      medicationName: old.medicationName,
      timeSlot: old.timeSlot,
      remindAt: old.remindAt,
      status: taken ? 'taken' : 'not_taken',
    );
    _events[index] = updated;
    return updated;
  }
}
