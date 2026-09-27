import '../../core/api_client.dart';
import '../../core/reminders.dart';

class ProfileRepository {
  const ProfileRepository(this.api, {this.reminders});
  final ApiClient api;
  final ReminderService? reminders;

  Future<Map<String, dynamic>> me() async =>
      await api.get('/users/me') as Map<String, dynamic>;
  Future<void> saveConsents(Map<String, bool> values) async {
    await api.put('/users/me/consents', body: values);
  }

  Future<void> saveReminders(bool enabled, String time) async {
    await api.put(
      '/users/me/reminders',
      body: {
        'chat_reminder_enabled': enabled,
        'chat_reminder_at': time,
      },
    );
    await reminders?.sync(requestPermission: enabled);
  }
}
