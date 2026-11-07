import 'package:flutter/material.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/page/bill/bill_view.dart';
import 'package:town_pass/page/city_service/city_service_view.dart';
import 'package:town_pass/page/home/home_view.dart';
import 'package:town_pass/page/perk/perk_view.dart';
import 'package:town_pass/util/extension/svg_gen_image.dart';

class TPBottomNavigationFactory {
  static List<BottomNavigationBarItem> get barItemList => [
        BottomNavigationBarItem(
          icon: Assets.svg.iconTabbarServiceDefault.icon(),
          label: '服務',
        ),
        BottomNavigationBarItem(
          icon: Assets.svg.iconTabbarHomeDefault.icon(),
          label: '首頁',
        ),
        BottomNavigationBarItem(
          icon: Assets.svg.iconTabbarCouponDefault.icon(),
          label: '優惠',
        ),
        BottomNavigationBarItem(
          icon: Assets.svg.iconTabbarAccountDefault.icon(),
          label: '帳務',
        ),
      ];

  static List<Widget> get viewList => [
        const CityServiceView(),
        const HomeView(),
        const PerkView(),
        const BillView(),
      ];

  /// 各分頁的識別碼，順序同 [viewList]（問題回報記錄所在分頁用）
  static const List<String> tabIds = ['service', 'home', 'perk', 'bill'];

  /// default to "Home" page (index = 1)
  static int get defaultIndex => 1;
}
