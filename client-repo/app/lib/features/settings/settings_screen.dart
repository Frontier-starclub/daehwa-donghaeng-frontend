import 'package:flutter/material.dart';
import '../../core/api_exception.dart';
import '../../design/tokens.dart';
import 'profile_repository.dart';

class ProfileGate extends StatefulWidget {
  const ProfileGate({super.key, required this.repository, required this.child});
  final ProfileRepository repository;
  final Widget child;
  @override
  State<ProfileGate> createState() => _ProfileGateState();
}

class _ProfileGateState extends State<ProfileGate> {
  late Future<Map<String, dynamic>> _profile = widget.repository.me();
  bool _finished = false;
  @override
  Widget build(BuildContext context) {
    if (_finished) return widget.child;
    return FutureBuilder<Map<String, dynamic>>(
      future: _profile,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: OutlinedButton(
                onPressed: () =>
                    setState(() => _profile = widget.repository.me()),
                child: const Text('설정 다시 불러오기'),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data!['consent']['onboarding_completed'] == true) {
          return widget.child;
        }
        return SettingsScreen(
          repository: widget.repository,
          onboarding: true,
          onDone: () => setState(() => _finished = true),
        );
      },
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    this.onboarding = false,
    this.onDone,
  });
  final ProfileRepository repository;
  final bool onboarding;
  final VoidCallback? onDone;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _values = <String, bool>{
    'analysis_allowed': false,
    'caregiver_share_allowed': false,
    'share_medication': false,
    'share_mood': false,
    'share_language': false,
  };
  bool _loading = true, _saving = false, _chatReminder = false;
  bool _loaded = false;
  TimeOfDay _chatTime = const TimeOfDay(hour: 19, minute: 0);
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
      final me = await widget.repository.me();
      if (!mounted) return;
      final consent = me['consent'] as Map<String, dynamic>;
      for (final key in _values.keys) {
        _values[key] = consent[key] == true;
      }
      _chatReminder = me['chat_reminder_enabled'] == true;
      final parts = (me['chat_reminder_at'] as String).split(':');
      _chatTime =
          TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
      _loaded = true;
    } catch (_) {
      _error = '설정을 불러오지 못했어요.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repository
          .saveConsents({..._values, 'onboarding_completed': true});
      final time =
          '${_chatTime.hour.toString().padLeft(2, '0')}:${_chatTime.minute.toString().padLeft(2, '0')}:00';
      await widget.repository.saveReminders(_chatReminder, time);
      if (!mounted) return;
      if (widget.onDone != null) {
        widget.onDone!();
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('설정을 저장했어요.')));
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is ApiException
              ? error.message
              : '설정을 저장하지 못했어요. 다시 시도해주세요.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _toggle(
    String key,
    String title,
    String description, {
    bool enabled = true,
  }) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(title),
        subtitle: Text(description),
        value: _values[key]!,
        onChanged: !enabled || _saving
            ? null
            : (value) => setState(() {
                  _values[key] = value;
                  if (!_values['analysis_allowed']!) {
                    _values['share_mood'] = false;
                    _values['share_language'] = false;
                  }
                  if (!_values['caregiver_share_allowed']!) {
                    _values['share_medication'] = false;
                    _values['share_mood'] = false;
                    _values['share_language'] = false;
                  }
                }),
      );
  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_saving,
        child: Scaffold(
          appBar: AppBar(title: Text(widget.onboarding ? '처음 이용 설정' : '설정')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screenH),
              children: [
                const Text('선택하지 않아도 약 등록, 복약 확인, 대화를 이용할 수 있어요.'),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_loaded) ...[
                  _toggle(
                    'analysis_allowed',
                    '내 대화 변화 살펴보기',
                    '동의한 뒤 시작한 대화에서 감정 표현과 말의 길이·어휘 변화를 정리해요. 건강 진단은 하지 않아요. 끄면 기존 분석 기록을 삭제해요.',
                  ),
                  _toggle(
                    'caregiver_share_allowed',
                    '보호자에게 기록 공유',
                    '초대 코드로 연결한 보호자에게 아래에서 고른 항목만 보여줘요. 끄면 보호자 연결과 초대 코드가 해제돼요.',
                  ),
                  _toggle(
                    'share_medication',
                    '복약 기록 공유',
                    '최근 7일의 복용 확인·미응답 횟수',
                    enabled: _values['caregiver_share_allowed']!,
                  ),
                  _toggle(
                    'share_mood',
                    '감정 표현 변화 공유',
                    '구조화된 감정 표현 지표만 공유해요.',
                    enabled: _values['caregiver_share_allowed']! &&
                        _values['analysis_allowed']!,
                  ),
                  _toggle(
                    'share_language',
                    '대화 표현 변화 공유',
                    '말의 길이와 어휘 다양성의 기록 변화',
                    enabled: _values['caregiver_share_allowed']! &&
                        _values['analysis_allowed']!,
                  ),
                  const Text('대화 원문, 음성, 개인적인 이야기는 보호자에게 공개하지 않아요.'),
                  const Divider(height: 40),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('이야기 시간 알림'),
                    subtitle: const Text('원하는 시각에 대화를 제안해요. 참여는 자유예요.'),
                    value: _chatReminder,
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _chatReminder = value),
                  ),
                  OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: _chatTime,
                              helpText: '이야기 알림 시각 · 한국 시간',
                            );
                            if (time != null && mounted) {
                              setState(() => _chatTime = time);
                            }
                          },
                    child: Text('이야기 알림 ${_chatTime.format(context)}'),
                  ),
                  if (widget.repository.reminders != null) ...[
                    ListenableBuilder(
                      listenable: widget.repository.reminders!,
                      builder: (context, _) => Text(
                        widget.repository.reminders!.notice ??
                            '알림 시간은 한국 시간을 기준으로 해요.',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => widget.repository.reminders!
                              .sync(requestPermission: true),
                      child: const Text('알림 권한 확인 및 다시 연결'),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(
                      _saving
                          ? '저장 중'
                          : widget.onboarding
                              ? '이 설정으로 시작하기'
                              : '설정 저장',
                    ),
                  ),
                ],
                if (_error != null) ...[
                  Text(_error!),
                  TextButton(onPressed: _load, child: const Text('다시 불러오기')),
                ],
              ],
            ),
          ),
        ),
      );
}
