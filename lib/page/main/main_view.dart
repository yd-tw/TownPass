import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/city_service/model/my_service_model.dart';
import 'package:town_pass/page/main/main_view_controller.dart';
import 'package:town_pass/service/report_service.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/util/tp_bottom_navigation_factory.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';

class MainView extends GetView<MainViewController> {
  const MainView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Obx(
        () => IndexedStack(
          index: controller.currentIndex.value,
          children: TPBottomNavigationFactory.viewList,
        ),
      ),
      // 論壇為主要功能，以浮動按鈕常駐於各分頁右下角
      floatingActionButton: GestureDetector(
        // 長按：回報目前畫面的問題
        onLongPress: () => Get.find<ReportService>().startReport(),
        child: FloatingActionButton.extended(
          heroTag: 'forum_fab',
          onPressed: () => TPRoute.openUri(uri: MyServiceItemId.forum.item.destinationUrl),
          backgroundColor: TPColors.primary500,
          foregroundColor: TPColors.white,
          icon: const Icon(Icons.forum_outlined),
          label: Text(
            MyServiceItemId.forum.item.title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Color(0x140B0D0E),
              blurRadius: 16,
              offset: Offset(0, -10),
              spreadRadius: 0,
            )
          ],
        ),
        child: Obx(
          () => BottomNavigationBar(
            type: BottomNavigationBarType.fixed,
            items: TPBottomNavigationFactory.barItemList,
            selectedItemColor: TPColors.primary500,
            unselectedItemColor: TPColors.grayscale950,
            selectedLabelStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
            ),
            showUnselectedLabels: true,
            currentIndex: controller.currentIndex.value,
            onTap: (index) => controller.currentIndex.value = index,
          ),
        ),
      ),
    );
  }
}
