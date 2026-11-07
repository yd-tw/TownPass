import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/chat_unread_service.dart';
import 'package:town_pass/service/notification_service.dart';

/// FCM 推播服務
///
/// - 未放入 `android/app/google-services.json` 時，Firebase 初始化會失敗，
///   此服務自動停用（[isAvailable] 為 false），App 其他功能不受影響。
/// - 推播 payload 約定：`data.url` 為點擊通知後要在 App 內開啟的網址，
///   規格見 `docs/fcm-push-spec.md`。
class PushService extends GetxService {
  bool _available = false;

  bool get isAvailable => _available;

  String? _token;

  /// 目前裝置的 FCM token；尚未取得或推播停用時為 null
  String? get token => _token;

  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _foregroundSub;
  StreamSubscription<RemoteMessage>? _openedSub;

  Future<PushService> init() async {
    try {
      await Firebase.initializeApp();
    } catch (error) {
      debugPrint('[PushService] Firebase 未設定，推播停用：$error');
      return this;
    }

    _available = true;

    // App 在前景時 FCM 不會自動顯示通知，改由本機通知顯示
    _foregroundSub = FirebaseMessaging.onMessage.listen(_showForegroundMessage);

    // App 在背景時，點擊系統顯示的推播通知
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen(_openMessage);

    // firebase_messaging 17 起 getToken / onTokenRefresh 標為 deprecated，改推 register() + FID。
    // 目前仍使用傳統 FCM registration token：後端可直接用 HTTP v1 `message.token` 發送，
    // 文件與 Admin SDK 支援完整；待 FID 直送方式穩定後再遷移。
    // ignore: deprecated_member_use
    _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((token) => _token = token);

    // 取得 token 失敗（例如無網路、無 Google Play 服務）不應阻擋 App 啟動
    unawaited(_fetchToken());

    return this;
  }

  /// 取得 FCM token；推播停用或取得失敗時回傳 null
  Future<String?> fetchToken() async {
    if (!_available) {
      return null;
    }
    return _token ?? await _fetchToken();
  }

  Future<String?> _fetchToken() async {
    try {
      // ignore: deprecated_member_use
      _token = await FirebaseMessaging.instance.getToken();
      if (kDebugMode) {
        // 僅 debug 版輸出，方便以 adb logcat 取得 token 測試推播
        debugPrint('[PushService] FCM token: $_token');
      }
    } catch (error) {
      debugPrint('[PushService] 取得 FCM token 失敗：$error');
    }
    return _token;
  }

  /// App 完全關閉時點擊推播通知啟動，需在路由就緒後呼叫
  Future<void> handleInitialMessage() async {
    if (!_available) {
      return;
    }
    final RemoteMessage? message = await FirebaseMessaging.instance.getInitialMessage();
    if (message != null) {
      _openMessage(message);
    }
  }

  void _showForegroundMessage(RemoteMessage message) {
    // 論壇回覆等推播：更新按鈕上的未讀數
    if (Get.isRegistered<ChatUnreadService>()) {
      Get.find<ChatUnreadService>().reload();
    }
    final RemoteNotification? notification = message.notification;
    final String? title = notification?.title ?? message.data['title'] as String?;
    final String? body = notification?.body ?? message.data['body'] as String?;
    if (title == null && body == null) {
      return;
    }
    NotificationService.showNotification(
      title: title,
      content: body,
      url: message.data['url'] as String?,
    );
  }

  void _openMessage(RemoteMessage message) {
    NotificationService.openUrl(message.data['url'] as String?);
  }

  @override
  void onClose() {
    _tokenRefreshSub?.cancel();
    _foregroundSub?.cancel();
    _openedSub?.cancel();
    super.onClose();
  }

  static String get platform => Platform.isIOS ? 'ios' : 'android';
}

