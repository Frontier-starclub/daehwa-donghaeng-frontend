import 'package:flutter/material.dart';

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
          : const UnconfiguredOcrRepository(),
      imagePicker: DevicePrescriptionImagePicker(),
      isMock: mock,
      initialize: mock
          ? null
          : () async {
              const name = String.fromEnvironment('BOOTSTRAP_DISPLAY_NAME');
              if (name.isNotEmpty) {
                await remote.bootstrap(
                  deviceId: await deviceIdStore.readOrCreate(),
                  displayName: name,
                );
              }
            },
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
  });
  final MedicationDataSource repository;
  final OcrRepository ocrRepository;
  final PrescriptionImagePicker imagePicker;
  final bool isMock;
  final Future<void> Function()? initialize;
  final VoidCallback? onDispose;
  @override
  State<DaehwaApp> createState() => _DaehwaAppState();
}

class _DaehwaAppState extends State<DaehwaApp> {
  @override
  void dispose() {
    widget.onDispose?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '대화동행',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      home: HomeScreen(
        repository: widget.repository,
        ocrRepository: widget.ocrRepository,
        imagePicker: widget.imagePicker,
        isMock: widget.isMock,
        initialize: widget.initialize,
      ),
    );
  }
}
