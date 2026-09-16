import 'package:flutter/material.dart';
import '../../core/api_exception.dart';
import '../../design/tokens.dart';
import '../medication/medication_models.dart';
import '../medication/medication_repository.dart';
import 'dur_repository.dart';

class DurScreen extends StatelessWidget {
  const DurScreen({
    super.key,
    required this.repository,
    required this.medications,
  });
  final DurDataSource repository;
  final MedicationDataSource medications;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('약 주의사항')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenH),
            children: [
              DurResultView(repository: repository, medications: medications),
            ],
          ),
        ),
      );
}

class DurResultView extends StatefulWidget {
  const DurResultView({
    super.key,
    required this.repository,
    required this.medications,
  });
  final DurDataSource repository;
  final MedicationDataSource medications;
  @override
  State<DurResultView> createState() => _DurResultViewState();
}

class _DurResultViewState extends State<DurResultView> {
  DurResult? _result;
  List<Medication> _medications = [];
  String? _error;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Names are presentational; a failed name lookup must not fabricate a result.
      try {
        _medications = await widget.medications.activeMedications();
      } catch (_) {/* Show server wording without names. */}
      if (!mounted) return;
      final result = await widget.repository.check();
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is ApiException ? error.message : '주의사항을 확인하지 못했어요.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final result = _result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('약 주의사항 확인', style: theme.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        if (_loading) ...[
          const Center(child: CircularProgressIndicator()),
          const Text('등록한 약의 주의사항을 확인하고 있어요.'),
        ] else if (_error != null || result == null) ...[
          Text(_error ?? '주의사항을 확인하지 못했어요.', style: theme.bodyLarge),
          const Text('확인하지 못한 상태입니다.'),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton(onPressed: _check, child: const Text('주의사항 다시 확인')),
        ] else ...[
          if (result.provider == 'mock' ||
              result.warnings.any((item) => item.type == 'demo_warning'))
            const Text('예시 결과 · 실제 의약 정보가 아닙니다.'),
          Text(
            switch (result.status) {
              'warnings' => '확인할 주의사항이 있어요',
              'no_warnings' => '조회된 주의사항이 없어요',
              _ => '확인하지 못한 항목이 있어요',
            },
            style: theme.bodyLarge,
          ),
          for (final warning in result.warnings) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.warningSurface,
                border: Border.all(color: AppColors.warning),
                borderRadius: BorderRadius.circular(AppSizing.radius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.info_outline,
                    color: AppColors.warning,
                    semanticLabel: '주의사항',
                  ),
                  if (_medications
                      .any((item) => warning.medicationIds.contains(item.id)))
                    Text(
                      _medications
                          .where(
                            (item) => warning.medicationIds.contains(item.id),
                          )
                          .map((item) => item.name)
                          .join(', '),
                      style: theme.titleLarge,
                    ),
                  Text(warning.message, style: theme.bodyLarge),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text(result.disclaimer, style: theme.bodyLarge),
          if (result.status != 'warnings' && result.status != 'no_warnings')
            OutlinedButton(onPressed: _check, child: const Text('주의사항 다시 확인')),
        ],
      ],
    );
  }
}
