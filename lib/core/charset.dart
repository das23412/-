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
    // UTF-16 无 BOM 猜测：前 64 字节中偶/奇位大量为 0
    if (bytes.length >= 64) {
      final sample = bytes.sublist(0, 64);
      int zeroEven = 0, zeroOdd = 0;
      for (int i = 0; i < 32; i++) {
        if (sample[i * 2] == 0) zeroEven++;
        if (sample[i * 2 + 1] == 0) zeroOdd++;
      }
      if (zeroEven > 28) return _decodeUtf16(bytes, littleEndian: false);
      if (zeroOdd > 28) return _decodeUtf16(bytes, littleEndian: true);
    }
    // UTF-8 严格解码失败则按 GBK 解码
    try {
      return utf8.decode(bytes);
    } on FormatException {
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
