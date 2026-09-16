import 'package:shared_preferences/shared_preferences.dart';
import '../../core/api_client.dart';
import '../../core/device_id_store.dart';

class UserRepository {
  UserRepository(this.api, this.deviceIdStore);
  final ApiClient api;
  final DeviceIdStore deviceIdStore;
  String get _nameKey => 'display_name:${api.baseUrl}';

  Future<String?> savedName() async =>
      (await SharedPreferences.getInstance()).getString(_nameKey);

  Future<void> register(String name) async {
    await api.post(
      '/users/bootstrap',
      body: {
        'device_id': await deviceIdStore.readOrCreate(),
        'display_name': name.trim(),
      },
    );
    await (await SharedPreferences.getInstance())
        .setString(_nameKey, name.trim());
  }
}
