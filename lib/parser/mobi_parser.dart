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
      // extra data flags：2 字节，位于 record0 偏移 16+0xF2（MOBI 头内 0xF2）
      if (mobiHeaderLen >= 0xF2 + 2 && rec0.length >= 16 + 0xF2 + 2) {
        extraFlags = r0.getUint16(16 + 0xF2);
      }
    }

    // 简易 Latin-1（兼容 western 1252 主体区间）
    // 文本记录是连续字节流按 4KB 切分的片段：必须先收集全部字节、
    // 最后整体解码一次。逐记录解码会把跨越边界的多字节汉字切碎，
    // 解码失败后整条记录回退 GBK，产生成段乱码。
    final allBytes = BytesBuilder(copy: false);
    for (int i = 1; i <= textRecordCount && i < numRecords; i++) {
      List<int> rec = bytes.sublist(recordOffsets[i], recordOffsets[i + 1]);
      switch (compression) {
        case 1: // 无压缩
          break;
        case 2: // PalmDOC
          rec = PalmDoc.decompress(rec);
          break;
        case 17480: // HUFF/CDIC
          throw const MobiUnsupportedException();
        default:
          throw const FormatException('未知的 MOBI 压缩方式');
      }
      rec = _trimTrailing(rec, extraFlags);
      allBytes.add(rec);
    }
    final rawBytes = allBytes.takeBytes();
    final String html;
    if (encodingName == 'windows1252') {
      html = rawBytes.map((e) => String.fromCharCode(e)).join();
    } else {
      html = CharsetDecoder.decode(rawBytes);
    }
    if (html.trim().isEmpty) throw const FormatException('MOBI 没有可读的正文');

    // MOBI 正文是 HTML：pagebreak/hr 视作段落边界（占位换行），整体去标签
    // （旧实现按 pagebreak 切 section 再 join 拼回，切分对结果无影响，白跑一轮）
    final normalized = html.replaceAll(
        RegExp(r'<\s*mbp:pagebreak\s*/?\s*>|<\s*hr\s*/?\s*>',
            caseSensitive: false),
        '\n');
    final joined = _stripToText(normalized);
    if (joined.trim().isEmpty) throw const FormatException('MOBI 没有可读的正文');
    final chapters = _splitMobiChapters(joined);
    return ParsedBook(chapters.isEmpty
        ? [_fallback(file.uri.pathSegments.last, joined)]
        : chapters);
  }

  static ParsedChapter _fallback(String title, String text) =>
      ParsedChapter(title, text);

  /// MOBI 正文切章：对每一段的第一行做章节标题识别。
  /// 正则提升为常量：逐行循环里每次新建 RegExp 是纯浪费。
  static final RegExp _chapterMarkCn =
      RegExp(r'^第\s*[0-9〇零一二两三四五六七八九十百千万]+\s*[章节回卷部篇]');
  static final RegExp _chapterMarkEn = RegExp(r'^chapter\s+\d+', caseSensitive: false);

  static List<ParsedChapter> _splitMobiChapters(String text) {
    // 动态导入会导致循环依赖，这里复制精简版判断
    final lines = text.split('\n');
    final marks = <int>[];
    for (int i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty || t.length > 50) continue;
      if (t.startsWith('第') && _chapterMarkCn.hasMatch(t)) {
        marks.add(i);
      } else if (_chapterMarkEn.hasMatch(t)) {
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
  ///
  /// 语义参照 DeDRM_tools 的 mobidedrm.py：
  /// - bit 0 = multibyte overlap：末字节低 2 位 + 1 个字节，先于其他条目裁剪；
  /// - bit 1..15：每个置位的 bit 对应一个 trailing entry，按 bit 从低到高的顺序
  ///   从尾部裁剪。每个 entry 的大小以"反向变长整数"编码存在尾部：
  ///   从末尾向前逐字节读，低 7 位为一组、越早读到的字节位权越高
  ///   （即存储时最高位组离尾部最远），最高位字节为 1 表示变长整数结束；
  ///   解码出的值 = entry 数据字节数，裁剪量 = 变长整数本身字节数 + 值。
  static List<int> _trimTrailing(List<int> data, int flags) {
    if (flags == 0 || data.isEmpty) return data;
    var end = data.length;

    // bit 0：multibyte overlap，位于最末尾
    if (flags & 1 != 0 && end > 0) {
      end -= (data[end - 1] & 0x3) + 1;
      if (end < 0) return data;
    }

    // bit 1..15：按从低到高的顺序处理每个置位 bit
    for (int bit = 1; bit < 16; bit++) {
      if (flags & (1 << bit) == 0) continue;
      // 反向变长整数：从当前末尾向前读（规格上限 4 字节）
      int numbytes = 0;
      int bits = 0;
      while (true) {
        final idx = end - 1 - numbytes;
        if (idx < 0 || numbytes >= 4) return data; // 数据异常：放弃裁剪
        numbytes++;
        bits += 7;
        if (data[idx] & 0x80 != 0) {
          bits -= 7;
          break;
        }
      }
      int value = 0;
      for (int n2 = 0; n2 < numbytes; n2++) {
        value += (data[end - 1 - n2] & 0x7F) << bits;
        bits -= 7;
      }
      end -= numbytes + value;
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
    // 输出放进可增长列表，LZ77 回引直接按下标读取。
    // 旧实现在回引循环里反复调用 out.toBytes()，每拷贝一个字节
    // 都要整包复制一次缓冲区，大文件解压会退化成 O(n²)。
    final out = <int>[];
    int i = 0;
    final n = data.length;
    while (i < n) {
      final c = data[i++];
      if (c >= 1 && c <= 8) {
        // 后跟 c 个字面量
        for (int k = 0; k < c && i < n; k++) {
          out.add(data[i++]);
        }
      } else if (c < 0x80) {
        out.add(c);
      } else if (c >= 0xC0) {
        out.add(0x20);
        out.add(c ^ 0x80);
      } else {
        // LZ77：11 位距离，3 位长度
        if (i >= n) break;
        final pair = (c << 8) | data[i++];
        final dist = (pair >> 3) & 0x7FF;
        final len = (pair & 0x7) + 3;
        final start = out.length - dist;
        // dist 允许小于 len（重叠拷贝），边写边读保持 LZ77 语义；
        // dist==0 是非法输入，跳过而不是越界崩溃
        if (start < 0 || dist <= 0) break;
        for (int k = 0; k < len; k++) {
          out.add(out[start + k]);
        }
      }
    }
    return Uint8List.fromList(out);
  }
}
