import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class LocalNotificationService {
  LocalNotificationService._();

  static const String _medicationChannelId = 'medication_alarm_channel_v2';
  static const String _medicationChannelName = 'Medication Alarms';
  static const String _medicationChannelDescription =
      'Medication reminders and dose alerts';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static const MethodChannel _platform = MethodChannel('arogion/timezone');

  static bool _initialized = false;
  static bool _canScheduleExact = false;

  static Future<void> initialize() async {
    if (_initialized) return;

    tz.initializeTimeZones();
    final zoneId = await _resolveDeviceTimeZone();
    try {
      tz.setLocalLocation(tz.getLocation(zoneId));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initializationSettings = InitializationSettings(
      android: androidSettings,
    );

    await _plugin.initialize(initializationSettings);

    final androidImplementation =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidImplementation?.requestNotificationsPermission();
    await androidImplementation?.requestExactAlarmsPermission();

    final notificationsEnabled = await androidImplementation?.areNotificationsEnabled();
    final exactAlarmAllowed = await androidImplementation?.canScheduleExactNotifications();
    _canScheduleExact = exactAlarmAllowed ?? false;
    debugPrint(
      '🔔 Notification permissions: enabled=$notificationsEnabled exactAlarm=$exactAlarmAllowed zone=$zoneId',
    );

    _initialized = true;
  }

  static int alarmNotificationId(String medicationId, int doseNumber) {
    final hash = medicationId.hashCode ^ (doseNumber * 7919);
    return hash.abs() % 2147483647;
  }

  static Future<void> scheduleDailyMedicationAlarm({
    required String medicationId,
    required String medicationName,
    required int doseNumber,
    required String doseLabel,
    required String alarmTime,
    required bool enabled,
    required String notificationType,
    required int notifyBeforeMinutes,
  }) async {
    await initialize();

    final id = alarmNotificationId(medicationId, doseNumber);
    await _plugin.cancel(id);

    if (!enabled) return;

    final parts = alarmTime.split(':');
    final hour = int.tryParse(parts[0]) ?? 8;
    final minute = int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0;

    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );

    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    final secondsUntilTrigger =
        scheduled.difference(now).inSeconds.clamp(0, 2147483647);

    debugPrint(
      '🔔 Scheduling med alarm: now=$now scheduled=$scheduled in=${secondsUntilTrigger}s time=$alarmTime type=$notificationType exact=$_canScheduleExact',
    );

    final normalizedType = notificationType.trim().toLowerCase();
    final playSound = normalizedType != 'silent' && normalizedType != 'vibration only';
    final enableVibration = normalizedType != 'silent' && normalizedType != 'sound only';

    final androidDetails = AndroidNotificationDetails(
      _medicationChannelId,
      _medicationChannelName,
      channelDescription: _medicationChannelDescription,
      importance: Importance.max,
      priority: Priority.high,
      playSound: playSound,
      enableVibration: enableVibration,
    );

    final alertBody = '$medicationName - $doseLabel at $alarmTime';

    await _plugin.zonedSchedule(
      id,
      'Medication Reminder',
      alertBody,
      scheduled,
      NotificationDetails(android: androidDetails),
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: _canScheduleExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: '$medicationId|$doseNumber',
    );

    final pending = await _plugin.pendingNotificationRequests();
    debugPrint(
      '🔔 Scheduled alarm: med=$medicationName dose=$doseNumber time=$alarmTime id=$id pending=${pending.length}',
    );
  }

  static Future<void> showTestNotificationNow() async {
    await initialize();

    const androidDetails = AndroidNotificationDetails(
      _medicationChannelId,
      _medicationChannelName,
      channelDescription: _medicationChannelDescription,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    await _plugin.show(
      987654321,
      'Medication Notifications Active',
      'Your alarm notification system is working.',
      const NotificationDetails(android: androidDetails),
    );
  }

  static Future<void> scheduleTestNotificationInSeconds({
    int seconds = 10,
  }) async {
    await initialize();

    final triggerInSeconds = seconds <= 0 ? 10 : seconds;
    final now = tz.TZDateTime.now(tz.local);
    final scheduled = now.add(Duration(seconds: triggerInSeconds));

    const androidDetails = AndroidNotificationDetails(
      _medicationChannelId,
      _medicationChannelName,
      channelDescription: _medicationChannelDescription,
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    await _plugin.zonedSchedule(
      987654320,
      'Medication Test Alarm',
      'This is a test notification to verify alarm delivery.',
      scheduled,
      const NotificationDetails(android: androidDetails),
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      androidScheduleMode: _canScheduleExact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'test',
    );
  }

  static Future<Map<String, bool>> getNotificationStatus() async {
    await initialize();

    final androidImplementation =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    final notificationsEnabled =
        await androidImplementation?.areNotificationsEnabled() ?? false;
    final exactAlarmAllowed =
        await androidImplementation?.canScheduleExactNotifications() ?? false;

    return {
      'notificationsEnabled': notificationsEnabled,
      'exactAlarmEnabled': exactAlarmAllowed,
    };
  }

  static Future<Map<String, bool>> requestNotificationPermissions() async {
    await initialize();

    final androidImplementation =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidImplementation?.requestNotificationsPermission();
    await androidImplementation?.requestExactAlarmsPermission();

    return getNotificationStatus();
  }

  static Future<void> cancelMedicationAlarm({
    required String medicationId,
    required int doseNumber,
  }) async {
    await initialize();
    await _plugin.cancel(alarmNotificationId(medicationId, doseNumber));
  }

  static Future<String> _resolveDeviceTimeZone() async {
    try {
      final zoneId = await _platform.invokeMethod<String>('getTimeZone');
      if (zoneId != null && zoneId.isNotEmpty) {
        return zoneId;
      }
    } catch (_) {
      // Fallback to UTC when native timezone call is unavailable.
    }

    return 'UTC';
  }
}
