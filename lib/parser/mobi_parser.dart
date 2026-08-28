import 'dart:io';
import 'dart:typed_data';

import '../core/charset.dart';
import 'parser.dart';

/// HUFF/CDIC 压缩的 MOBI 暂不支持。
class MobiUnsupportedException implements Exception {
  const MobiUnsupportedException();
  @override
  String toString() =>
      '该 MOBI/AZW3 文件使用了 HUFF/CDIC 压缩，暂不支持，请转换成 EPUB 或 TXT 后导入';
}

/// MOBI / AZW3（KF8）解析。
///
/// 实现 PDB 容器 + PalmDOC(LZ77) 解压 + HTML 去标签。
/// HUFF/CDIC 压缩的少数 AZW3 文件暂不支持，会抛出友好错误。
class MobiParser {
  static ParsedBook parse(File file) {
    final bytes = file.readAsBytesSync();
    if (bytes.length < 132) throw const FormatException('文件太小，不是有效的 MOBI');

    // PDB 头：记录数在 76 偏移（u16），记录表从 78 开始，每项 8 字节
    final bd = ByteData.sublistView(bytes);
    final numRecords = bd.getUint16(76);
    if (numRecords == 0 || 78 + numRecords * 8 > bytes.length) {
      throw const FormatException('MOBI 记录表损坏');
    }
    final recordOffsets = List<int>.filled(numRecords + 1, bytes.length);
    for (int i = 0; i < numRecords; i++) {
      recordOffsets[i] = bd.getUint32(78 + i * 8);
    }
    recordOffsets[numRecords] = bytes.length;

    final rec0 = bytes.sublist(recordOffsets[0], recordOffsets[1]);
    final r0 = ByteData.sublistView(rec0);
    if (rec0.length < 16) throw const FormatException('MOBI 头部损坏');
    final compression = r0.getUint16(0);
    final textRecordCount = r0.getUint16(8);
    final encryption = r0.getUint16(12);

    if (encryption != 0) {
      throw const FormatException('该 MOBI 文件有加密（DRM），无法阅读');
    }

    String encodingName = 'utf8';
    int extraFlags = 0;
    // MOBI 扩展头
    if (rec0.length >= 24 &&
        rec0[16] == 0x4D && rec0[17] == 0x4F &&
        rec0[18] == 0x42 && rec0[19] == 0x49) {
      // 'MOBI'
      final mobiHeaderLen = r0.getUint32(20);
      final textEncoding = r0.getUint32(28);
      encodingName =
          textEncoding == 1252 ? 'windows1252' : (textEncoding == 65001 ? 'utf8' : 'gbk');
      // extra data flags 位于 MOBI 头内偏移 0xF2
      if (mobiHeaderLen >= 0xF2 + 2 && rec0.length >= 16 + 0xF2 + 4) {
        extraFlags = r0.getUint32(16 + 0xF2);
      }
    }

    // 简易 Latin-1（兼容 western 1252 主体区间）
    String decodeBytes(List<int> b) {
      if (encodingName == 'utf8') return CharsetDecoder.decode(b);
      if (encodingName == 'windows1252') {
        return b.map((e) => String.fromCharCode(e)).join();
      }
      return CharsetDecoder.decode(b);
    }

    // 文本记录：1 .. textRecordCount
    final buf = StringBuffer();
    for (int i = 1; i <= textRecordCount && i < numRecords; i++) {
      List<int> rec = bytes.sublist(recordOffsets[i], recordOffsets[i + 1]);
      switch (compression) {
        case 1: // 无压缩
          break;
        case 2: // PalmDOC
          rec = PalmDoc.decompress(rec);
        case 17480: // HUFF/CDIC
          throw const MobiUnsupportedException();
        default:
          throw const FormatException('未知的 MOBI 压缩方式');
      }
      rec = _trimTrailing(rec, extraFlags);
      buf.write(decodeBytes(rec));
    }

    final html = buf.toString();
    if (html.trim().isEmpty) throw const FormatException('MOBI 没有可读的正文');

    // MOBI 正文是 HTML：按 <mbp:pagebreak/> 或 <hrdbreak> 切章，去标签后按标题识别
    final rawSections =
        html.split(RegExp(r'<\s*mbp:pagebreak\s*/?\s*>|<\s*hr\s*/?\s*>',
            caseSensitive: false));
    final plain = rawSections
        .map((s) => _stripToText(s))
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (plain.isEmpty) throw const FormatException('MOBI 没有可读的正文');

    // 切章逻辑复用 TXT 的标题识别
    final title = file.uri.pathSegments.last;
    final joined = plain.join('\n');
    final chapters = _splitMobiChapters(joined);
    return ParsedBook(chapters.isEmpty ? [_fallback(title, joined)] : chapters);
  }

