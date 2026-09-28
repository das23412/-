import 'dart:io';
import 'dart:typed_data';

import '../core/charset.dart';
import 'chapter_splitter.dart';
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
      final off = bd.getUint32(78 + i * 8);
      // 单调递增且不越界：损坏文件抛友好错误而不是裸 RangeError
      if (off < 78 + numRecords * 8 + 2 ||
          off > bytes.length ||
          (i > 0 && off <= recordOffsets[i - 1])) {
        throw const FormatException('MOBI 记录表损坏（偏移非法）');
      }
      recordOffsets[i] = off;
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
    int mobiVersion = 0;
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
      if (rec0.length >= 0x68 + 4) {
        mobiVersion = r0.getUint32(0x68);
      }
      // extra data flags：2 字节大端，位于 record0 绝对偏移 0xF2。
      // 存在条件（参照 mobidedrm）：mobiHeaderLen >= 0xE4 且 mobiVersion >= 5。
      if (mobiHeaderLen >= 0xE4 && mobiVersion >= 5 && rec0.length >= 0xF2 + 2) {
        extraFlags = r0.getUint16(0xF2);
      }
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
  /// 正则提升为常量；切分逻辑统一在 ChapterSplitter（三格式共用）。
  static final RegExp _chapterMarkCn =
      RegExp(r'^第\s*[0-9〇零一二两三四五六七八九十百千万]+\s*[章节回卷部篇]');
  static final RegExp _chapterMarkEn = RegExp(r'^chapter\s+\d+', caseSensitive: false);

  static List<ParsedChapter> _splitMobiChapters(String text) {
    final parts = ChapterSplitter.split(
      text: text,
      bookTitle: '',
      titlePatterns: [_chapterMarkCn, _chapterMarkEn],
    );
    return parts.map((p) => ParsedChapter(p.title, p.body)).toList();
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
  /// 语义逐行对照 DeDRM_tools mobidedrm.py 的 getSizeOfTrailingDataEntries：
  /// - bit 1..15（从低到高）：每个置位 bit 对应一个反向变长整数 entry，
  ///   从 `ptr[size-num-1]`（尾字节）向前读，【尾字节是最低 7 位】，
  ///   位权每次 +7；高位字节终止并计入该组；解码值 = 该 entry 的字节数；
  /// - bit 0 = multibyte overlap：位于所有 entry 之前，
  ///   `(倒数第 num+1 字节 & 0x3) + 1` 个字节；
  /// - 总裁剪量 = 各 entry 值之和 + multibyte 字节数。
  static List<int> _trimTrailing(List<int> data, int flags) {
    if (flags == 0 || data.isEmpty) return data;
    var num = 0;
    var testflags = flags >> 1;
    while (testflags != 0) {
      if (testflags & 1 != 0) {
        num += _sizeOfTrailingDataEntry(data, data.length - num);
      }
      testflags >>= 1;
    }
    if (flags & 1 != 0 && data.length - num - 1 >= 0) {
      num += (data[data.length - num - 1] & 0x3) + 1;
    }
    if (num <= 0 || num > data.length) return data; // 畸形防御
    return data.sublist(0, data.length - num);
  }

  /// mobidedrm getSizeOfTrailingDataEntry：尾字节最低 7 位起，向前位权 +7；
  /// 高位字节终止（其 7 位计入）；bitpos 上限 28（最多 4 字节）。
  static int _sizeOfTrailingDataEntry(List<int> ptr, int size) {
    var bitpos = 0;
    var result = 0;
    if (size <= 0) return result;
    while (true) {
      final v = ptr[size - 1];
      result |= (v & 0x7F) << bitpos;
      bitpos += 7;
      size -= 1;
      if ((v & 0x80) != 0 || bitpos >= 28 || size == 0) {
        return result;
      }
    }
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
