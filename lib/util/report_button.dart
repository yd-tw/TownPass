import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/report_service.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';

/// 全域「回報問題」按鈕，疊在所有頁面左下角（預覽頁除外）。
/// 位於截圖範圍（RepaintBoundary）之外，不會出現在截圖中。
class ReportButton extends StatelessWidget {
  const ReportButton({super.key});

  @override
  Widget build(BuildContext context) {
    final double bottom = MediaQuery.paddingOf(context).bottom + 96;
    return Obx(
      () => switch (ReportService.currentRoute.value == TPRoute.reportPreview) {
        true => const SizedBox.shrink(),
        false => Positioned(
          left: 16,
          bottom: bottom,
          child: Material(
            color: TPColors.white,
            shape: const CircleBorder(side: BorderSide(color: TPColors.primary500, width: 1.5)),
            elevation: 4,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => Get.find<ReportService>().startReport(),
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.bug_report_outlined, color: TPColors.primary500, size: 24),
              ),
            ),
          ),
        ),
      },
    );
  }
}
