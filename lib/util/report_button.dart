import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/report_service.dart';
import 'package:town_pass/util/tp_colors.dart';

/// 全域「回報問題」按鈕，疊在所有頁面右下角。
/// 使用者長按後可以拖曳到螢幕上任意位置（只在本次執行期間記住位置）。
/// 位於截圖範圍（RepaintBoundary）之外，不會出現在截圖中。
class ReportButton extends StatefulWidget {
  const ReportButton({super.key});

  @override
  State<ReportButton> createState() => _ReportButtonState();
}

class _ReportButtonState extends State<ReportButton> {
  /// 按鈕的實際尺寸（內距 + 圖示 + 邊框）
  static const double _size = 56;

  /// 離螢幕邊緣的最小距離
  static const double _edgeGap = 8;

  /// 和論壇「我要發問」相同的對話框問號（Lucide `message-circle-question-mark`，ISC 授權）
  static const String _questionIcon = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"/>
  <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/>
  <path d="M12 17h.01"/>
</svg>
''';

  /// 按鈕中心離螢幕右邊、下邊的距離；null 表示尚未設定，使用預設位置
  Offset? _anchor;

  /// 開始拖曳時的按鈕位置（用來計算拖曳位移）
  Offset? _dragStartAnchor;

  bool _dragging = false;

  Offset _defaultAnchor(BuildContext context) {
    final double bottom = MediaQuery.paddingOf(context).bottom + 96;
    return Offset(16, bottom);
  }

  /// 把位置限制在螢幕內，避免旋轉或拖出邊界後按鈕消失
  Offset _clamp(BuildContext context, Offset anchor) {
    final Size screen = MediaQuery.sizeOf(context);
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    final double minRight = _edgeGap;
    final double maxRight = screen.width - _size - _edgeGap;
    final double minBottom = padding.bottom + _edgeGap;
    final double maxBottom = screen.height - padding.top - _size - _edgeGap;
    return Offset(
      anchor.dx.clamp(minRight, maxRight < minRight ? minRight : maxRight).toDouble(),
      anchor.dy.clamp(minBottom, maxBottom < minBottom ? minBottom : maxBottom).toDouble(),
    );
  }

  void _onLongPressStart(BuildContext context) {
    setState(() {
      _dragging = true;
      _dragStartAnchor = _anchor ?? _defaultAnchor(context);
    });
  }

  void _onLongPressMoveUpdate(BuildContext context, LongPressMoveUpdateDetails details) {
    final Offset start = _dragStartAnchor ?? _defaultAnchor(context);
    // 手指往右移，按鈕要往右（right 變小）；手指往下移，按鈕要往下（bottom 變小）
    setState(() {
      _anchor = _clamp(
        context,
        Offset(start.dx - details.offsetFromOrigin.dx, start.dy - details.offsetFromOrigin.dy),
      );
    });
  }

  void _onLongPressEnd() {
    setState(() {
      _dragging = false;
      _dragStartAnchor = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Offset anchor = _clamp(context, _anchor ?? _defaultAnchor(context));
    return Positioned(
      right: anchor.dx,
      bottom: anchor.dy,
      child: GestureDetector(
        onLongPressStart: (_) => _onLongPressStart(context),
        onLongPressMoveUpdate: (details) => _onLongPressMoveUpdate(context, details),
        onLongPressEnd: (_) => _onLongPressEnd(),
        onLongPressCancel: _onLongPressEnd,
        child: AnimatedScale(
          scale: _dragging ? 1.1 : 1,
          duration: const Duration(milliseconds: 150),
          child: Material(
            color: TPColors.white,
            shape: const CircleBorder(side: BorderSide(color: TPColors.primary500, width: 1.5)),
            elevation: _dragging ? 8 : 4,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Get.find<ReportService>().startReport(),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SvgPicture.string(
                  _questionIcon,
                  width: 28,
                  height: 28,
                  colorFilter: const ColorFilter.mode(TPColors.primary500, BlendMode.srcIn),
                  semanticsLabel: '回報問題',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
