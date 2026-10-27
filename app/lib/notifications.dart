import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models.dart';

/// Systemowe powiadomienia o zgłoszeniach. Na webie i Windows ich nie ma –
/// tam aplikacja pokazuje baner w oknie.
class Notifier {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;
  static void Function(int reportId)? onTap;

  static bool get supported => !kIsWeb && defaultTargetPlatform != TargetPlatform.windows;

  static Future<void> init() async {
    if (_ready || !supported) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
          macOS: DarwinInitializationSettings(),
          linux: LinuxInitializationSettings(defaultActionName: 'Pokaż na mapie'),
        ),
        onDidReceiveNotificationResponse: (resp) {
          final id = int.tryParse(resp.payload ?? '');
          if (id != null) onTap?.call(id);
        },
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      _ready = true;
    } catch (e) {
      debugPrint('Powiadomienia niedostępne: $e');
    }
  }

  static Future<void> show(Report r) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        r.id,
        r.message,
        [if (r.text.isNotEmpty) r.text, r.userName].join(' — '),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'reports',
            'Zgłoszenia',
            channelDescription: 'Znaleziska i zgłoszenia uczestników akcji',
            importance: Importance.max,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(presentSound: true),
          macOS: DarwinNotificationDetails(presentSound: true),
        ),
        payload: '${r.id}',
      );
    } catch (e) {
      debugPrint('Nie udało się pokazać powiadomienia: $e');
    }
  }
}
