import '../../core/api_client.dart';
import '../../core/json_decode.dart';

class DurWarning {
  const DurWarning({
    required this.type,
    required this.medicationIds,
    required this.message,
    this.sourceCode,
  });
  final String type;
  final List<String> medicationIds;
  final String message;
  final String? sourceCode;
  factory DurWarning.fromJson(Map<String, dynamic> json) => DurWarning(
        type: json['warning_type'] as String,
        medicationIds: (json['medication_ids'] as List<dynamic>).cast<String>(),
        message: json['message'] as String,
        sourceCode: json['source_code'] as String?,
      );
}

class DurResult {
  const DurResult({
    required this.id,
    required this.status,
    required this.provider,
    required this.warnings,
    required this.disclaimer,
  });
  final String id;
  final String status;
  final String provider;
  final List<DurWarning> warnings;
  final String disclaimer;
  factory DurResult.fromJson(Map<String, dynamic> json) => DurResult(
        id: json['id'] as String,
        status: json['status'] as String,
        provider: json['provider'] as String,
        warnings: (json['warnings'] as List<dynamic>)
            .map((item) => DurWarning.fromJson(item as Map<String, dynamic>))
            .toList(),
        disclaimer: json['disclaimer'] as String,
      );
}

abstract interface class DurDataSource {
  Future<DurResult> check();
  Future<DurResult> getResult(String id);
}

class DurRepository implements DurDataSource {
  const DurRepository(this.api);
  final ApiClient api;
  @override
  Future<DurResult> check() async => decodeResponse(
        await api.post('/dur-checks', body: <String, dynamic>{}),
        (value) => DurResult.fromJson(value as Map<String, dynamic>),
      );
  @override
  Future<DurResult> getResult(String id) async => decodeResponse(
        await api.get('/dur-checks/$id'),
        (value) => DurResult.fromJson(value as Map<String, dynamic>),
      );
}

class MockDurRepository implements DurDataSource {
  const MockDurRepository();
  @override
  Future<DurResult> check() async => const DurResult(
        id: 'demo-check',
        status: 'warnings',
        provider: 'mock',
        warnings: [
          DurWarning(
            type: 'demo_warning',
            medicationIds: [],
            message: '시연용 주의사항입니다. 실제 의약 정보가 아닙니다.',
          ),
        ],
        disclaimer: '예시 결과입니다. 실제 약에 대한 확인은 의사·약사와 상담하세요.',
      );
  @override
  Future<DurResult> getResult(String id) => check();
}
