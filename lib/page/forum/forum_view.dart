import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/page/city_service/model/my_service_model.dart';
import 'package:town_pass/service/report_service.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';

/// 論壇是主畫面的分頁；原生 AppBar 與其他底部分頁保持一致。
class ForumView extends StatefulWidget {
  final bool active;
  final int mainTabIndex;

  const ForumView({
    super.key,
    required this.active,
    required this.mainTabIndex,
  });

  @override
  State<ForumView> createState() => _ForumViewState();
}

class _ForumViewState extends State<ForumView> {
  final GlobalKey _webViewKey = GlobalKey();
  late bool _hasOpened;
  InAppWebViewController? _controller;

  /// 網頁有上一頁（含論壇用 pushState 疊的聊天室、對話框）
  bool _canGoBack = false;

  Future<void> _updateCanGoBack() async {
    final bool value = await _controller?.canGoBack() ?? false;
    if (mounted && value != _canGoBack) {
      setState(() => _canGoBack = value);
    }
  }

  @override
  void initState() {
    super.initState();
    _hasOpened = widget.active;
  }

  @override
  void didUpdateWidget(covariant ForumView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      _hasOpened = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 系統返回鍵：論壇是目前分頁且網頁有上一頁時先退網頁，否則照常（離開 App）。
    // IndexedStack 會保留其他分頁，所以只在論壇分頁顯示中才攔截。
    return PopScope(
      canPop: !(widget.active && _canGoBack),
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop) {
          await _controller?.goBack();
        }
      },
      child: _buildPage(),
    );
  }

  Widget _buildPage() {
    return Scaffold(
      appBar: TPAppBar(
        showLogo: true,
        title: '論壇',
        leading: IconButton(
          icon: Semantics(label: '帳戶', child: Assets.svg.iconPerson.svg()),
          onPressed: () => Get.toNamed(TPRoute.account),
        ),
        backgroundColor: TPColors.white,
      ),
      body: _hasOpened
          ? TPInAppWebView(
              key: _webViewKey,
              onWebViewCreated: (controller) {
                _controller = controller;
                ReportService.registerWebView(
                  controller,
                  _webViewKey,
                  mainTabIndex: widget.mainTabIndex,
                );
                final Uri forumUrl = Uri.parse(
                  MyServiceItemId.forum.item.destinationUrl,
                );
                controller.loadUrl(
                  urlRequest: URLRequest(
                    url: WebUri(
                      forumUrl
                          .replace(
                            queryParameters: {
                              ...forumUrl.queryParameters,
                              'appTab': 'forum',
                            },
                          )
                          .toString(),
                    ),
                  ),
                );
              },
              onUpdateVisitedHistory: (_, url, _) {
                ReportService.updateWebUrl(_webViewKey, url);
                _updateCanGoBack();
              },
              onLoadStop: (_, url) =>
                  ReportService.updateWebUrl(_webViewKey, url),
              onGeolocationPermissionsShowPrompt: (_, origin) async =>
                  GeolocationPermissionShowPromptResponse(
                    origin: origin,
                    allow: true,
                    retain: true,
                  ),
              onPermissionRequest: (_, request) async => PermissionResponse(
                resources: request.resources,
                action: await TPWebView.canGrantForumPermission(request)
                    ? PermissionResponseAction.GRANT
                    : PermissionResponseAction.DENY,
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
