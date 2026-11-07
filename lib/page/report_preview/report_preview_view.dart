import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/report_service.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_button.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// 問題回報預覽：確認截圖（已遮蔽個資）與描述後送到論壇
class ReportPreviewView extends StatefulWidget {
  const ReportPreviewView({super.key});

  @override
  State<ReportPreviewView> createState() => _ReportPreviewViewState();
}

class _ReportPreviewViewState extends State<ReportPreviewView> {
  final ReportService _service = Get.find<ReportService>();
  final TextEditingController _description = TextEditingController();
  bool _attachImage = true;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _service.pendingImage;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        // 送出時 submit() 已清空；直接返回則捨棄截圖
        if (didPop) _service.discard();
      },
      child: Scaffold(
        appBar: const TPAppBar(title: '回報問題'),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const TPText('畫面截圖', style: TPTextStyles.h3SemiBold),
              const SizedBox(height: 4),
              const TPText('個資欄位已自動遮蔽，網頁內容可能未完全遮蔽，送出前請確認。', style: TPTextStyles.caption, color: TPColors.grayscale500),
              const SizedBox(height: 8),
              if (image == null)
                const TPText('截圖失敗，仍可只送出文字描述。', color: TPColors.grayscale500)
              else
                Opacity(
                  opacity: _attachImage ? 1 : 0.3,
                  child: Container(
                    decoration: BoxDecoration(border: Border.all(color: TPColors.grayscale200)),
                    child: Image.memory(image, height: 420, fit: BoxFit.contain),
                  ),
                ),
              if (image != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const TPText('附上截圖'),
                  value: _attachImage,
                  activeThumbColor: TPColors.primary500,
                  onChanged: (value) => setState(() => _attachImage = value),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _description,
                maxLines: 4,
                decoration: const InputDecoration(hintText: '請描述遇到的問題（例如：按下送出後沒有反應）', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              TPButton.primary(
                text: '送到論壇',
                onPressed: () => _service.submit(description: _description.text.trim(), attachImage: _attachImage && image != null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
