import '../../core/api_client.dart';
import '../../core/json_decode.dart';
import '../../core/api_exception.dart';
import '../../core/reminders.dart';
import 'package:uuid/uuid.dart';
import '../ocr/ocr_models.dart';
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
  Future<List<Medication>> saveMedications({
    String? scanId,
    required List<MedicationDraft> items,
  });
  Future<void> saveSchedules(
    String medicationId,
    List<MedicationSchedule> schedules,
  );
}

abstract interface class MedicationManagement {
  Future<List<MedicationSchedule>> schedules(String medicationId);
  Future<void> endMedication(String medicationId);
  Future<void> renameMedication(String medicationId, String name);
  Future<List<MedicationEvent>> history(DateTime start, DateTime end);
}

class MedicationRepository
    implements MedicationDataSource, MedicationManagement {
  MedicationRepository(this._api, {this.reminders});

  final ApiClient _api;
  final ReminderService? reminders;

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
    final data = await _api.get('/medication-events/today');
    return decodeResponse(
      data,
      (value) => (value as List<dynamic>)
          .map(
            (item) => MedicationEvent.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
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
    );
    return decodeResponse(
      data,
      (value) => MedicationEvent.fromJson(value as Map<String, dynamic>),
    );
  }

  /// MED-07 — 내 약 목록.
  @override
  Future<List<Medication>> activeMedications() async {
    final data = await _api.get('/medications');
    return _decodeMedications(data);
  }

  List<Medication> _decodeMedications(dynamic data) => decodeResponse(
        data,
        (value) => (value as List<dynamic>)
            .map((item) => Medication.fromJson(item as Map<String, dynamic>))
            .toList(),
      );

  @override
  Future<List<Medication>> saveMedications({
    String? scanId,
    required List<MedicationDraft> items,
  }) async {
    final requestId = const Uuid().v4();
    dynamic data;
    try {
      data = await _api.post(
        '/medications/batch',
        body: {
          'request_id': requestId,
          'scan_id': scanId,
          'items': items.map((item) => item.toJson()).toList(),
        },
      );
    } catch (failure, stack) {
      if (failure is ApiException &&
          failure.statusCode >= 400 &&
          failure.statusCode < 500) {
        rethrow;
      }
      // Resolve a lost response without repeating a registration. A missing
      // result remains uncertain and the controller offers the medication list.
      try {
        data = await _api.get('/medication-registrations/$requestId');
      } catch (_) {
        Error.throwWithStackTrace(failure, stack);
      }
    }
    return _decodeMedications(data);
  }

  @override
  Future<void> saveSchedules(
    String medicationId,
    List<MedicationSchedule> schedules,
  ) async {
    await _api.put(
      '/medications/$medicationId/schedules',
      body: {
        'schedules': schedules.map((item) => item.toJson()).toList(),
      },
    );
    await reminders?.sync(requestPermission: true);
  }

  @override
  Future<List<MedicationSchedule>> schedules(String medicationId) async {
    final data =
        await _api.get('/medications/$medicationId/schedules') as List<dynamic>;
    return data
        .map(
          (item) => MedicationSchedule(
            timeSlot: item['time_slot'] as String,
            remindAt: item['remind_at'] as String,
          ),
        )
        .toList();
  }

  @override
  Future<void> endMedication(String medicationId) async {
    await _api.patch('/medications/$medicationId', body: {'status': 'ended'});
    await reminders?.sync();
  }

  @override
  Future<void> renameMedication(String medicationId, String name) async {
    await _api.patch('/medications/$medicationId', body: {'name': name});
  }

  @override
  Future<List<MedicationEvent>> history(DateTime start, DateTime end) async {
    final data = await _api.get(
      '/medication-events',
      query: {
        'start': start.toIso8601String().substring(0, 10),
        'end': end.toIso8601String().substring(0, 10),
      },
    ) as List<dynamic>;
    return data
        .map((item) => MedicationEvent.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
