import 'dart:convert';
import 'package:fast_gbk/fast_gbk.dart';

/// 文本编码识别与解码。
///
/// 优先级：BOM > UTF-8 严格校验 > GBK。
/// 中文小说最常见的存储编码就是 UTF-8 与 GBK 两种。
class CharsetDecoder {
  /// 解码字节为字符串，自动识别编码。
  static String decode(List<int> bytes) {
    if (bytes.isEmpty) return '';
    // BOM 检测
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
    // UTF-16 无 BOM 猜测：按 LE/BE 各试解一次样本，可读字符占比高者胜。
    // 旧启发式（大量 0x00）只对 ASCII 有效，中文正文（CJK 区两字节均非 0）判不出。
    if (bytes.length >= 64) {
      final le = _decodeUtf16(bytes.sublist(0, 64), littleEndian: true);
      if (_looksLikeText(le)) return _decodeUtf16(bytes, littleEndian: true);
      final be = _decodeUtf16(bytes.sublist(0, 64), littleEndian: false);
      if (_looksLikeText(be)) return _decodeUtf16(bytes, littleEndian: false);
    }
    // UTF-8 严格解码失败：先尝试容忍解码（单字节损坏只产生个别替换符），
    // 替换率低于阈值才采用；否则整本回退 GBK，避免一本书毁于一处坏字节
    try {
      return utf8.decode(bytes);
    } on FormatException {
      final lenient = utf8.decode(bytes, allowMalformed: true);
      int bad = 0;
      final runesList = lenient.runes.toList();
      for (final r in runesList) {
        if (r == 0xFFFD) bad++;
      }
      if (runesList.isNotEmpty && bad / runesList.length < 0.005) {
        return lenient;
      }
      return decodeGbk(bytes);
    }
  }

  /// 强制按 GBK 解码（HTML 声明 gbk/gb2312 时使用）。
  static String decodeGbk(List<int> bytes) {
    try {
      return gbk.decode(bytes, allowMalformed: true);
    } catch (_) {
      return gbk.decode(bytes);
    }
  }

  /// 样本文本可读性：CJK/ASCII/常见标点占比高且几乎无控制符即认为可读。
  static bool _looksLikeText(String sample) {
    if (sample.isEmpty) return false;
    var good = 0;
    for (final r in sample.runes) {
      if (r == 0 ||
          (r < 0x20 && r != 0x0A && r != 0x0D && r != 0x09) ||
          (r >= 0xE000 && r <= 0xF8FF)) {
        continue; // 控制符/私用区：不可读
      }
      good++;
    }
    return good / sample.runes.length > 0.85;
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
}
