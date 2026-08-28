import 'package:flutter/material.dart';

import '../data/settings.dart';

/// 应用主题状态：跟随系统 / 浅色 / 深色。
class ThemeState extends ChangeNotifier {
  ThemeState() {
    _mode = _fromInt(AppSettings.instance.themeMode);
  }

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  void setMode(ThemeMode m) {
    _mode = m;
    AppSettings.instance.themeMode = m.index;
    notifyListeners();
  }

  static ThemeMode _fromInt(int v) {
    switch (v) {
      case 1:
        return ThemeMode.light;
      case 2:
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
