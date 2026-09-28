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
  int get themeMode => (_prefs.getInt(_kThemeMode) ?? 0).clamp(0, 2);
  set themeMode(int v) => _prefs.setInt(_kThemeMode, v.clamp(0, 2));

  // ---------- 阅读器 ----------
  // 所有取值带范围钳制：历史/手工写入的越界值（如 lineHeight=0 导致除零）不再透传
  static const _kFontSize = 'reader_font_size';
  double get fontSize => (_prefs.getDouble(_kFontSize) ?? 19).clamp(12.0, 32.0);
  set fontSize(double v) => _prefs.setDouble(_kFontSize, v.clamp(12.0, 32.0));

  static const _kLineHeight = 'reader_line_height';
  double get lineHeight =>
      (_prefs.getDouble(_kLineHeight) ?? 1.8).clamp(1.0, 3.0);
  set lineHeight(double v) => _prefs.setDouble(_kLineHeight, v.clamp(1.0, 3.0));

  static const _kIndent = 'reader_indent';
  bool get indent => _prefs.getBool(_kIndent) ?? true;
  set indent(bool v) => _prefs.setBool(_kIndent, v);

  /// 翻页模式：0 仿真 / 1 平移 / 2 覆盖 / 3 上下滚动
  static const _kPageMode = 'reader_page_mode';
  int get pageMode => (_prefs.getInt(_kPageMode) ?? 0).clamp(0, 3);
  set pageMode(int v) => _prefs.setInt(_kPageMode, v.clamp(0, 3));

  /// 阅读背景索引：0 纸白 1 米黄 2 护眼绿 3 羊皮纸 4 夜黑 -1 自定义图片
  static const _kBgIndex = 'reader_bg_index';
  int get bgIndex => (_prefs.getInt(_kBgIndex) ?? 1).clamp(-1, 4);
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

  /// 扫描时被用户永久忽略的文件路径。
  static const _kIgnoredScanPaths = 'ignored_scan_paths';
  List<String> get ignoredScanPaths =>
      _prefs.getStringList(_kIgnoredScanPaths) ?? [];
  Future<void> setIgnoredScanPaths(List<String> v) =>
      _prefs.setStringList(_kIgnoredScanPaths, v);

  /// 「允许联网下载」总开关，默认关闭。
  /// 开关关闭时应用不发起任何网络请求；打开后也只在用户主动下载时联网。
  static const _kAllowNetworkDownload = 'allow_network_download';
  bool get allowNetworkDownload =>
      _prefs.getBool(_kAllowNetworkDownload) ?? false;
  set allowNetworkDownload(bool v) => _prefs.setBool(_kAllowNetworkDownload, v);

  /// 「书源联网」独立开关，默认关闭。
  /// 控制书源的搜索/目录/正文请求；与「允许联网下载」分开，
  /// 便于用户分别管控两类网络行为。
  static const _kAllowSources = 'allow_book_sources';
  bool get allowSources => _prefs.getBool(_kAllowSources) ?? false;
  set allowSources(bool v) => _prefs.setBool(_kAllowSources, v);
}
