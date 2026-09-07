import 'package:flutter/material.dart';

import '../../core/api_exception.dart';
import '../../design/tokens.dart';
import '../medication/medication_models.dart';
import '../medication/medication_repository.dart';
import '../ocr/ocr_repository.dart';
import '../ocr/prescription_image_picker.dart';
import '../ocr/screens/registration_flow_screen.dart';

/// HOME-01 — 홈.
///
/// 화면설계서 FT-전체 / MVP: MUST / UI A안(오늘 할 일 중심).
/// 목적: 앱을 열자마자 오늘 복약 상태를 확인하고 새 약을 등록할 수 있게 한다.
///
/// 이 화면은 Phase1 완료 기준이기도 하다 — 백엔드 왕복
/// (bootstrap → 오늘의 약 → 복약 응답)이 여기서 처음 검증된다.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.ocrRepository,
    required this.imagePicker,
    required this.isMock,
    this.initialize,
  });
  final MedicationDataSource repository;
  final OcrRepository ocrRepository;
  final PrescriptionImagePicker imagePicker;
  final bool isMock;
  final Future<void> Function()? initialize;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  MedicationDataSource get _repository => widget.repository;
  bool _initialized = false;
  final Set<String> _responding = {};

  List<MedicationEvent>? _events;
  ApiException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_initialized) {
        await widget.initialize?.call();
        _initialized = true;
      }
      final events = await _repository.todayEvents();
      if (!mounted) return;
      setState(() {
        _events = events;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _respond(MedicationEvent event, bool taken) async {
    if (_responding.contains(event.id)) return;
    setState(() => _responding.add(event.id));
    try {
      final updated =
          await _repository.respondToEvent(eventId: event.id, taken: taken);
      if (!mounted) return;
      setState(() {
        _events = [
          for (final item in _events!) item.id == updated.id ? updated : item,
        ];
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _responding.remove(event.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('대화동행'),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
        centerTitle: false,
      ),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load);
    }

    final events = _events ?? const <MedicationEvent>[];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.screenH),
        children: [
          if (widget.isMock) ...[
            const Text('화면 테스트 · 예시 데이터이며 서버에 저장되지 않습니다.'),
            const SizedBox(height: AppSpacing.md),
          ],
          Text('오늘의 약', style: Theme.of(context).textTheme.headlineLarge),
          const SizedBox(height: AppSpacing.md),
          if (events.isEmpty)
            // 화면설계서 오류/예외: 등록된 약 0개 → 안내 + [약 등록하기]만 크게
            const _EmptyState()
          else
            for (final event in events) ...[
              _EventCard(
                event: event,
                onRespond: _respond,
                busy: _responding.contains(event.id),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          const SizedBox(height: AppSpacing.lg),
          FilledButton(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => RegistrationFlowScreen(
                  repository: widget.ocrRepository,
                  picker: widget.imagePicker,
                  isMock: widget.isMock,
                ),
              ),
            ),
            child: const Text('약 등록하기'),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Text(
        '아직 등록된 약이 없어요',
        style: Theme.of(context).textTheme.bodyLarge,
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// 한 건의 복약 일정. 화면당 주요 선택지 2개(드셨어요 / 아직이에요)를 넘지 않는다.
class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.onRespond,
    required this.busy,
  });

  final MedicationEvent event;
  final void Function(MedicationEvent event, bool taken) onRespond;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
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
          Text(
            '${event.timeSlotLabel} ${event.displayTime}',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.min),
          Text(event.medicationName, style: theme.textTheme.bodyLarge),
          const SizedBox(height: AppSpacing.md),
          if (event.isAnswered)
            // 색상에만 의존하지 않는다 — 아이콘 + 문구를 함께 쓴다.
            Row(
              children: [
                Icon(
                  event.wasTaken
                      ? Icons.check_circle
                      : Icons.remove_circle_outline,
                  color: event.wasTaken
                      ? AppColors.safe
                      : AppColors.onSurfaceMuted,
                  size: 28,
                ),
                const SizedBox(width: AppSpacing.min),
                Expanded(
                  child: Text(
                    event.wasTaken ? '드셨어요' : '아직 안 드셨어요',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ],
            )
          else ...[
            FilledButton(
              onPressed: busy ? null : () => onRespond(event, true),
              child: const Text('드셨어요'),
            ),
            const SizedBox(height: AppSpacing.min),
            OutlinedButton(
              onPressed: busy ? null : () => onRespond(event, false),
              child: const Text('아직이에요'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final ApiException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.screenH),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 서버가 준 한국어 문구를 그대로 보여준다. 앱에서 새로 짓지 않는다.
          Text(
            error.message,
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (error.isRetryable)
            FilledButton(onPressed: onRetry, child: const Text('다시 시도')),
        ],
      ),
    );
  }
}
