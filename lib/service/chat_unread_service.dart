import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/account_service.dart';
import 'package:town_pass/service/report_service.dart';

/// 論壇聊天的未讀數，顯示在回報／聊天按鈕的紅色數字。
///
/// App 自己用 `account.id` 向論壇後端登入（和論壇網頁相同的 `POST /sessions`），
/// 再從 `GET /notifications?unread_only=true` 算出和自己問題有關的未讀通知。
/// 論壇網頁在聊天室把通知標為已讀後，會送 `chat_unread_changed` 請 App 重抓。
class ChatUnreadService extends GetxService with WidgetsBindingObserver {
  static const String _apiBase = 'https://tpcodefest.mcloudtw.com/api/v1';

  /// 算進聊天未讀的通知類型：別人回覆或協助自己的問題。
  /// 附近有人發問、獲得徽章等不算。
  static const Set<String> _chatTypes = {
    'new_answer',
    'answer_accepted',
    'assist_claimed',
    'assist_arrived',
    'assist_completed',
    'assist_cancelled',
  };

  static const int _pageLimit = 50;
  static const int _maxPages = 5;
  static const Duration _pollInterval = Duration(seconds: 60);
  static const Duration _timeout = Duration(seconds: 10);

  /// 未讀數；沒登入、沒網路時為 0
  final RxInt unreadCount = RxInt(0);

  final HttpClient _client = HttpClient()..connectionTimeout = _timeout;

  String? _token;

  /// 取得 token 時用的使用者，換帳號時要重新登入
  String? _tokenUserId;

  Timer? _timer;
  Worker? _routeWorker;

  /// 正在抓時又被要求重抓：抓完再抓一次
  bool _loading = false;
  bool _pending = false;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    // 換頁（例如關掉論壇 WebView 回到 App）時重抓
    _routeWorker = ever(ReportService.currentRoute, (_) => reload());
    _startPolling();
    reload();
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _routeWorker?.dispose();
    _timer?.cancel();
    _client.close(force: true);
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
      reload();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // 背景時不輪詢，收到推播或回到前景再抓
      _timer?.cancel();
      _timer = null;
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => reload());
  }

  /// 重新向後端取得未讀數；失敗時維持原本的數字
  Future<void> reload() async {
    if (_loading) {
      _pending = true;
      return;
    }
    _loading = true;
    try {
      do {
        _pending = false;
        final int? count = await _fetchUnreadCount();
        if (count != null) {
          unreadCount.value = count;
        }
      } while (_pending);
    } finally {
      _loading = false;
    }
  }

  Future<int?> _fetchUnreadCount() async {
    final String? userId = Get.find<AccountService>().account?.id;
    if (userId == null || userId.isEmpty) {
      return 0;
    }
    try {
      int count = 0;
      String? cursor;
      for (int page = 0; page < _maxPages; page++) {
        final Map<String, String> query = {
          'unread_only': 'true',
          'limit': '$_pageLimit',
          'cursor': ?cursor,
        };
        final Map<String, dynamic>? body = await _get(userId, '/notifications', query);
        if (body == null) {
          return null;
        }
        final List<dynamic> list = body['data'] as List<dynamic>? ?? const [];
        count += list.where((item) => item is Map && _chatTypes.contains(item['type'])).length;
        cursor = body['next_cursor'] as String?;
        if (cursor == null || cursor.isEmpty) {
          break;
        }
      }
      return count;
    } catch (error) {
      debugPrint('[ChatUnreadService] 取得未讀數失敗：$error');
      return null;
    }
  }

  /// 帶 token 的 GET；token 失效（401）時重新登入一次再重試
  Future<Map<String, dynamic>?> _get(String userId, String path, Map<String, String> query) async {
    final Uri uri = Uri.parse('$_apiBase$path').replace(queryParameters: query);
    for (int attempt = 0; attempt < 2; attempt++) {
      final String? token = await _ensureToken(userId, renew: attempt > 0);
      if (token == null) {
        return null;
      }
      final HttpClientRequest request = await _client.getUrl(uri).timeout(_timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final HttpClientResponse response = await request.close().timeout(_timeout);
      final String text = await response.transform(utf8.decoder).join().timeout(_timeout);
      if (response.statusCode == HttpStatus.unauthorized) {
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        debugPrint('[ChatUnreadService] GET $path 回傳 ${response.statusCode}');
        return null;
      }
      return jsonDecode(text) as Map<String, dynamic>;
    }
    return null;
  }

  /// 規格：只傳 townpass_user_id 和暱稱，不傳姓名、身分證字號或電話
  Future<String?> _ensureToken(String userId, {bool renew = false}) async {
    if (!renew && _token != null && _tokenUserId == userId) {
      return _token;
    }
    _token = null;
    final String? username = Get.find<AccountService>().account?.username;
    final HttpClientRequest request = await _client.postUrl(Uri.parse('$_apiBase/sessions')).timeout(_timeout);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({
      'townpass_user_id': userId,
      if (username != null && username.isNotEmpty) 'nickname': username.characters.take(30).toString(),
    }));
    final HttpClientResponse response = await request.close().timeout(_timeout);
    final String text = await response.transform(utf8.decoder).join().timeout(_timeout);
    if (response.statusCode != HttpStatus.created && response.statusCode != HttpStatus.ok) {
      debugPrint('[ChatUnreadService] 登入論壇後端失敗：${response.statusCode}');
      return null;
    }
    final Map<String, dynamic>? data = (jsonDecode(text) as Map<String, dynamic>)['data'] as Map<String, dynamic>?;
    _token = data?['token'] as String?;
    _tokenUserId = userId;
    return _token;
  }
}
