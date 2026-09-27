import 'package:flutter/material.dart';
import '../../core/api_exception.dart';
import '../../design/tokens.dart';
import 'profile_repository.dart';

class InsightsScreen extends StatefulWidget {
  const InsightsScreen({super.key, required this.repository});
  final ProfileRepository repository;
  @override
  State<InsightsScreen> createState() => _InsightsScreenState();
}

class _InsightsScreenState extends State<InsightsScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool retry = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (retry) {
        for (final id
            in (_data?['retry_session_ids'] as List<dynamic>? ?? [])) {
          await widget.repository.api.post('/chat/sessions/$id/analysis');
        }
      }
      final data =
          await widget.repository.api.get('/insights') as Map<String, dynamic>;
      if (mounted) setState(() => _data = data);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is ApiException ? error.message : '변화 기록을 불러오지 못했어요.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('내 변화 요약')),
        body: ListView(
          padding: const EdgeInsets.all(AppSpacing.screenH),
          children: [
            if (_busy) const Center(child: CircularProgressIndicator()),
            if (_error != null) Text(_error!),
            if (_data != null) ...[
              if (_data!['has_demo_data'] == true)
                const Text('예시 AI 모드의 기록이 포함되어 있어요.'),
              Text(
                _data!['status'] == 'collecting'
                    ? '변화를 비교할 기록을 모으고 있어요.'
                    : '최근 7일과 이전 7일의 기록',
              ),
              const Text(
                '각 기간에 대화 3회, 발화 10개 이상일 때 비교해요. 감정 비교는 충분한 신뢰도의 분석 3회가 더 필요해요.',
              ),
              const SizedBox(height: 20),
              Text(
                '최근 대화 ${_data!['current']['sessions']}회 · 발화 ${_data!['current']['utterances']}개',
              ),
              observationCard(
                '말의 길이',
                _data!['current']['mean_characters'],
                _data!['change']['mean_characters'],
                suffix: '자',
              ),
              observationCard(
                '어휘 다양성',
                _data!['current']['vocabulary_diversity'],
                _data!['change']['vocabulary_diversity'],
              ),
              observationCard(
                '감정 표현',
                _data!['current']['mood_score'],
                _data!['change']['mood_score'],
              ),
              const Text(
                '감정 표현은 -1~1, 어휘 다양성은 0~1의 기록값이에요. 높거나 낮음만으로 건강 상태를 판단하지 않아요.',
              ),
              Text(_data!['disclaimer'] as String),
              if ((_data!['retry_session_ids'] as List).isNotEmpty)
                OutlinedButton(
                  onPressed: _busy ? null : () => _load(retry: true),
                  child: const Text('미완료 분석 다시 시도'),
                ),
            ],
            OutlinedButton(
              onPressed: _busy ? null : _load,
              child: const Text('다시 확인'),
            ),
          ],
        ),
      );
}

Widget observationCard(
  String label,
  dynamic value,
  dynamic change, {
  String suffix = '',
}) =>
    Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label),
            Text(value == null ? '아직 확인할 기록이 부족해요.' : '$value$suffix'),
            if (change != null)
              Text('이전 기간 대비 ${change >= 0 ? '+' : ''}$change$suffix'),
          ],
        ),
      ),
    );
