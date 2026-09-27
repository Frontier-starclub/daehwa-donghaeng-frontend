import 'package:flutter/material.dart';
import '../../core/api_exception.dart';
import '../../design/tokens.dart';
import 'medication_models.dart';
import 'medication_repository.dart';
import 'schedule_screen.dart';

class MedicationListScreen extends StatefulWidget {
  const MedicationListScreen({
    super.key,
    required this.repository,
    this.isMock = false,
  });
  final MedicationDataSource repository;
  final bool isMock;
  @override
  State<MedicationListScreen> createState() => _MedicationListScreenState();
}

class _MedicationListScreenState extends State<MedicationListScreen> {
  List<Medication>? _items;
  String? _error;
  final Set<String> _configured = {};
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await widget.repository.activeMedications();
      if (mounted) setState(() => _items = items);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is ApiException ? error.message : '약 목록을 불러오지 못했어요.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit(Medication item, {bool end = false}) async {
    final management = widget.repository;
    if (management is! MedicationManagement) return;
    final name = TextEditingController(text: item.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(end ? '이 약의 복용을 종료할까요?' : '약 이름 수정'),
        content: end
            ? const Text(
                '앱의 알림과 활성 약 목록에서 제외됩니다. 지난 기록은 남아요. 실제 복용 변경은 의사·약사에게 확인해주세요.',
              )
            : TextField(
                controller: name,
                maxLength: 100,
                decoration: const InputDecoration(labelText: '약 이름'),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(end ? '종료' : '저장'),
          ),
        ],
      ),
    );
    final value = name.text.trim();
    name.dispose();
    if (!mounted || confirmed != true || (!end && value.isEmpty)) return;
    setState(() => _loading = true);
    try {
      if (end) {
        await (management as MedicationManagement).endMedication(item.id);
      } else {
        await (management as MedicationManagement)
            .renameMedication(item.id, value);
      }
      if (mounted) {
        _loading = false;
        await _load();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error is ApiException ? error.message : '약 정보를 변경하지 못했어요.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('내 약 목록')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenH),
            children: [
              if (widget.isMock) const Text('예시 데이터 · 앱을 종료하면 초기화됩니다.'),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_error != null) ...[
                Text(_error!),
                OutlinedButton(onPressed: _load, child: const Text('다시 불러오기')),
              ] else ...[
                if (_items?.isEmpty ?? true) const Text('아직 등록된 약이 없어요.'),
                for (final item in _items ?? <Medication>[]) ...[
                  Text(
                    item.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (item.doseFrequencyPerDay != null)
                    Text('1일 ${item.doseFrequencyPerDay}회'),
                  OutlinedButton(
                    onPressed: () async {
                      final saved = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ScheduleScreen(
                            medication: item,
                            repository: widget.repository,
                          ),
                        ),
                      );
                      if (mounted && saved == true) {
                        setState(() => _configured.add(item.id));
                      }
                    },
                    child: Text(
                      _configured.contains(item.id)
                          ? '시간 설정 완료 · 다시 설정'
                          : '복약 시간 설정',
                    ),
                  ),
                  if (widget.repository is MedicationManagement) ...[
                    TextButton(
                      onPressed: () => _edit(item),
                      child: const Text('이름 수정'),
                    ),
                    TextButton(
                      onPressed: () => _edit(item, end: true),
                      child: const Text('복용 종료'),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.lg),
                ],
              ],
            ],
          ),
        ),
      );
}
