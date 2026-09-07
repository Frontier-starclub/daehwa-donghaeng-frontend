import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/api_exception.dart';
import 'ocr_models.dart';
import 'ocr_repository.dart';
import 'prescription_image_picker.dart';

enum OcrStep { start, capture, photo, processing, result, error, complete }

class OcrFlowController extends ChangeNotifier {
  OcrFlowController({required this.repository, required this.picker});
  final OcrRepository repository;
  final PrescriptionImagePicker picker;
  OcrStep step = OcrStep.start;
  PrescriptionImage? image;
  List<MedicationDraft> _items = [];
  List<MedicationDraft> get items => List.unmodifiable(_items);
  String? message;
  bool picking = false;
  int _generation = 0;
  bool _disposed = false;

  void go(OcrStep next) {
    _generation++;
    picking = false;
    message = null;
    step = next;
    notifyListeners();
  }

  Future<void> pick(ImageSource source) => _pick(() => picker.pick(source));
  Future<void> recover() => _pick(picker.recover);

  Future<void> _pick(Future<PrescriptionImage?> Function() request) async {
    if (picking) return;
    final ticket = ++_generation;
    picking = true;
    message = null;
    notifyListeners();
    try {
      final selected = await request();
      if (!_current(ticket)) return;
      if (selected != null) {
        image = selected;
        step = OcrStep.photo;
      }
    } catch (error) {
      if (!_current(ticket)) return;
      message = error is ApiException
          ? error.message
          : '사진을 열지 못했어요. 다른 사진을 선택하거나 직접 입력해 주세요.';
      step = OcrStep.capture;
    } finally {
      if (_current(ticket)) {
        picking = false;
        notifyListeners();
      }
    }
  }

  Future<void> recognize() async {
    if (image == null || step == OcrStep.processing) return;
    final ticket = ++_generation;
    step = OcrStep.processing;
    message = null;
    notifyListeners();
    try {
      final result = await repository.recognize(image!);
      if (!_current(ticket)) return;
      if (result.isEmpty ||
          result.length > 30 ||
          result.any(
            (item) =>
                item.name.trim().isEmpty ||
                item.name.trim().length > 100 ||
                (item.doseFrequencyPerDay != null &&
                    (item.doseFrequencyPerDay! < 1 ||
                        item.doseFrequencyPerDay! > 10)),
          )) {
        message = '약 이름을 읽지 못했어요. 다시 찍거나 직접 입력해 주세요.';
        step = OcrStep.error;
      } else {
        _items = List.of(result);
        step = OcrStep.result;
      }
    } catch (error) {
      if (!_current(ticket)) return;
      message =
          error is ApiException ? error.message : '약봉투를 읽지 못했어요. 다시 시도해 주세요.';
      step = OcrStep.error;
    }
    if (_current(ticket)) notifyListeners();
  }

  void saveDraft(MedicationDraft value, {int? index}) {
    final name = value.name.trim();
    if (name.isEmpty || name.length > 100) {
      throw ArgumentError('Invalid medication name');
    }
    final frequency = value.doseFrequencyPerDay;
    if (frequency != null && (frequency < 1 || frequency > 10)) {
      throw ArgumentError('Invalid frequency');
    }
    final draft = MedicationDraft(name: name, doseFrequencyPerDay: frequency);
    if (index == null) {
      if (_items.length >= 30) throw StateError('Too many medications');
      _items.add(draft);
    } else {
      _items[index] = draft;
    }
    go(OcrStep.result);
  }

  void removeDraft(int index) {
    _items.removeAt(index);
    notifyListeners();
  }

  void confirm() {
    if (_items.isNotEmpty) go(OcrStep.complete);
  }

  bool _current(int ticket) => !_disposed && ticket == _generation;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
