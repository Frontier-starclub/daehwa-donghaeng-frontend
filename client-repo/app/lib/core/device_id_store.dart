import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 기기 식별자 저장소.
///
/// 백엔드 계약(`apps/mobile/README.md`):
///   앱 최초 실행 시 UUID v4를 한 번 생성해 로컬에 저장하고,
///   `POST /users/bootstrap`의 `device_id`와 이후 모든 `X-Device-ID` 헤더에
///   같은 값을 쓴다.
///
/// 이 값이 바뀌면 서버에서 다른 사용자가 되어 약 목록과 복약 기록이 통째로
/// 사라진 것처럼 보인다. 절대 재생성하지 않는다.
class DeviceIdStore {
  DeviceIdStore({SharedPreferences? preferences, Uuid? uuid})
      : _preferences = preferences,
        _uuid = uuid ?? const Uuid();

  static const _key = 'device_id';

  SharedPreferences? _preferences;
  final Uuid _uuid;
  String? _cached;

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  /// 저장된 값을 돌려주고, 없으면 한 번만 만들어 저장한다.
  Future<String> readOrCreate() async {
    if (_cached != null) return _cached!;

    final prefs = await _prefs;
    final existing = prefs.getString(_key);
    if (existing != null && existing.isNotEmpty) {
      return _cached = existing;
    }

    final created = _uuid.v4();
    await prefs.setString(_key, created);
    return _cached = created;
  }
}
