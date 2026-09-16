import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../../design/tokens.dart';
import '../ocr_flow_controller.dart';
import '../ocr_models.dart';
import '../ocr_repository.dart';
import '../prescription_image_picker.dart';
import 'medication_edit_screen.dart';
import '../../medication/medication_repository.dart';
import '../../medication/registration_controller.dart';
import '../../medication/schedule_screen.dart';
import '../../medication/medication_list_screen.dart';
import '../../dur/dur_repository.dart';
import '../../dur/dur_screen.dart';

/// OCR-01~07/E1. 공통 AppBar와 진행 상태를 공유하는 단계별 화면.
class RegistrationFlowScreen extends StatefulWidget {
  const RegistrationFlowScreen({
    super.key,
    required this.repository,
    required this.picker,
    required this.isMock,
    required this.medications,
    required this.dur,
  });
  final OcrRepository repository;
  final PrescriptionImagePicker picker;
  final bool isMock;
  final MedicationDataSource medications;
  final DurDataSource dur;
  @override
  State<RegistrationFlowScreen> createState() => _RegistrationFlowScreenState();
}

class _RegistrationFlowScreenState extends State<RegistrationFlowScreen> {
  late final OcrFlowController flow;
  late final RegistrationController registration;
  final Set<String> _scheduled = {};
  @override
  void initState() {
    super.initState();
    flow =
        OcrFlowController(repository: widget.repository, picker: widget.picker);
    registration = RegistrationController(widget.medications);
    flow.recover();
  }

  @override
  void dispose() {
    flow.dispose();
    registration.dispose();
    super.dispose();
  }

  Future<void> _edit([int? index]) async {
    final value = await Navigator.push<MedicationDraft>(
      context,
      MaterialPageRoute(
        builder: (_) => MedicationEditScreen(
          initial: index == null ? null : flow.items[index],
        ),
      ),
    );
    if (mounted && value != null) flow.saveDraft(value, index: index);
  }

