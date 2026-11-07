import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/report_service.dart';
import 'package:town_pass/util/tp_colors.dart';

/// 標記含個資的元件；問題回報截圖時會改畫成色塊。
///
/// ```dart
/// Sensitive(child: TPText(account.idNumber))
/// ```
class Sensitive extends StatelessWidget {
  final Widget child;

  const Sensitive({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => switch (ReportService.maskMode.value) {
        // 保留原元件佔位（不可見），版面不跑掉
        true => Stack(
          children: [
            Opacity(opacity: 0, child: child),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(color: TPColors.grayscale300, borderRadius: BorderRadius.circular(4)),
              ),
            ),
          ],
        ),
        false => child,
      },
    );
  }
}
