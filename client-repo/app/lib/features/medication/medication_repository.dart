import '../../core/api_client.dart';
import 'medication_models.dart';

/// 복약 관련 API 호출.
///
/// 화면은 이 클래스만 보고, 경로 문자열이나 JSON 키를 직접 다루지 않는다.
abstract interface class MedicationDataSource {
  Future<List<MedicationEvent>> todayEvents();
  Future<MedicationEvent> respondToEvent({
    required String eventId,
    required bool taken,
  });
  Future<List<Medication>> activeMedications();
}

class MedicationRepository implements MedicationDataSource {
  const MedicationRepository(this._api);

  final ApiClient _api;

  /// 앱 최초 실행 시 사용자 등록. 같은 device_id면 기존 사용자를 돌려준다(멱등).
  Future<void> bootstrap({
    required String deviceId,
    required String displayName,
  }) async {
    await _api.post(
      '/users/bootstrap',
      body: {
        'device_id': deviceId,
        'display_name': displayName,
      },
    );
  }

  /// HOME-01 / MED-03 — 오늘의 복약 일정.
  ///
  /// 서버가 조회 시점에 오늘치 일정을 만들어 주므로 앱에서 따로 생성하지 않는다.
  @override
  Future<List<MedicationEvent>> todayEvents() async {
    final data = await _api.get('/medication-events/today') as List<dynamic>;
    return data
        .map((item) => MedicationEvent.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// MED-04 — "약을 드셨나요?" 예/아니오 응답.
  @override
  Future<MedicationEvent> respondToEvent({
    required String eventId,
    required bool taken,
  }) async {
    final data = await _api.put(
      '/medication-events/$eventId/response',
      body: {'status': taken ? 'taken' : 'not_taken'},
    ) as Map<String, dynamic>;
    return MedicationEvent.fromJson(data);
  }

  /// MED-07 — 내 약 목록.
  @override
  Future<List<Medication>> activeMedications() async {
    final data = await _api.get('/medications') as List<dynamic>;
    return data
        .map((item) => Medication.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
