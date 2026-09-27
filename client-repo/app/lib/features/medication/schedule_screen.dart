import 'package:flutter/material.dart';
import '../../core/api_exception.dart';
import '../../design/tokens.dart';
import 'medication_models.dart';
import 'medication_repository.dart';

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({
    super.key,
    required this.medication,
    required this.repository,
  });
  final Medication medication;
  final MedicationDataSource repository;
  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  static const _slots = {
    'morning': '아침',
    'lunch': '점심',
    'dinner': '저녁',
    'bedtime': '자기 전',
    'custom': '직접 정한 시간',
  };
  final List<MedicationSchedule> _schedules = [];
  bool _saving = false;
  bool _loading = false;
  bool _loadFailed = false;
  bool _hadSchedules = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repository = widget.repository;
    if (repository is! MedicationManagement) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
      _error = null;
    });
    try {
      final items = await (repository as MedicationManagement)
          .schedules(widget.medication.id);
      if (mounted) {
        setState(() {
          _schedules.clear();
          _schedules.addAll(items);
          _hadSchedules = items.isNotEmpty;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _error = '기존 시간을 확인하지 못했어요. 다시 불러온 뒤 변경해주세요.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: '약을 드실 시간을 선택해 주세요',
      cancelText: '취소',
      confirmText: '선택',
      hourLabelText: '시',
      minuteLabelText: '분',
    );
    if (!mounted || time == null) return;
    final value =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:00';
    setState(() {
      if (_schedules.any((item) => item.remindAt == value)) {
        _error = '같은 시간은 한 번만 선택해 주세요.';
      } else {
        _error = null;
        _schedules.add(MedicationSchedule(timeSlot: 'custom', remindAt: value));
      }
    });
  }

  Future<void> _save() async {
    if (_saving || _loading || _loadFailed) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repository
          .saveSchedules(widget.medication.id, List.of(_schedules));
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ApiException
              ? error.message
              : '시간을 저장하지 못했어요. 다시 시도해 주세요.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('복약 시간 설정'),
            automaticallyImplyLeading: !_saving,
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screenH),
              children: [
                Text(
                  widget.medication.name,
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: AppSpacing.sm),
                const Text(
                  '한국 시간 기준으로 알림 시간을 정해주세요. 시간을 모두 지우고 저장하면 알림이 중단됩니다. 지난 복약 기록은 남습니다.',
                ),
                const SizedBox(height: AppSpacing.md),
                if (_loading) const Center(child: CircularProgressIndicator()),
                if (_loadFailed)
                  OutlinedButton(
                    onPressed: _load,
                    child: const Text('다시 불러오기'),
                  ),
                for (var index = 0; index < _schedules.length; index++) ...[
                  Text(
                    _schedules[index].remindAt.substring(0, 5),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('slot-$index-${_schedules[index].remindAt}'),
                    initialValue: _schedules[index].timeSlot,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '시간 이름'),
                    items: _slots.entries
                        .map(
                          (entry) => DropdownMenuItem(
                            value: entry.key,
                            child: Text(entry.value),
                          ),
                        )
                        .toList(),
                    onChanged: _saving
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(
                                () => _schedules[index] = MedicationSchedule(
                                  timeSlot: value,
                                  remindAt: _schedules[index].remindAt,
                                ),
                              );
                            }
                          },
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _schedules.removeAt(index)),
                    child: const Text('이 시간 삭제'),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                ],
                if (_schedules.length < 8)
                  OutlinedButton(
                    onPressed: _saving || _loading || _loadFailed ? null : _add,
                    child: const Text('시간 추가하기'),
                  ),
                if (_error != null)
                  Text(_error!, style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: AppSpacing.md),
                FilledButton(
                  onPressed: _saving ||
                          _loading ||
                          _loadFailed ||
                          (_schedules.isEmpty && !_hadSchedules)
                      ? null
                      : _save,
                  child: Text(_saving ? '시간 저장 중' : '이 시간으로 저장'),
                ),
                const SizedBox(height: AppSpacing.sm),
                const Text('약은 이미 등록되어 있어요. 시간만 저장하거나 다시 시도합니다.'),
              ],
            ),
          ),
        ),
      );
}
