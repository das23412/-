import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置（全部本地存储，无联网）。
class AppSettings {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ---------- 主题：0 跟随系统 / 1 浅色 / 2 深色 ----------
  static const _kThemeMode = 'theme_mode';
  int get themeMode => _prefs.getInt(_kThemeMode) ?? 0;
  set themeMode(int v) => _prefs.setInt(_kThemeMode, v);

  // ---------- 阅读器 ----------
  static const _kFontSize = 'reader_font_size';
  double get fontSize => _prefs.getDouble(_kFontSize) ?? 19;
  set fontSize(double v) => _prefs.setDouble(_kFontSize, v);

  static const _kLineHeight = 'reader_line_height';
  double get lineHeight => _prefs.getDouble(_kLineHeight) ?? 1.8;
  set lineHeight(double v) => _prefs.setDouble(_kLineHeight, v);

  static const _kIndent = 'reader_indent';
  bool get indent => _prefs.getBool(_kIndent) ?? true;
  set indent(bool v) => _prefs.setBool(_kIndent, v);

  /// 翻页模式：0 仿真 / 1 平移 / 2 覆盖 / 3 上下滚动
  static const _kPageMode = 'reader_page_mode';
  int get pageMode => _prefs.getInt(_kPageMode) ?? 0;
  set pageMode(int v) => _prefs.setInt(_kPageMode, v);

  /// 阅读背景索引：0 纸白 1 米黄 2 护眼绿 3 羊皮纸 4 夜黑 -1 自定义图片
  static const _kBgIndex = 'reader_bg_index';
  int get bgIndex => _prefs.getInt(_kBgIndex) ?? 1;
  set bgIndex(int v) => _prefs.setInt(_kBgIndex, v);

  static const _kCustomBg = 'reader_custom_bg';
  String get customBgPath => _prefs.getString(_kCustomBg) ?? '';
  set customBgPath(String v) => _prefs.setString(_kCustomBg, v);

  static const _kCustomFont = 'reader_custom_font';
  String get customFontPath => _prefs.getString(_kCustomFont) ?? '';
  set customFontPath(String v) => _prefs.setString(_kCustomFont, v);

  static const _kDarkFollowNight = 'reader_dark_follow';
  bool get darkBgInNight => _prefs.getBool(_kDarkFollowNight) ?? true;
  set darkBgInNight(bool v) => _prefs.setBool(_kDarkFollowNight, v);

  // ---------- 扫描文件夹 ----------
  static const _kScanFolders = 'scan_folders';
  List<String> get scanFolders => _prefs.getStringList(_kScanFolders) ?? [];
  Future<void> setScanFolders(List<String> v) =>
      _prefs.setStringList(_kScanFolders, v);

  static const _kFirstScanDone = 'first_scan_done';
  bool get firstScanDone => _prefs.getBool(_kFirstScanDone) ?? false;
  set firstScanDone(bool v) => _prefs.setBool(_kFirstScanDone, v);
}
