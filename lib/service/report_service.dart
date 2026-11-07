import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/city_service/model/my_service_model.dart';
import 'package:town_pass/service/account_service.dart';
import 'package:town_pass/service/device_service.dart';
import 'package:town_pass/service/package_service.dart';
import 'package:town_pass/util/tp_route.dart';

/// 問題回報（PoC）：截圖 → 遮蔽個資 → 預覽 → 帶到論壇。
///
/// 論壇網頁以 `flutterObject` 的 `report_draft` 取得草稿，規格見
/// `docs/webview-bridge-spec.md`。
class ReportService extends GetxService {
  /// 論壇開啟回報草稿的網址；論壇偵測 `source=app-report` 後呼叫 `report_draft`
  static String get forumReportUrl {
    final Uri forum = Uri.parse(MyServiceItemId.forum.item.destinationUrl);
    return forum.replace(queryParameters: {'source': 'app-report'}).toString();
  }

  /// 只有這個網域可以讀取草稿
  static String get forumHost => Uri.parse(MyServiceItemId.forum.item.destinationUrl).host;

  /// 為 true 時，所有 [Sensitive] 元件改畫成色塊
  static final RxBool maskMode = RxBool(false);

  /// 包住整個 App 的截圖範圍
  static final GlobalKey boundaryKey = GlobalKey();

  /// 目前路由，供全域回報按鈕判斷是否顯示
  static final RxString currentRoute = RxString('/');

  static const int _maxRouteHistory = 10;
  static final List<String> _routeHistory = [];

  static const int _maxImageSide = 1280;
  static const Duration _draftTtl = Duration(minutes: 10);

  static final List<_WebViewEntry> _webViews = [];

  bool _capturing = false;

  /// 預覽中的截圖（PNG）
  Uint8List? pendingImage;

  _ReportDraft? _draft;

  /// GetMaterialApp.routingCallback
  static void onRoute(Routing? routing) {
    final String? route = routing?.current;
    if (route == null || route.isEmpty) {
      return;
    }
    currentRoute.value = route;
    if (_routeHistory.isEmpty || _routeHistory.last != route) {
      _routeHistory.add(route);
      if (_routeHistory.length > _maxRouteHistory) {
        _routeHistory.removeAt(0);
      }
    }
  }

  /// TPWebView 建立時登記，截圖時用來另外擷取 WebView 畫面
  static void registerWebView(InAppWebViewController controller, GlobalKey key) {
    _webViews.removeWhere((entry) => entry.key.currentContext == null);
    _webViews.add(_WebViewEntry(controller, key));
  }

  /// 截圖並開啟預覽頁
  Future<void> startReport() async {
    if (_capturing) {
      return;
    }
    _capturing = true;
    try {
      await _recordWebUrl();
      // 在進入預覽頁前記錄，避免路由變成 /report_preview
      _pendingContext = _diagnostics();
      pendingImage = await _capture();
    } catch (error) {
      debugPrint('[ReportService] 截圖失敗：$error');
      pendingImage = null;
    } finally {
      _capturing = false;
    }
    await Get.toNamed(TPRoute.reportPreview);
  }

  /// 預覽頁按「送到論壇」
  Future<void> submit({required String description, required bool attachImage}) async {
    final Uint8List? image = attachImage ? pendingImage : null;
    _draft = _ReportDraft(
      id: _randomId(),
      description: description,
      imageDataUrl: image == null ? null : 'data:image/png;base64,${base64Encode(image)}',
      context: _pendingContext ?? _diagnostics(),
      createdAt: DateTime.now(),
    );
    pendingImage = null;
    _pendingContext = null;
    Get.back();
    await TPRoute.openUri(uri: forumReportUrl);
  }

  void discard() {
    pendingImage = null;
    _pendingContext = null;
  }

  /// 論壇網頁讀取草稿：限論壇網域、只能讀一次、逾時作廢
  Map<String, dynamic>? takeDraft(WebUri? sourceOrigin) {
    if (sourceOrigin?.host != forumHost) {
      return null;
    }
    final _ReportDraft? draft = _draft;
    _draft = null;
    if (draft == null || DateTime.now().difference(draft.createdAt) > _draftTtl) {
      return null;
    }
    return draft.toJson();
  }

  Future<Uint8List?> _capture() async {
    final RenderRepaintBoundary? boundary = boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      return null;
    }

