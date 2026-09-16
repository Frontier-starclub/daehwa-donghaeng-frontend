import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/api_client.dart';
import 'core/device_id_store.dart';
import 'design/tokens.dart';
import 'features/home/home_screen.dart';
import 'features/medication/medication_repository.dart';
import 'features/medication/mock_medication_repository.dart';
import 'features/ocr/http_ocr_repository.dart';
import 'features/ocr/mock_ocr_repository.dart';
import 'features/ocr/ocr_repository.dart';
import 'features/ocr/prescription_image_picker.dart';
import 'features/onboarding/user_repository.dart';
import 'features/onboarding/bootstrap_screen.dart';
import 'features/dur/dur_repository.dart';
import 'features/chat/chat_repository.dart';
import 'features/chat/voice_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const mock = bool.fromEnvironment('USE_MOCK', defaultValue: false);
  const scenarioName =
      String.fromEnvironment('MOCK_OCR_SCENARIO', defaultValue: 'success');
  final scenario = MockOcrScenario.values.firstWhere(
    (value) => value.name == scenarioName,
    orElse: () => MockOcrScenario.success,
  );
  final deviceIdStore = DeviceIdStore();
  final apiClient = ApiClient(
    // 실기기 테스트에서는 --dart-define=API_BASE_URL=http://<개발PC IP>:8090/api/v1
    baseUrl: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: ApiClient.emulatorBaseUrl,
    ),
    deviceIdStore: deviceIdStore,
  );

  final remote = MedicationRepository(apiClient);
  runApp(
    DaehwaApp(
      repository: mock ? MockMedicationRepository() : remote,
      ocrRepository: mock
          ? MockOcrRepository(scenario: scenario)
          : HttpOcrRepository(api: apiClient),
      imagePicker: DevicePrescriptionImagePicker(),
      isMock: mock,
      userRepository: mock ? null : UserRepository(apiClient, deviceIdStore),
      dur: mock ? const MockDurRepository() : DurRepository(apiClient),
      chat: mock ? MockChatRepository() : ChatRepository(apiClient),
      onDispose: apiClient.close,
    ),
  );
}

class DaehwaApp extends StatefulWidget {
  const DaehwaApp({
    super.key,
    required this.repository,
    required this.ocrRepository,
    required this.imagePicker,
    required this.isMock,
    this.initialize,
    this.onDispose,
    this.userRepository,
    this.dur,
    this.chat,
    this.voice,
  });
  final MedicationDataSource repository;
  final OcrRepository ocrRepository;
  final PrescriptionImagePicker imagePicker;
  final bool isMock;
  final Future<void> Function()? initialize;
  final VoidCallback? onDispose;
  final UserRepository? userRepository;
  final DurDataSource? dur;
  final ChatDataSource? chat;
  final VoiceService? voice;
  @override
  State<DaehwaApp> createState() => _DaehwaAppState();
}

class _DaehwaAppState extends State<DaehwaApp> {
  late final DurDataSource _dur = widget.dur ??
      (widget.isMock
          ? const MockDurRepository()
          : throw StateError('Real DUR repository required'));
  late final ChatDataSource _chat = widget.chat ??
      (widget.isMock
          ? MockChatRepository()
          : throw StateError('Real chat repository required'));
  VoiceService? _voice;
  @override
  void dispose() {
    final voice = _voice;
    if (voice != null) unawaited(voice.dispose());
    widget.onDispose?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = HomeScreen(
      repository: widget.repository,
      ocrRepository: widget.ocrRepository,
      imagePicker: widget.imagePicker,
      isMock: widget.isMock,
      initialize: widget.initialize,
      dur: _dur,
      chat: _chat,
      voice: () => _voice ??= widget.voice ?? DeviceVoiceService(),
    );
    return MaterialApp(
      title: '대화동행',
      locale: const Locale('ko', 'KR'),
      supportedLocales: const [Locale('ko', 'KR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      home: widget.userRepository == null
          ? home
          : BootstrapScreen(
              repository: widget.userRepository!,
              initialName:
                  const String.fromEnvironment('BOOTSTRAP_DISPLAY_NAME'),
              child: home,
            ),
    );
  }
}
