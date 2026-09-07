import '../../core/api_client.dart';
import '../../core/api_exception.dart';
import 'ocr_models.dart';
import 'ocr_repository.dart';

typedef OcrResponseDecoder = List<MedicationDraft> Function(dynamic response);

/// 백엔드 명세를 받은 후 경로와 decoder를 주입한다. AI 서비스 직접 호출 금지.
class HttpOcrRepository implements OcrRepository {
  const HttpOcrRepository({
    required this.api,
    required this.path,
    required this.decode,
  });
  final ApiClient api;
  final String path;
  final OcrResponseDecoder decode;

  @override
  Future<List<MedicationDraft>> recognize(PrescriptionImage image) async {
    final response = await api.uploadImage(
      path,
      bytes: image.bytes,
      filename: image.filename,
      contentType: image.contentType,
    );
    try {
      return decode(response);
    } on FormatException catch (error) {
      throw ApiException.malformed(error);
    } on TypeError catch (error) {
      throw ApiException.malformed(error);
    }
  }
}

class UnconfiguredOcrRepository implements OcrRepository {
  const UnconfiguredOcrRepository();
  @override
  Future<List<MedicationDraft>> recognize(PrescriptionImage image) async {
    throw const ApiException(
      statusCode: 0,
      code: 'OCR_NOT_CONFIGURED',
      message: '사진으로 약을 읽는 기능을 준비하고 있어요. 직접 입력해 주세요.',
    );
  }
}
