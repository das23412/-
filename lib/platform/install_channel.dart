import 'package:flutter/services.dart';

/// 拉起系统包安装器安装下载好的 APK。
class InstallChannel {
  InstallChannel._();
  static const MethodChannel _channel = MethodChannel('moyue/installer');

  /// 返回 null 表示已成功调起安装界面；否则返回错误信息。
  static Future<String?> installApk(String path) async {
    try {
      await _channel.invokeMethod<void>('installApk', path);
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '无法调起安装器';
    }
  }
}
