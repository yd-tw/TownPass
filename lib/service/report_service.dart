import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/city_service/model/my_service_model.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/account_service.dart';
import 'package:town_pass/service/device_service.dart';
import 'package:town_pass/service/package_service.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_bottom_navigation_factory.dart';
import 'package:town_pass/util/tp_route.dart';

/// 問題回報（PoC）：截圖 → 遮蔽個資 → 直接開啟論壇「我要發問」並帶入截圖。
///
/// 論壇網頁以 `flutterObject` 的 `report_draft` 取得草稿，規格見
/// `docs/webview-bridge-spec.md`。
class ReportService extends GetxService {
  /// 論壇「我要發問」頁；偵測到 `source=app-report` 後呼叫 `report_draft`
  static String get forumReportUrl {
    final Uri forum = Uri.parse(MyServiceItemId.forum.item.destinationUrl);
    return forum.replace(path: '/new', queryParameters: {'source': 'app-report'}).toString();
  }

  /// 只有這個網域可以讀取草稿
  static String get forumHost => Uri.parse(MyServiceItemId.forum.item.destinationUrl).host;

  /// 論壇聊天列表
  static String get forumChatUrl {
    final Uri forum = Uri.parse(MyServiceItemId.forum.item.destinationUrl);
    return forum.replace(path: '/chat').toString();
  }

  /// 最上層頁面是論壇「我要發問」（/new）：回報按鈕改成聊天按鈕
  static final RxBool onAskPage = RxBool(false);

  /// 為 true 時，所有 [Sensitive] 元件改畫成色塊
  static final RxBool maskMode = RxBool(false);

  /// 包住整個 App 的截圖範圍
  static final GlobalKey boundaryKey = GlobalKey();

  /// 目前路由
  static final RxString currentRoute = RxString('/');

  static const int _maxRouteHistory = 10;
  static final List<String> _routeHistory = [];

  /// 最上層的路由（可能是對話框或底部彈窗）
  static Route<dynamic>? _topRoute;

  /// 最上層的頁面（不含對話框、底部彈窗）
  static Route<dynamic>? _pageRoute;

  /// WebView 網址中可以保留的 query 參數（其餘可能含 token，一律刪除）
  static Set<String> _allowedQueryKeys(String host) => host == forumHost ? const {'question'} : const {};

  static const int _maxImageSide = 1280;
  static const Duration _draftTtl = Duration(minutes: 10);

  static final List<_WebViewEntry> _webViews = [];

  bool _capturing = false;

  _ReportDraft? _draft;

