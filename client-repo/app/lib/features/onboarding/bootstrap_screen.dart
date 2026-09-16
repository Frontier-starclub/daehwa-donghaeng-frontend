import 'package:flutter/material.dart';
import '../../core/api_exception.dart';
import '../../design/tokens.dart';
import 'user_repository.dart';

class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({
    super.key,
    required this.repository,
    required this.child,
    this.initialName = '',
  });
  final UserRepository repository;
  final Widget child;
  final String initialName;
  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _loading = true;
  bool _ready = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final saved = widget.initialName.isNotEmpty
          ? widget.initialName
          : await widget.repository.savedName();
      if (!mounted) return;
      _name.text = saved ?? '';
      if (_name.text.isNotEmpty) {
        await _register();
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '사용자 정보를 열지 못했어요. 이름을 입력해 주세요.';
        });
      }
    }
  }

  Future<void> _register() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await widget.repository.register(_name.text);
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is ApiException ? error.message : '등록하지 못했어요. 다시 시도해 주세요.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    return Scaffold(
      appBar: AppBar(title: const Text('대화동행 시작하기')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenH),
            children: [
              Text(
                '어떻게 불러드릴까요?',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _name,
                enabled: !_loading,
                maxLength: 50,
                style: Theme.of(context).textTheme.bodyLarge,
                decoration: const InputDecoration(
                  labelText: '이름 또는 별명',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? '이름을 입력해 주세요.'
                    : null,
              ),
              if (_error != null)
                Text(_error!, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: AppSpacing.md),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else
                FilledButton(
                  onPressed: () {
                    if (_form.currentState!.validate()) _register();
                  },
                  child: const Text('시작하기'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
