import 'package:flutter/material.dart';
import '../../design/tokens.dart';
import 'medication_models.dart';
import 'medication_repository.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.repository});
  final MedicationManagement repository;
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  DateTime _day = DateTime.now().toUtc().add(const Duration(hours: 9));
  List<MedicationEvent> _events = [];
  bool _loading = false;
  String? _error;
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
      final events = await widget.repository.history(_day, _day);
      if (mounted) setState(() => _events = events);
    } catch (_) {
      if (mounted) setState(() => _error = '복약 기록을 불러오지 못했어요.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('복약 기록')),
        body: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenH),
          children: [
            OutlinedButton(
              onPressed: _loading
                  ? null
                  : () async {
                      final now =
                          DateTime.now().toUtc().add(const Duration(hours: 9));
                      final chosen = await showDatePicker(
                        context: context,
                        initialDate: _day,
                        firstDate: DateTime(2020),
                        lastDate: now,
                        helpText: '확인할 날짜',
                      );
                      if (chosen != null && mounted) {
                        _day = chosen;
                        await _load();
                      }
                    },
              child: Text('${_day.year}년 ${_day.month}월 ${_day.day}일 · 날짜 선택'),
            ),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null) ...[
              Text(_error!),
              OutlinedButton(onPressed: _load, child: const Text('다시 확인')),
            ] else if (_events.isEmpty)
              const Text('이 날짜에 예정된 약이 없어요.')
            else
              for (final event in _events)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${event.displayTime} ${event.medicationName}'),
                        Text(
                          switch (event.status) {
                            'taken' => '드셨어요',
                            'not_taken' => '아직 안 드셨어요',
                            _ => '응답 기록 없음'
                          },
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      );
}