  void _back() {
    if (registration.status == RegistrationStatus.saving) return;
    if (registration.status == RegistrationStatus.saved ||
        registration.status == RegistrationStatus.uncertain) {
      Navigator.pop(context);
      return;
    }
    switch (flow.step) {
      case OcrStep.start:
        Navigator.pop(context);
        return;
      case OcrStep.capture:
        flow.go(OcrStep.start);
      case OcrStep.photo:
        flow.go(OcrStep.capture);
      case OcrStep.processing:
        flow.go(OcrStep.photo);
      case OcrStep.result:
        flow.go(flow.image == null ? OcrStep.start : OcrStep.photo);
      case OcrStep.error:
        flow.go(OcrStep.capture);
      case OcrStep.complete:
        flow.go(OcrStep.result);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([flow, registration]),
        builder: (context, _) {
          final title = switch (flow.step) {
            OcrStep.start => '약 등록',
            OcrStep.capture => '약봉투 찍기',
            OcrStep.photo => '사진 확인',
            OcrStep.processing => '약 읽는 중',
            OcrStep.result => '읽은 내용 확인',
            OcrStep.error => '다시 확인해 주세요',
            OcrStep.complete => '약 등록 완료',
          };
          return PopScope(
            canPop: flow.step == OcrStep.start &&
                registration.status != RegistrationStatus.saving,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) _back();
            },
            child: Scaffold(
              appBar: AppBar(
                leading: IconButton(
                  onPressed: registration.status == RegistrationStatus.saving
                      ? null
                      : _back,
                  tooltip: '뒤로',
                  icon: const Icon(Icons.arrow_back),
                ),
                title: Text(title),
              ),
              body: SafeArea(
                child: ListView(
                  key: ValueKey(flow.step),
                  padding: const EdgeInsets.all(AppSpacing.screenH),
                  children: [
                    if (widget.isMock) ...[
                      const Text('화면 테스트 · 예시 데이터이며 서버에 저장되지 않습니다.'),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    ..._content(),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Text(text, style: Theme.of(context).textTheme.headlineLarge),
      );
  Widget _body(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.md),
        child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
      );
  Widget _primary(String text, VoidCallback? action) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: FilledButton(onPressed: action, child: Text(text)),
      );
  Widget _secondary(String text, VoidCallback? action) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        child: OutlinedButton(onPressed: action, child: Text(text)),
      );

  List<Widget> _content() {
    if (registration.status == RegistrationStatus.saving) {
      return [
        _heading('약을 등록하고 있어요'),
        const Center(child: CircularProgressIndicator()),
      ];
    }
    if (registration.status == RegistrationStatus.uncertain) {
      return [
        _heading('저장 여부를 확인해 주세요'),
        _body(registration.error!),
        _primary('내 약 목록 확인', () async {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => MedicationListScreen(
                repository: widget.medications,
                isMock: widget.isMock,
              ),
            ),
          );
        }),
        _secondary('홈으로', () => Navigator.pop(context)),
      ];
    }
    switch (flow.step) {
      case OcrStep.start:
        return [
          _heading('약봉투를 사진으로 등록해요'),
          _body('약국에서 받은 약봉투를 준비해주세요'),
          _body('글씨가 잘 보이도록 밝은 곳에서 찍어주세요'),
          const Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Icon(
              Icons.camera_alt_outlined,
              size: AppSizing.illustrationSize,
              color: AppColors.primary,
            ),
          ),
          _primary(
            '사진 찍기',
            flow.picking ? null : () => flow.go(OcrStep.capture),
          ),
          _secondary('직접 입력하기', flow.picking ? null : () => _edit()),
        ];
      case OcrStep.capture:
        return [
          _heading('글씨가 잘 보이도록 찍어주세요'),
          _body('휴대폰 카메라로 촬영하거나 앨범의 사진을 선택할 수 있어요.'),
          if (flow.message != null) _body(flow.message!),
          if (flow.picking) const Center(child: CircularProgressIndicator()),
          _primary(
            '촬영',
            flow.picking ? null : () => flow.pick(ImageSource.camera),
          ),
          _secondary(
            '앨범에서 선택',
            flow.picking ? null : () => flow.pick(ImageSource.gallery),
          ),
          TextButton(
            onPressed: flow.picking ? null : () => _edit(),
            child: const Text('직접 입력하기'),
          ),
        ];
      case OcrStep.photo:
        return [
          _heading('글씨가 잘 보이나요?'),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppSizing.radius),
            child: Image.memory(
              flow.image!.bytes,
              fit: BoxFit.contain,
              height: AppSizing.photoPreviewHeight,
              cacheWidth: 1200,
              errorBuilder: (_, error, stack) =>
                  _body('사진을 표시하지 못했어요. 다른 사진을 선택해 주세요.'),
            ),
          ),
          _primary('이 사진 사용', () => flow.recognize()),
          _secondary('다시 찍기', () => flow.go(OcrStep.capture)),
        ];
      case OcrStep.processing:
        return [
          _heading('약봉투를 읽고 있어요'),
          _body('잠시만 기다려주세요'),
          const Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Center(child: CircularProgressIndicator()),
          ),
          _secondary('취소', () => flow.go(OcrStep.photo)),
        ];
      case OcrStep.result:
        return [
          _heading('이 약이 맞나요?'),
          _body('틀린 곳이 있으면 고쳐주세요'),
          if (flow.items.isEmpty) _body('약을 추가해 주세요.'),
          for (var i = 0; i < flow.items.length; i++) _draftCard(i),
          TextButton(
            onPressed: flow.items.length >= 30 ? null : () => _edit(),
            child: const Text('+ 약 추가하기'),
          ),
          if (flow.items.length >= 30) _body('한 번에 30개까지 확인할 수 있어요.'),
          if (flow.provider == 'mock' && !widget.isMock)
            _body('서버가 보낸 예시 결과입니다. 실제 사진 인식 결과가 아니에요.'),
          if (registration.error != null) _body(registration.error!),
          _primary(
            '이 내용으로 등록',
            flow.items.isEmpty
                ? null
                : () async {
                    await registration.save(
                      scanId: flow.scanId,
                      items: flow.items,
                    );
                    if (mounted &&
                        registration.status == RegistrationStatus.saved) {
                      flow.confirm();
                    }
                  },
          ),
          _secondary('다시 찍기', () => flow.go(OcrStep.capture)),
        ];
      case OcrStep.error:
        return [
          _heading('약봉투를 읽지 못했어요'),
          _body(flow.message ?? '다시 시도해 주세요.'),
          if (flow.image != null) _primary('다시 시도', () => flow.recognize()),
          _secondary('다시 찍기', () => flow.go(OcrStep.capture)),
          TextButton(onPressed: () => _edit(), child: const Text('직접 입력하기')),
        ];
      case OcrStep.complete:
        return [
          _heading('약을 등록했어요'),
          _body('오늘의 약에 표시하려면 복약 시간을 설정해 주세요.'),
          for (final item in registration.medications) ...[
            _body(item.name),
            _secondary(
                _scheduled.contains(item.id) ? '시간 설정 완료 · 다시 설정' : '복약 시간 설정',
                () async {
              final saved = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => ScheduleScreen(
                    medication: item,
                    repository: widget.medications,
                  ),
                ),
              );
              if (mounted && saved == true) {
                setState(() => _scheduled.add(item.id));
              }
            }),
          ],
          const SizedBox(height: AppSpacing.lg),
          DurResultView(
            repository: widget.dur,
            medications: widget.medications,
          ),
          _primary('홈으로', () => Navigator.pop(context)),
        ];
    }
  }

  Widget _draftCard(int index) {
    final item = flow.items[index];
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border:
            Border.all(color: AppColors.border, width: AppSizing.borderWidth),
        borderRadius: BorderRadius.circular(AppSizing.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.name, style: Theme.of(context).textTheme.bodyLarge),
          if (item.doseFrequencyPerDay != null)
            Text(
              '1일 ${item.doseFrequencyPerDay}회',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              TextButton(
                onPressed: () => _edit(index),
                child: const Text('수정'),
              ),
              TextButton(
                onPressed: () async {
                  final remove = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('이 약을 목록에서 지울까요?'),
                      content: Text(item.name),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('취소'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('삭제'),
                        ),
                      ],
                    ),
                  );
                  if (mounted && remove == true) flow.removeDraft(index);
                },
                child: const Text('삭제'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
