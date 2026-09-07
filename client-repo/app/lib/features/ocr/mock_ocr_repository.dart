import '../../core/api_exception.dart';
import 'ocr_models.dart';
import 'ocr_repository.dart';

enum MockOcrScenario { success, empty, error, timeout }

class MockOcrRepository implements OcrRepository {
  const MockOcrRepository({
    this.scenario = MockOcrScenario.success,
    this.delay = const Duration(milliseconds: 800),
  });
  final MockOcrScenario scenario;
  final Duration delay;

  @override
  Future<List<MedicationDraft>> recognize(PrescriptionImage image) async {
    await Future<void>.delayed(delay);
    switch (scenario) {
      case MockOcrScenario.success:
        return const [
          MedicationDraft(name: '예시약 A'),
          MedicationDraft(name: '예시약 B'),
        ];
      case MockOcrScenario.empty:
        return const [];
      case MockOcrScenario.error:
        throw const ApiException(
          statusCode: 502,
          code: 'OCR_PROVIDER_ERROR',
          message: '약봉투를 읽지 못했어요. 다시 찍거나 직접 입력해 주세요.',
        );
      case MockOcrScenario.timeout:
        throw ApiException.timeout('mock timeout');
    }
  }
}
