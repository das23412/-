import 'package:flutter/services.dart';

/// 与原生 MainActivity 通信，接收“用墨阅打开”的文件。
///
/// 原生侧会把 content:// URI 拷贝到应用缓存目录后返回真实文件路径，
/// Flutter 侧无需存储权限即可读取。
class IntentChannel {
  IntentChannel._();
  static const MethodChannel _channel = MethodChannel('moyue/intent');

  /// 应用启动时携带的文件路径（若有）。
  static Future<String?> initialFilePath() async {
    try {
      return await _channel.invokeMethod<String>('initialFilePath');
    } on PlatformException {
      return null;
    }
  }

  /// 监听应用运行中新收到的打开请求。
  static void onNewFilePath(void Function(String path) callback) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNewFilePath' && call.arguments is String) {
        callback(call.arguments as String);
      }
      return null;
    });
  }
}
