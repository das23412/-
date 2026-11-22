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

  /// 按指定名字强制解码（阅读设置里的手动编码切换）。
  /// 支持 utf-8 / gbk / utf-16le / utf-16be / utf-16（BOM 感知）；
  /// 空或未知名字回落到自动识别 [decode]。
  static String decodeAs(String name, List<int> bytes) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return decode(bytes);
    if (n == 'utf-8' || n == 'utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (n == 'gbk' || n == 'gb2312' || n == 'gb18030') {
      return decodeGbk(bytes);
    }
    if (n == 'utf-16le' || n == 'utf16le') {
      return _decodeUtf16(bytes, littleEndian: true);
    }
    if (n == 'utf-16be' || n == 'utf16be') {
      return _decodeUtf16(bytes, littleEndian: false);
    }
    if (n == 'utf-16' || n == 'utf16') {
      if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: true);
      }
      if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: false);
      }
      return _decodeUtf16(bytes, littleEndian: true);
    }
    return decode(bytes);
  }

  /// windows-1252 高位区（0x80-0x9F）码表：27 个已定义码位 + 5 个未定义
  /// 位（0x81/0x8D/0x8F/0x90/0x9D，按 WHATWG 规范映射为字节本身）。
  /// €、各种弯引号、破折号、省略号等英文高频标点都在这一段，按
  /// Latin-1 逐字节映射全部错位。
  static const List<int?> _cp1252High = [
    0x20AC, null, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 0x80-0x87
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, null, 0x017D, null, // 0x88-0x8F
    null, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 0x90-0x97
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, null, 0x017E, 0x0178, // 0x98-0x9F
  ];

  /// 按 windows-1252 解码：0x80-0x9F 查 cp1252 码表，其余字节与 Latin-1
  /// 相同直接映射。整段一次性用 StringBuffer 构建，避免逐字节
  /// map().join() 产生海量小字符串对象。
  static String decodeWindows1252(List<int> bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      if (b >= 0x80 && b <= 0x9F) {
        final v = _cp1252High[b - 0x80];
        buf.write(v == null ? String.fromCharCode(b) : String.fromCharCode(v));
      } else {
        buf.writeCharCode(b);
      }
    }
    return buf.toString();
  }

  /// 样本文本可读性：CJK/ASCII/常见标点占比高且几乎无控制符即认为可读。
  static bool _looksLikeText(String sample) {
    if (sample.isEmpty) return false;
    var good = 0;
    for (final r in sample.runes) {
      // 可读 = ASCII 可打印 / CJK 统一表意 / CJK 标点 / 全角形式 / 常见空白。
      // 注意不能把"非控制符"当可读：ASCII 文本被按 UTF-16 解码会产生
      // 大量 CJK 部首扩展区的怪符号，宽松判定会把纯 ASCII 误判成 UTF-16。
      if ((r >= 0x20 && r <= 0x7E) ||
          (r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3000 && r <= 0x303F) ||
          (r >= 0xFF00 && r <= 0xFFEF) ||
          r == 0x0A || r == 0x0D || r == 0x09) {
        good++;
      }
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
