import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_exception.dart';
import '../../design/tokens.dart';
import 'profile_repository.dart';
import 'insights_screen.dart';

class CaregiversScreen extends StatefulWidget {
  const CaregiversScreen({super.key, required this.repository});
  final ProfileRepository repository;
  @override
  State<CaregiversScreen> createState() => _CaregiversScreenState();
}

class _CaregiversScreenState extends State<CaregiversScreen> {
  final _code = TextEditingController();
  List<dynamic> _links = [];
  String? _invitation, _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _run(_load);
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final links =
        await widget.repository.api.get('/caregivers/links') as List<dynamic>;
    if (mounted) setState(() => _links = links);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error is ApiException ? error.message : '요청을 완료하지 못했어요.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _report(String? linkId) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => CaregiverReportScreen(
          repository: widget.repository,
          linkId: linkId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('보호자 연결')),
        body: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenH),
          children: [
            const Text('내 기록을 공유하려면 설정에서 공유에 동의하고 항목을 먼저 골라주세요.'),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        final data = await widget.repository.api
                                .post('/caregivers/invitations')
                            as Map<String, dynamic>;
                        if (mounted) {
                          setState(() => _invitation = data['code'] as String);
                        }
                      }),
              child: const Text('보호자 초대 코드 만들기'),
            ),
            if (_invitation != null) ...[
              const Text(
                '24시간 안에 한 번만 사용할 수 있어요. 기록을 보여줄 보호자에게만 전달해주세요. 새 코드를 만들면 이전 코드는 만료돼요.',
              ),
              SelectableText(_invitation!),
              OutlinedButton(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _invitation!)),
                child: const Text('코드 복사'),
              ),
            ],
            OutlinedButton(
              onPressed: _busy ? null : () => _report(null),
              child: const Text('내가 공유하는 리포트 미리보기'),
            ),
            const Divider(height: 40),
            Text('보호자로 연결하기', style: Theme.of(context).textTheme.titleLarge),
            const Text('사용자가 직접 전달한 초대 코드를 입력해주세요.'),
            TextField(
              controller: _code,
              enabled: !_busy,
              maxLength: 100,
              decoration: const InputDecoration(labelText: '받은 초대 코드'),
            ),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        await widget.repository.api.post(
                          '/caregivers/accept',
                          body: {'code': _code.text.trim()},
                        );
                        _code.clear();
                        await _load();
                      }),
              child: const Text('초대 수락'),
            ),
            const Divider(height: 40),
            Text('현재 연결', style: Theme.of(context).textTheme.titleLarge),
            if (_links.isEmpty && !_busy) const Text('아직 연결된 사람이 없어요.'),
            for (final link in _links)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${link['display_name']} · ${link['role'] == 'owner' ? '내 기록을 보는 보호자' : '내가 돌보는 분'}',
                      ),
                      if (link['role'] == 'caregiver')
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _report(link['id'] as String),
                          child: const Text('공유 리포트 보기'),
                        ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                  final confirmed = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('연결을 해제할까요?'),
                                      content: const Text(
                                        '이 연결로는 더 이상 기록을 볼 수 없어요.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('유지'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('해제'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (confirmed == true) {
                                    await widget.repository.api.delete(
                                      '/caregivers/links/${link['id']}',
                                    );
                                    await _load();
                                  }
                                }),
                        child: const Text('연결 해제'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_busy) const Center(child: CircularProgressIndicator()),
            if (_error != null) Text(_error!),
            OutlinedButton(
              onPressed: _busy ? null : () => _run(_load),
              child: const Text('다시 확인'),
            ),
          ],
        ),
      );
}

class CaregiverReportScreen extends StatefulWidget {
  const CaregiverReportScreen({
    super.key,
    required this.repository,
    this.linkId,
  });
  final ProfileRepository repository;
  final String? linkId;
  @override
  State<CaregiverReportScreen> createState() => _CaregiverReportScreenState();
}

class _CaregiverReportScreenState extends State<CaregiverReportScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _data = null;
    });
    try {
      final path = widget.linkId == null
          ? '/caregivers/report-preview'
          : '/caregivers/links/${widget.linkId}/report';
      final data =
          await widget.repository.api.get(path) as Map<String, dynamic>;
      if (mounted) setState(() => _data = data);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is ApiException ? error.message : '리포트를 불러오지 못했어요.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('공유 리포트')),
        body: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenH),
          children: [
            if (_loading) const Center(child: CircularProgressIndicator()),
            if (_error != null) Text(_error!),
            if (_data != null) ...[
              Text(
                '${_data!['display_name']}님의 기록',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text('사용자가 허용한 항목만 보여요. 대화 원문과 음성은 공유하지 않아요.'),
              if (_data!['medication'] case final Map<String, dynamic> med) ...[
                const SizedBox(height: 20),
                const Text('최근 7일 복약 기록'),
                Text('예정 ${med['scheduled']}회 · 복용 확인 ${med['taken']}회'),
                Text(
                  '아직 복용 안 함 ${med['not_taken']}회 · 응답 없음 ${med['unanswered']}회',
                ),
                Text(
                  med['confirmation_rate'] == null
                      ? '계산할 기록이 없어요.'
                      : '복용 확인율 ${((med['confirmation_rate'] as num) * 100).round()}%',
                ),
              ],
              for (final type in ['mood', 'language'])
                if (_data![type] case final Map<String, dynamic> section) ...[
                  const SizedBox(height: 20),
                  Text(type == 'mood' ? '감정 표현 기록' : '대화 표현 기록'),
                  if (section['has_demo_data'] == true)
                    const Text('예시 AI 모드의 기록이 포함되어 있어요.'),
                  if (section['status'] == 'collecting')
                    const Text('기간별 변화를 비교할 기록을 모으고 있어요.'),
                  if (type == 'mood')
                    observationCard(
                      '감정 표현',
                      section['current']['mood_score'],
                      section['change']['mood_score'],
                    )
                  else ...[
                    observationCard(
                      '말의 길이',
                      section['current']['mean_characters'],
                      section['change']['mean_characters'],
                      suffix: '자',
                    ),
                    observationCard(
                      '어휘 다양성',
                      section['current']['vocabulary_diversity'],
                      section['change']['vocabulary_diversity'],
                    ),
                  ],
                ],
              if (_data!['medication'] == null &&
                  _data!['mood'] == null &&
                  _data!['language'] == null)
                const Text('현재 공유하도록 선택한 항목이 없어요.'),
              const SizedBox(height: 20),
              Text(_data!['disclaimer'] as String),
            ],
            OutlinedButton(
              onPressed: _loading ? null : _load,
              child: const Text('다시 확인'),
            ),
          ],
        ),
      );
}
