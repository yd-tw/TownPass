import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:town_pass/util/tp_route.dart';

class NotificationService extends GetxService {
  /// 本機通知與 FCM 推播共用的 Android 通知通道，
  /// 後端發送推播時 `android.notification.channel_id` 需使用此值。
  static const String androidChannelId = 'TownPass android notification id';
  static const String _androidChannelName = 'TownPass android notification channel name';

  static int _id = 0;
  static final FlutterLocalNotificationsPlugin _notificationInstance = FlutterLocalNotificationsPlugin();

  /// App 因點擊本機通知而啟動時的 payload（url），待路由就緒後處理
  String? _launchPayload;

  Future<NotificationService> init() async {
    final NotificationAppLaunchDetails? launchDetails = await _notificationInstance.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _launchPayload = launchDetails?.notificationResponse?.payload;
    }

    final InitializationSettings initializationSettings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );

    await _notificationInstance.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (response) => openUrl(response.payload),
    );

    // 預先建立通道，讓 App 在背景時由系統顯示的 FCM 推播也能套用相同設定
    await _notificationInstance
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            androidChannelId,
            _androidChannelName,
            importance: Importance.max,
          ),
        );

    return this;
  }

  static Future<void> requestPermission() async {
    if (Platform.isAndroid) {
      await _notificationInstance.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _notificationInstance.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
    }
  }

  /// 顯示本機通知；[url] 為點擊通知後要開啟的網址（`https://…` 或 `local://…`）
  static Future<void> showNotification({String? title, String? content, String? url}) async {
    await _notificationInstance.show(
      id: _id++,
      title: title,
      body: content,
      payload: url,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          androidChannelId,
          _androidChannelName,
          importance: Importance.max,
          priority: Priority.max,
        ),
      ),
    );
  }

  /// 點擊通知後開啟網址，空值則不動作（僅回到 App）
  static void openUrl(String? url) {
    if (url == null || url.isEmpty) {
      return;
    }
    TPRoute.openUri(uri: url);
  }

  /// App 因點擊本機通知而啟動時，需在路由就緒後呼叫
  void handleLaunchNotification() {
    final String? payload = _launchPayload;
    _launchPayload = null;
    openUrl(payload);
  }
}
