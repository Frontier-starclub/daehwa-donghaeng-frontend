import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'api_client.dart';

/// Server schedules use Asia/Seoul. The OS owns delivery while the app is closed.
class ReminderService extends ChangeNotifier {
  ReminderService(this.api, {FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final ApiClient api;
  final FlutterLocalNotificationsPlugin _plugin;
  String? notice;
  String? pendingRoute;
  VoidCallback? onOpen;
  bool _initialized = false;
  Future<void> _queue = Future.value();

  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _initialize() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_medication'),
      ),
      onDidReceiveNotificationResponse: (response) => _opened(response.payload),
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp ?? false) {
      _opened(launch!.notificationResponse?.payload);
    }
    _initialized = true;
  }

  void _opened(String? payload) {
    try {
      final data = jsonDecode(payload ?? '') as Map<String, dynamic>;
      if (data['server'] != api.baseUrl) return;
      pendingRoute = data['route'] as String?;
      onOpen?.call();
    } catch (_) {/* An old notification can still open the home screen. */}
  }

  Future<void> sync({bool requestPermission = false}) {
    _queue = _queue.then((_) => _sync(requestPermission));
    return _queue;
  }

  Future<void> _sync(bool requestPermission) async {
    if (!supported) {
      notice = '정시 알림은 Android 앱에서 받을 수 있어요. 웹에서는 오늘의 약을 직접 확인해주세요.';
      notifyListeners();
      return;
    }
    try {
      await _initialize();
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()!;
      if (requestPermission) {
        await android.requestNotificationsPermission();
        await android.requestExactAlarmsPermission();
      }
      final granted = await android.areNotificationsEnabled() ?? false;
      final exact = await android.canScheduleExactNotifications() ?? false;
      final schedules = await api.get('/medication-schedules') as List<dynamic>;
      final user = await api.get('/users/me') as Map<String, dynamic>;
      final jobs = <Map<String, String>>[
        for (final item in schedules)
          {
            'key': 'med:${item['id']}',
            'time': item['remind_at'] as String,
            'route': 'medication',
            'title': '약을 드실 시간이에요',
            'body': '앱에서 오늘의 약을 확인하고 복용 여부를 알려주세요.',
          },
        if (user['chat_reminder_enabled'] == true)
          {
            'key': 'chat',
            'time': user['chat_reminder_at'] as String,
            'route': 'chat',
            'title': '오늘 이야기 나누실까요?',
            'body': '편하실 때 들러주세요. 오늘은 쉬셔도 괜찮아요.',
          },
      ];
      final prefs = await SharedPreferences.getInstance();
      final ids = Map<String, dynamic>.from(
        jsonDecode(
          prefs.getString('notification_ids') ?? '{}',
        ) as Map,
      );
      var next = prefs.getInt('next_notification_id') ?? 1;
      final desired = <int, Map<String, String>>{};
      for (final job in jobs) {
        final key = '${api.baseUrl}:${job['key']}';
        ids[key] ??= next++;
        desired[ids[key] as int] = job;
      }
      await prefs.setString('notification_ids', jsonEncode(ids));
      await prefs.setInt('next_notification_id', next);
      final pending = await _plugin.pendingNotificationRequests();
      for (final item in pending) {
        if (!desired.containsKey(item.id) || !granted) {
          await _plugin.cancel(item.id);
        }
      }
      if (!granted) {
        notice = '알림 권한이 꺼져 있어요. 설정에서 알림을 허용해주세요.';
      } else {
        final location = tz.getLocation('Asia/Seoul');
        for (final entry in desired.entries) {
          final job = entry.value;
          final payload =
              jsonEncode({...job, 'server': api.baseUrl, 'exact': exact});
          if (pending
              .any((item) => item.id == entry.key && item.payload == payload)) {
            continue;
          }
          final parts = job['time']!.split(':');
          final now = tz.TZDateTime.now(location);
          var when = tz.TZDateTime(
            location,
            now.year,
            now.month,
            now.day,
            int.parse(parts[0]),
            int.parse(parts[1]),
          );
          if (!when.isAfter(now)) {
            when = tz.TZDateTime(
              location,
              now.year,
              now.month,
              now.day + 1,
              int.parse(parts[0]),
              int.parse(parts[1]),
            );
          }
          await _plugin.zonedSchedule(
            entry.key,
            job['title'],
            job['body'],
            when,
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'daily_reminders',
                '복약과 대화 알림',
                importance: Importance.high,
                priority: Priority.high,
                visibility: NotificationVisibility.private,
              ),
            ),
            androidScheduleMode: exact
                ? AndroidScheduleMode.exactAllowWhileIdle
                : AndroidScheduleMode.inexactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.time,
            payload: payload,
          );
        }
        notice = exact ? null : '정확한 알람 권한이 없어 설정한 시각보다 늦게 알림이 올 수 있어요.';
      }
    } catch (_) {
      notice = '시간은 서버에 저장됐지만 기기 알림을 갱신하지 못했어요. 설정에서 다시 연결해주세요.';
    }
    notifyListeners();
  }
}
