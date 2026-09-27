import 'dart:convert';

import 'package:daehwa_donghaeng/core/api_client.dart';
import 'package:daehwa_donghaeng/core/device_id_store.dart';
import 'package:daehwa_donghaeng/core/reminders.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  late ApiClient api;
  late ReminderService service;
  late List<Map<String, dynamic>> schedules;
  late Map<int, Map<String, dynamic>> pending;
  late List<MethodCall> calls;
  var granted = true, exact = true, chat = true;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    schedules = [
      {'id': 's1', 'remind_at': '08:30:00'},
    ];
    pending = {};
    calls = [];
    granted = exact = chat = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
        case 'requestNotificationsPermission':
        case 'requestExactAlarmsPermission':
          return true;
        case 'getNotificationAppLaunchDetails':
          return {'notificationLaunchedApp': false};
        case 'areNotificationsEnabled':
          return granted;
        case 'canScheduleExactNotifications':
          return exact;
        case 'pendingNotificationRequests':
          return pending.values.toList();
        case 'zonedSchedule':
          final value = Map<String, dynamic>.from(call.arguments as Map);
          pending[value['id'] as int] = value;
          return null;
        case 'cancel':
          pending.remove((call.arguments as Map)['id']);
          return null;
        default:
          throw StateError('Unexpected native call ${call.method}');
      }
    });
    api = ApiClient(
      baseUrl: 'http://fixture/api/v1',
      deviceIdStore: DeviceIdStore(),
      httpClient: MockClient((request) async => http.Response(
          jsonEncode(
            request.url.path.endsWith('/medication-schedules')
                ? schedules
                : {
                    'chat_reminder_enabled': chat,
                    'chat_reminder_at': '19:00:00',
                  },
          ),
          200,),),
    );
    service = ReminderService(api);
  });
  tearDown(() {
    service.dispose();
    api.close();
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('daily Seoul reservations survive resync and removed jobs are cancelled',
      () async {
    await service.sync(requestPermission: true);
    expect(service.notice, isNull);
    expect(pending.length, 2);
    final first = pending.keys.toSet();
    expect(pending.values.every((job) => job['timeZoneName'] == 'Asia/Seoul'),
        isTrue,);
    expect(
        calls
            .where((call) => call.method == 'requestNotificationsPermission')
            .length,
        1,);
    await service.sync();
    expect(pending.keys.toSet(), first);
    expect(calls.where((call) => call.method == 'zonedSchedule').length, 2);
    schedules = [];
    chat = false;
    await service.sync();
    expect(pending, isEmpty);
  });

  test('denial cancels stale alarms and exact alarm denial is visible',
      () async {
    await service.sync();
    granted = false;
    await service.sync();
    expect(pending, isEmpty);
    expect(service.notice, contains('알림 권한이 꺼져'));
    granted = true;
    exact = false;
    await service.sync();
    expect(pending.length, 2);
    expect(service.notice, contains('늦게'));
    expect(
        pending.values.every(
            (job) => jsonDecode(job['payload'] as String)['exact'] == false,),
        isTrue,);
  });
}
