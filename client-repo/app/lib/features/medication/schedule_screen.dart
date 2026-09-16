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
  String? _error;
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
    if (_saving || _schedules.isEmpty) return;
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
                  '약봉투의 안내에 맞춰 드실 시간을 직접 선택해 주세요. 기존 시간이 있으면 아래 내용으로 바뀝니다.',
                ),
                const SizedBox(height: AppSpacing.md),
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
                    onPressed: _saving ? null : _add,
                    child: const Text('시간 추가하기'),
                  ),
                if (_error != null)
                  Text(_error!, style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: AppSpacing.md),
                FilledButton(
                  onPressed: _saving || _schedules.isEmpty ? null : _save,
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