  static ParsedChapter _fallback(String title, String text) =>
      ParsedChapter(title, text);

  /// MOBI 正文切章：对每一段的第一行做章节标题识别。
  static List<ParsedChapter> _splitMobiChapters(String text) {
    // 动态导入会导致循环依赖，这里复制精简版判断
    final lines = text.split('\n');
    final marks = <int>[];
    for (int i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty || t.length > 50) continue;
      if (t.startsWith('第') &&
          RegExp(r'^第\s*[0-9〇零一二两三四五六七八九十百千万]+\s*[章节回卷部篇]').hasMatch(t)) {
        marks.add(i);
      } else if (RegExp(r'^chapter\s+\d+', caseSensitive: false).hasMatch(t)) {
        marks.add(i);
      }
    }
    if (marks.length < 2) return [];
    final chapters = <ParsedChapter>[];
    if (marks.first > 0) {
      final head = lines.sublist(0, marks.first).join('\n').trim();
      if (head.isNotEmpty) chapters.add(ParsedChapter('开篇', head));
    }
    for (int m = 0; m < marks.length; m++) {
      final start = marks[m];
      final end = m + 1 < marks.length ? marks[m + 1] : lines.length;
      final body = lines.sublist(start + 1, end).join('\n').trim();
      chapters.add(ParsedChapter(lines[start].trim(), body));
    }
    return chapters;
  }

  static String _stripToText(String html) {
    var s = html;
    s = s.replaceAll(
        RegExp(r'<(script|style)[^>]*>.*?</\1>',
            dotAll: true, caseSensitive: false),
        '');
    s = s.replaceAll(
        RegExp(r'</?(p|div|br|h[1-6]|li|blockquote|body|html)[^>]*/?>',
            caseSensitive: false),
        '\n');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    return s.replaceAll('\r\n', '\n').replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }

  /// 去除记录尾部的 extra data（trailing entries + multibyte overlap）。
  static List<int> _trimTrailing(List<int> data, int flags) {
    if (flags == 0 || data.isEmpty) return data;
    var end = data.length;
    int trailingSize(List<int> d, int len) {
      int n = 0;
      for (int i = len - 1; i >= 0; i--) {
        if (d[i] & 0x80 != 0) break;
        n++;
      }
      return n;
    }

    for (int bit = 1; bit < 16; bit++) {
      if (flags & (1 << bit) != 0) {
        end -= trailingSize(data, end);
        if (end < 0) return data;
      }
    }
    if (flags & 1 != 0 && end > 0) {
      end -= (data[end - 1] & 0x3) + 1;
      if (end < 0) return data;
    }
    return data.sublist(0, end);
  }

  /// 供单元测试使用的公开包装。
  static List<int> trimTrailingForTest(List<int> data, int flags) =>
      _trimTrailing(data, flags);
}

/// PalmDOC（LZ77 变体）解压。
class PalmDoc {
  static List<int> decompress(List<int> data) {
    final out = BytesBuilder(copy: false);
    int i = 0;
    final n = data.length;
    while (i < n) {
      final c = data[i++];
      if (c >= 1 && c <= 8) {
        // 后跟 c 个字面量
        final cnt = c;
        for (int k = 0; k < cnt && i < n; k++) {
          out.addByte(data[i++]);
        }
      } else if (c < 0x80) {
        out.addByte(c);
      } else if (c >= 0xC0) {
        out.addByte(0x20);
        out.addByte(c ^ 0x80);
      } else {
        // LZ77：11 位距离，3 位长度
        if (i >= n) break;
        final pair = (c << 8) | data[i++];
        final dist = (pair >> 3) & 0x7FF;
        final len = (pair & 0x7) + 3;
        final start = out.length - dist;
        if (start < 0) break;
        for (int k = 0; k < len; k++) {
          out.addByte(out.toBytes()[start + k]);
        }
      }
    }
    return out.toBytes();
  }
}
