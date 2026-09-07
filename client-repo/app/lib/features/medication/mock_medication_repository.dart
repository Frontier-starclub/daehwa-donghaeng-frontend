import 'medication_models.dart';
import 'medication_repository.dart';

/// 서버에 기록하지 않는 프론트엔드 시연 데이터.
class MockMedicationRepository implements MedicationDataSource {
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
  Future<List<Medication>> activeMedications() async => const [
        Medication(id: 'demo-medication', name: '예시약 A'),
      ];

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
