import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/api_exception.dart';
import 'ocr_models.dart';

abstract interface class PrescriptionImagePicker {
  Future<PrescriptionImage?> pick(ImageSource source);
  Future<PrescriptionImage?> recover();
}

class DevicePrescriptionImagePicker implements PrescriptionImagePicker {
  DevicePrescriptionImagePicker({ImagePicker? picker})
      : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  @override
  Future<PrescriptionImage?> pick(ImageSource source) async {
    try {
      final file = await _picker.pickImage(source: source);
      return file == null ? null : await _read(file);
    } on PlatformException catch (error) {
      throw ApiException(
        statusCode: 0,
        code: 'IMAGE_PICK_FAILED',
        message: '사진을 가져오지 못했어요. 권한을 확인하거나 직접 입력해 주세요.',
        details: error,
      );
    }
  }

  @override
  Future<PrescriptionImage?> recover() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    final result = await _picker.retrieveLostData();
    if (result.exception != null) {
      throw const ApiException(
        statusCode: 0,
        code: 'IMAGE_RECOVERY_FAILED',
        message: '사진을 다시 선택해 주세요.',
      );
    }
    final files = result.files;
    return files == null || files.isEmpty ? null : _read(files.first);
  }

  Future<PrescriptionImage> _read(XFile file) async {
    if (await file.length() > PrescriptionImage.maxBytes) {
      throw const ApiException(
        statusCode: 413,
        code: 'IMAGE_TOO_LARGE',
        message: '사진이 너무 커요. 10MiB 이하의 사진을 선택해 주세요.',
      );
    }
    final bytes = await file.readAsBytes();
    final png = bytes.length >= 8 &&
        listEquals(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final jpeg = bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    if (!png && !jpeg) {
      throw const ApiException(
        statusCode: 415,
        code: 'UNSUPPORTED_IMAGE',
        message: 'JPEG 또는 PNG 사진을 선택해 주세요.',
      );
    }
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1200);
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
    return PrescriptionImage(
      bytes: bytes,
      filename: png ? 'label.png' : 'label.jpg',
      contentType: png ? 'image/png' : 'image/jpeg',
    );
  }
}
