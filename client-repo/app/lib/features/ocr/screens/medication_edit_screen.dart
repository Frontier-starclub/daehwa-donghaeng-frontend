import 'package:flutter/material.dart';
import '../../../design/tokens.dart';
import '../ocr_models.dart';

class MedicationEditScreen extends StatefulWidget {
  const MedicationEditScreen({super.key, this.initial});
  final MedicationDraft? initial;
  @override
  State<MedicationEditScreen> createState() => _MedicationEditScreenState();
}

class _MedicationEditScreenState extends State<MedicationEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _frequency = TextEditingController(
    text: widget.initial?.doseFrequencyPerDay?.toString() ?? '',
  );

  @override
  void dispose() {
    _name.dispose();
    _frequency.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar:
            AppBar(title: Text(widget.initial == null ? '직접 입력' : '약 정보 수정')),
        body: SafeArea(
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.screenH),
              children: [
                Text(
                  '약 이름을 입력해 주세요',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  controller: _name,
                  maxLength: 100,
                  style: Theme.of(context).textTheme.bodyLarge,
                  decoration: const InputDecoration(
                    labelText: '약 이름',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? '약 이름을 입력해 주세요.'
                      : null,
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _frequency,
                  keyboardType: TextInputType.number,
                  style: Theme.of(context).textTheme.bodyLarge,
                  decoration: const InputDecoration(
                    labelText: '1일 복용 횟수 (선택)',
                    helperText: '약봉투에 적힌 횟수를 입력해 주세요.',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return null;
                    }
                    final count = int.tryParse(value.trim());
                    return count == null || count < 1 || count > 10
                        ? '1~10 사이의 횟수를 입력해 주세요.'
                        : null;
                  },
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: () {
                    if (!_form.currentState!.validate()) return;
                    Navigator.pop(
                      context,
                      MedicationDraft(
                        name: _name.text.trim(),
                        doseFrequencyPerDay:
                            int.tryParse(_frequency.text.trim()),
                      ),
                    );
                  },
                  child: const Text('확인'),
                ),
                const SizedBox(height: AppSpacing.sm),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소'),
                ),
              ],
            ),
          ),
        ),
      );
}
