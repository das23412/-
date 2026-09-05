/// 应用版本信息。发布新版本时与 pubspec.yaml 的 version 保持一致
/// （见 docs/发布检查清单.md）。
class AppInfo {
  static const version = '1.4.0';
  static const build = '7';
  static const display = 'v$version+$build';
}