    final _WebViewEntry? webView = _activeWebView();
    maskMode.value = true;
    try {
      if (webView != null) {
        await webView.controller.evaluateJavascript(source: _maskScript(Get.find<AccountService>()));
      }
      // 等遮罩畫到畫面上
      await WidgetsBinding.instance.endOfFrame;
      await WidgetsBinding.instance.endOfFrame;
      if (webView != null) {
        await Future.delayed(const Duration(milliseconds: 150));
      }

      final double pixelRatio = boundary.size.longestSide == 0
          ? 1
          : min(ui.PlatformDispatcher.instance.views.first.devicePixelRatio, _maxImageSide / boundary.size.longestSide);
      final ui.Image appImage = await boundary.toImage(pixelRatio: pixelRatio);

      // RepaintBoundary 擷取不到 WebView（原生元件），需另外截圖再合成
      ui.Image? webImage;
      Rect? webRect;
      if (webView != null) {
        final Uint8List? bytes = await webView.controller.takeScreenshot();
        final RenderBox? box = webView.key.currentContext?.findRenderObject() as RenderBox?;
        if (bytes != null && box != null) {
          webImage = await decodeImageFromList(bytes);
          final Offset topLeft = box.localToGlobal(Offset.zero, ancestor: boundary);
          webRect = Rect.fromLTWH(topLeft.dx * pixelRatio, topLeft.dy * pixelRatio, box.size.width * pixelRatio, box.size.height * pixelRatio);
        }
      }

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      canvas.drawImage(appImage, Offset.zero, Paint());
      if (webImage != null && webRect != null) {
        canvas.drawImageRect(
          webImage,
          Rect.fromLTWH(0, 0, webImage.width.toDouble(), webImage.height.toDouble()),
          webRect,
          Paint()..filterQuality = FilterQuality.medium,
        );
      }
      final ui.Image composed = await recorder.endRecording().toImage(appImage.width, appImage.height);
      final ByteData? data = await composed.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      maskMode.value = false;
      if (webView != null) {
        await webView.controller.evaluateJavascript(source: _unmaskScript);
      }
    }
  }

  /// 目前畫面最上層、可見的 WebView
  _WebViewEntry? _activeWebView() {
    _webViews.removeWhere((entry) => entry.key.currentContext == null);
    for (final _WebViewEntry entry in _webViews.reversed) {
      final BuildContext? context = entry.key.currentContext;
      if (context != null && (ModalRoute.of(context)?.isCurrent ?? false)) {
        return entry;
      }
    }
    return null;
  }

  Map<String, dynamic> _diagnostics() {
    final device = Get.find<DeviceService>().androidDeviceInfo;
    final String? webUrl = _activeWebUrl;
    return {
      'route': currentRoute.value,
      'routeHistory': List<String>.from(_routeHistory),
      'webUrl': webUrl,
      'appVersion': Get.find<PackageService>().packageInfo?.version,
      'platform': defaultTargetPlatform.name,
      'osVersion': device?.version.release,
      'deviceModel': device?.model,
      'locale': ui.PlatformDispatcher.instance.locale.toLanguageTag(),
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  String? _activeWebUrl;

  /// 截圖當下的診斷資訊
  Map<String, dynamic>? _pendingContext;

  /// 截圖當下記錄 WebView 網址（只留 scheme、host、path，避免帶出 query 中的 token）
  Future<void> _recordWebUrl() async {
    final WebUri? url = await _activeWebView()?.controller.getUrl();
    _activeWebUrl = url == null ? null : '${url.scheme}://${url.host}${url.path}';
  }

  static String _randomId() {
    final Random random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 模糊 WebView 中的輸入欄位、[data-sensitive]，以及含使用者個資或個資格式的文字
  static String _maskScript(AccountService accountService) {
    final account = accountService.account;
    final List<String> known = [
      account?.id,
      account?.realName,
      account?.account,
      account?.birthday,
      account?.idNumber,
      account?.phoneNumber,
      account?.email,
      account?.residentAddress,
    ].whereType<String>().where((value) => value.length >= 2).toList();

    return '''
(() => {
  const known = ${jsonEncode(known)};
  // 身分證、手機、Email、經緯度（小數 4 位以上）
  const patterns = [/[A-Z][12]\\d{8}/, /09\\d{2}-?\\d{3}-?\\d{3}/, /[\\w.+-]+@[\\w-]+\\.[\\w.]+/, /\\b\\d{1,3}\\.\\d{4,}\\b/];
  const style = document.createElement('style');
  style.id = '__tp_mask_style';
  style.textContent = '.__tp_mask{filter:blur(8px)!important}';
  document.head.appendChild(style);
  document.querySelectorAll('input, textarea, [data-sensitive]').forEach(el => el.classList.add('__tp_mask'));
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const text = walker.currentNode.nodeValue;
    if (!text || !text.trim()) continue;
    if (known.some(v => text.includes(v)) || patterns.some(p => p.test(text))) {
      walker.currentNode.parentElement?.classList.add('__tp_mask');
    }
  }
})();
''';
  }

  static const String _unmaskScript = '''
(() => {
  document.getElementById('__tp_mask_style')?.remove();
  document.querySelectorAll('.__tp_mask').forEach(el => el.classList.remove('__tp_mask'));
})();
''';
}

class _WebViewEntry {
  final InAppWebViewController controller;
  final GlobalKey key;

  const _WebViewEntry(this.controller, this.key);
}

class _ReportDraft {
  final String id;
  final String description;
  final String? imageDataUrl;
  final Map<String, dynamic> context;
  final DateTime createdAt;

  const _ReportDraft({required this.id, required this.description, required this.imageDataUrl, required this.context, required this.createdAt});

  Map<String, dynamic> toJson() => {'id': id, 'description': description, 'image': imageDataUrl, 'context': context};
}
