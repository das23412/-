import 'package:flutter/material.dart';

/// 阅读背景主题。
class ReaderPalette {
  final String name;
  final Color background;
  final Color text;
  final Color secondary; // 菜单/控件次要色
  const ReaderPalette(this.name, this.background, this.text, this.secondary);
}

const List<ReaderPalette> readerPalettes = [
  ReaderPalette('纸白', Color(0xFFFCFAF7), Color(0xFF2B2B2B), Color(0xFF757575)),
  ReaderPalette('米黄', Color(0xFFF5EFDC), Color(0xFF3B3226), Color(0xFF8A7B5C)),
  ReaderPalette('护眼绿', Color(0xFFCCE8CF), Color(0xFF243B2B), Color(0xFF5E7D66)),
  ReaderPalette('羊皮纸', Color(0xFFE4D5B0), Color(0xFF40331E), Color(0xFF7C6A45)),
  ReaderPalette('夜黑', Color(0xFF121212), Color(0xFF9E9E9E), Color(0xFF6E6E6E)),
];

/// 字节大小格式化。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 中文时间描述：刚刚 / N分钟前 / 今天 HH:mm / 昨天 / N天前 / 日期。
String formatTimeCN(int ms) {
  if (ms <= 0) return '未读过';
  return _formatDay(ms);
}

/// 绝对日期时间（如书籍添加时间，语义与"最近阅读"不同）。
String formatDateTimeCN(int ms) {
  if (ms <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final two = (int v) => v.toString().padLeft(2, '0');
  return '${d.year}/${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
}

String _formatDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(d);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(d.year, d.month, d.day);
  final days = today.difference(that).inDays;
  if (days == 0) {
    return '今天 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  if (days == 1) return '昨天';
  if (days < 30) return '$days天前';
  return '${d.year}/${d.month}/${d.day}';
}

/// 全角数字/中文数字格式化的书号。
String chapterLabel(int index) => '第${index + 1}章';

/// 下载进度节流。
///
/// 网络回调按 TCP 分块触发，一秒可达数千次，逐次 setState 会造成
/// 不必要的重建风暴；只有间隔超过 [minIntervalMs] 毫秒、进度明显变化
/// 或下载完成时才建议刷新界面。
class ProgressThrottler {
  final int minIntervalMs;
  final double minFraction;

  int _lastAtMs = 0;
  int _lastReceived = -1;

  ProgressThrottler({this.minIntervalMs = 100, this.minFraction = 0.005});

  /// 是否应该把 (received, total) 刷到界面上。
  bool shouldEmit(int received, int total) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final finished = total > 0 && received >= total;
    final moved = total > 0 && (received - _lastReceived) >= total * minFraction;
    if (_lastReceived < 0 ||
        finished ||
        moved ||
        now - _lastAtMs >= minIntervalMs) {
      _lastAtMs = now;
      _lastReceived = received;
      return true;
    }
    return false;
  }

  /// 开始新一轮下载前重置。
  void reset() {
    _lastAtMs = 0;
    _lastReceived = -1;
  }
}
