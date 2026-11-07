import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/report_service.dart';
import 'package:town_pass/util/tp_colors.dart';

/// 全域「回報問題」按鈕，疊在所有頁面左下角。
/// 位於截圖範圍（RepaintBoundary）之外，不會出現在截圖中。
class ReportButton extends StatelessWidget {
  const ReportButton({super.key});

  /// 和論壇「我要發問」相同的對話框問號（Lucide `message-circle-question-mark`，ISC 授權）
  static const String _questionIcon = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"/>
  <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/>
  <path d="M12 17h.01"/>
</svg>
''';

  @override
  Widget build(BuildContext context) {
    final double bottom = MediaQuery.paddingOf(context).bottom + 96;
    return Positioned(
      left: 16,
      bottom: bottom,
      child: Material(
        color: TPColors.white,
        shape: const CircleBorder(side: BorderSide(color: TPColors.primary500, width: 1.5)),
        elevation: 4,
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
    );
  }
}
