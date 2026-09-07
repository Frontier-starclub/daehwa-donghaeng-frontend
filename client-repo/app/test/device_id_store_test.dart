import 'package:daehwa_donghaeng/core/device_id_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('device_id는 한 번 만들어지면 바뀌지 않는다', () async {
    SharedPreferences.setMockInitialValues({});

    final first = await DeviceIdStore().readOrCreate();
    // 새 인스턴스여도 저장된 값을 읽어야 한다. 여기서 값이 바뀌면
    // 사용자의 약 목록과 복약 기록이 통째로 사라진 것처럼 보인다.
    final second = await DeviceIdStore().readOrCreate();

    expect(first, isNotEmpty);
    expect(second, first);
  });

  test('저장된 값이 있으면 그대로 쓴다', () async {
    SharedPreferences.setMockInitialValues({
      'device_id': '11111111-2222-3333-4444-555555555555',
    });

    final id = await DeviceIdStore().readOrCreate();

    expect(id, '11111111-2222-3333-4444-555555555555');
  });
}