  /// GetMaterialApp.routingCallback
  static void onRoute(Routing? routing) {
    // GetX 在 push 時給新路由、pop 時給上一個路由，所以就是目前最上層的路由
    final Route<dynamic>? top = routing?.route;
    if (top != null) {
      _topRoute = top;
      if (top is PageRoute) {
        _pageRoute = top;
      }
    }

    final String? route = routing?.current;
    if (route == null || route.isEmpty) {
      return;
    }
    currentRoute.value = route;
    // routingCallback 當下新頁面可能還沒成為最上層，等這一幀結束再判斷一次
    _updateAskPage();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateAskPage());
    if (_routeHistory.isEmpty || _routeHistory.last != route) {
      _routeHistory.add(route);
      if (_routeHistory.length > _maxRouteHistory) {
        _routeHistory.removeAt(0);
      }
    }
  }

  /// WebView 建立時登記，截圖時用來另外擷取 WebView 畫面
  static void registerWebView(InAppWebViewController controller, GlobalKey key, {int? mainTabIndex}) {
    _webViews.removeWhere((entry) => entry.key.currentContext == null);
    _webViews.add(_WebViewEntry(controller, key, mainTabIndex: mainTabIndex));
  }

  /// 切換底部分頁後重新判斷目前是否位於發問頁。
  static void refreshActivePage() => _updateAskPage();

  /// WebView 網址改變（含 pushState）時呼叫。
  /// 用 [key] 找 WebView：回呼帶來的 controller 和建立時登記的不一定是同一個物件。
  static void updateWebUrl(GlobalKey key, Uri? url) {
    for (final _WebViewEntry entry in _webViews) {
      if (identical(entry.key, key)) {
        entry.url = url;
      }
    }
    _updateAskPage();
  }

  static void _updateAskPage() {
    final Uri? url = _activeWebView()?.url;
    onAskPage.value = url != null && url.host == forumHost && url.path == '/new';
  }

  /// 聊天按鈕：在目前的論壇 WebView 換成聊天列表，不在論壇時另開一層
  static Future<void> openChat() async {
    final _WebViewEntry? webView = _activeWebView();
    if (webView != null && webView.url?.host == forumHost) {
      await webView.controller.loadUrl(urlRequest: URLRequest(url: WebUri(forumChatUrl)));
      return;
    }
    await TPRoute.openUri(uri: forumChatUrl);
  }

  /// 截圖後直接開啟論壇「我要發問」，由網頁讀取草稿帶入截圖
  Future<void> startReport() async {
    if (_capturing) {
      return;
    }
    _capturing = true;
    Uint8List? image;
    Map<String, dynamic>? context;
    try {
      await _recordScreen();
      // 在開啟論壇前記錄，才是使用者按下回報時所在的畫面
      context = _diagnostics();
      image = await _capture();
    } catch (error) {
      // 截圖失敗仍開啟論壇，讓使用者用文字描述
      debugPrint('[ReportService] 截圖失敗：$error');
    } finally {
      _capturing = false;
    }
    _draft = _ReportDraft(
      id: _randomId(),
      // 描述改由使用者在論壇輸入；保留欄位相容舊版網頁
      description: '',
      imageDataUrl: image == null ? null : 'data:image/png;base64,${base64Encode(image)}',
      context: context ?? _diagnostics(),
      createdAt: DateTime.now(),
    );
    // 從 WebView（例如論壇本身）回報時，也要再開一層論壇
    await TPRoute.openUri(uri: forumReportUrl, preventDuplicates: false);
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

  /// 目前頁面上的 WebView（上面開著對話框時也算）
  static _WebViewEntry? _activeWebView() {
    _webViews.removeWhere((entry) => entry.key.currentContext == null);
    for (final _WebViewEntry entry in _webViews.reversed) {
      if (entry.mainTabIndex != null &&
          (!Get.isRegistered<MainViewController>() ||
              Get.find<MainViewController>().currentIndex.value != entry.mainTabIndex)) {
        continue;
      }
      final BuildContext? context = entry.key.currentContext;
      if (context != null && _isOnTopPage(context)) {
        return entry;
      }
    }
    return null;
  }

  /// [context] 是否屬於目前最上層的頁面
  static bool _isOnTopPage(BuildContext context) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null) {
      return false;
    }
    final Route<dynamic>? page = _pageRoute;
    return page != null && page.isActive ? identical(route, page) : route.isCurrent;
  }

  Map<String, dynamic> _diagnostics() {
    final device = Get.find<DeviceService>().androidDeviceInfo;
    final String? webUrl = _activeWebUrl;
    return {
      'screen': _screen ?? currentRoute.value,
      'screenTitle': _screenTitle,
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

  /// 截圖當下所在畫面的識別字串，例如 `/account`、`/main/home`（首頁分頁）、`web:tp2026.ydtw.net/new+dialog`
  String? _screen;

  /// 截圖當下標題列的文字
  String? _screenTitle;

  /// 截圖當下記錄所在畫面
  Future<void> _recordScreen() async {
    final String route = currentRoute.value.split('?').first;
    final WebUri? url = await _activeWebView()?.controller.getUrl();

    // WebView 網址只留 scheme、host、path，避免帶出 query 中的 token
    _activeWebUrl = url == null ? null : '${url.scheme}://${url.host}${url.path}';

    String screen;
    if (url != null) {
      final Set<String> allowed = _allowedQueryKeys(url.host);
      final Map<String, String> query = {
        for (final MapEntry<String, String> entry in url.queryParameters.entries)
          if (allowed.contains(entry.key)) entry.key: entry.value,
      };
      screen = 'web:${url.host}${url.path}${query.isEmpty ? '' : '?${Uri(queryParameters: query).query}'}';
    } else if (route == TPRoute.main) {
      // 不用 # 分隔：後端會把 page_route 從 ? 或 # 起的部分刪掉
      screen = '/main/${_mainTabId() ?? 'unknown'}';
    } else {
      screen = route;
    }

    final String? overlay = _overlayKind();
    _screen = overlay == null ? screen : '$screen+$overlay';
    _screenTitle = route == TPRoute.main ? _mainTabLabel() : _appBarTitle() ?? _fallbackTitles[route];
  }

  /// 標題列沒有文字的頁面，改用入口按鈕上的名稱
  static const Map<String, String> _fallbackTitles = {TPRoute.account: '帳戶'};

  /// 最上層開著對話框或底部彈窗時回傳 `dialog` / `sheet`
  static String? _overlayKind() {
    final Route<dynamic>? top = _topRoute;
    if (top == null || top is! PopupRoute || !top.isActive) {
      return null;
    }
    return top is ModalBottomSheetRoute || (Get.isBottomSheetOpen ?? false) ? 'sheet' : 'dialog';
  }

  static int? _mainTabIndex() =>
      Get.isRegistered<MainViewController>() ? Get.find<MainViewController>().currentIndex.value : null;

  static String? _mainTabId() {
    final int? index = _mainTabIndex();
    final List<String> ids = TPBottomNavigationFactory.tabIds;
    return index != null && index >= 0 && index < ids.length ? ids[index] : null;
  }

  static String? _mainTabLabel() {
    final int? index = _mainTabIndex();
    final List<BottomNavigationBarItem> items = TPBottomNavigationFactory.barItemList;
    return index != null && index >= 0 && index < items.length ? items[index].label : null;
  }

  /// 目前頁面上 [TPAppBar] 顯示的標題（WebView 頁面就是網頁 `<title>`）
  static String? _appBarTitle() {
    String? title;
    void visit(Element element) {
      final Widget widget = element.widget;
      if (widget is TPAppBar && _isOnTopPage(element)) {
        final String? value = widget.currentTitle;
        if (value != null && value.trim().isNotEmpty) {
          title = value.trim(); // 取最後一個，也就是最上層的
        }
      }
      element.visitChildElements(visit);
    }

    final BuildContext? root = boundaryKey.currentContext;
    if (root is Element) {
      root.visitChildElements(visit);
    }
    return title;
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
  final int? mainTabIndex;

  /// 目前網址（scheme、host、path 用來判斷頁面，不會送出）
  Uri? url;

  _WebViewEntry(this.controller, this.key, {this.mainTabIndex});
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
