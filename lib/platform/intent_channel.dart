import 'package:flutter/foundation.dart';
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
    } on MissingPluginException {
      // 测试环境/宿主未注册渠道：静默降级
      return null;
    }
  }

  /// 监听应用运行中新收到的打开请求。
  static void onNewFilePath(void Function(String path) callback) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNewFilePath') {
        if (call.arguments is String) {
          callback(call.arguments as String);
        } else {
          // 原生侧参数类型变化时给出可见线索，而不是无声失效
          debugPrint('onNewFilePath 参数类型异常：${call.arguments.runtimeType}');
        }
      }
      return null;
    });
  }
}
