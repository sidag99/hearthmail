import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Desktop/Android notifications for new mail.
class MailNotifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool? _permitted;
  int _nextId = 1;

  /// Called with the payload of a notification the user clicked.
  void Function(String payload)? onOpen;

  static bool get supported => Platform.isMacOS || Platform.isAndroid;

  Future<void> init() async {
    if (_ready || !supported) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // Permission is requested on the first new mail, not at launch.
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestSoundPermission: false,
            requestBadgePermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          final p = r.payload;
          if (p != null) onOpen?.call(p);
        },
      );
      _ready = true;
      // The app may have been launched by clicking a notification.
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final p = launch?.notificationResponse?.payload;
      if ((launch?.didNotificationLaunchApp ?? false) && p != null) {
        scheduleMicrotask(() => onOpen?.call(p));
      }
    } catch (_) {
      // Notifications are a nicety; never break mail over them.
    }
  }

  /// Asks once (the OS remembers the answer). True if allowed.
  Future<bool> ensurePermission() async {
    if (_permitted != null) return _permitted!;
    if (!_ready) return false;
    try {
      bool? ok;
      if (Platform.isMacOS) {
        ok = await _plugin
            .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, sound: true);
      } else if (Platform.isAndroid) {
        ok = await _plugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      _permitted = ok ?? false;
    } catch (_) {
      _permitted = false;
    }
    return _permitted!;
  }

  Future<void> show({required String title, required String body, required String payload}) async {
    if (!await ensurePermission()) return;
    try {
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        payload: payload,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails('new_mail', 'New mail',
              channelDescription: 'New messages in your inbox', importance: Importance.high, priority: Priority.high),
          macOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }
}
