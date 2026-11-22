import 'dart:io';

import '../core/charset.dart';
import '../core/text_utils.dart';
import 'chapter_splitter.dart';
import 'parser.dart';

/// 单个 HTML 文件小说解析。
class HtmlParser {
  static ParsedBook parse(File file) {
    final bytes = file.readAsBytesSync();
    var html = CharsetDecoder.decode(bytes);
    // 替换符 ≥2 且声明编码重解后替换符严格减少才采纳重解结果：
    // 单个坏字节的真 UTF-8 页若恰好误标 gbk，无条件重解会把好文本
    // 整篇搞坏（GBK 解码几乎不产生替换符，无法从结果分辨对错）。
    // 旧条件「连续两个 FFFD」过严：单个中文双字节损坏只产生一个替换符
    // 会错过重解；放宽为计数阈值并加结果校验，两头都堵住。
    var fffdCount = 0;
    for (final r in html.runes) {
      if (r == 0xFFFD) fffdCount++;
    }
    if (fffdCount >= 2) {
      final retry = _decodeWithDeclaredCharset(bytes);
      var retryFffd = 0;
      if (retry != null) {
        for (final r in retry.runes) {
          if (r == 0xFFFD) retryFffd++;
        }
        if (retryFffd < fffdCount) html = retry;
      }
    }
    final text = TextUtils.stripHtml(html);
    if (text.trim().isEmpty) throw const FormatException('HTML 没有可读的正文');

    // 尝试 <title> 作为书名
    final m = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true, caseSensitive: false)
        .firstMatch(html);
    final title = m == null
        ? file.uri.pathSegments.last
        : TextUtils.decodeEntities(m.group(1)!).trim();

    // 复用 TXT 的章节切分
    final chapters = _splitByChapterLines(title, text);
    return ParsedBook(chapters);
  }

  static String? _decodeWithDeclaredCharset(List<int> bytes) {
    final headLen = bytes.length > 2048 ? 2048 : bytes.length;
    final head = CharsetDecoder.decode(bytes.sublist(0, headLen));
    final m = RegExp(
            r'''charset\s*=\s*["']?([\w-]+)''',
            caseSensitive: false)
        .firstMatch(head);
    final cs = m?.group(1)?.toLowerCase() ?? '';
    if (cs.contains('gb')) {
      return CharsetDecoder.decodeGbk(bytes);
    }
    return null;
  }

  /// HTML 章节切分：逻辑统一在 ChapterSplitter（三格式共用）。
  static final RegExp _chapterMark =
      RegExp(r'^第\s*[0-9〇零一二两三四五六七八九十百千万]+\s*[章节回卷部篇]');

  static List<ParsedChapter> _splitByChapterLines(String title, String text) {
    final parts = ChapterSplitter.split(
      text: text,
      bookTitle: title,
      titlePatterns: [_chapterMark],
      // 与 TXT/MOBI 主路径一致：开目录守卫与目录块折叠
      excludeTocLines: true,
      collapseTocRuns: true,
    );
    if (parts.isEmpty) {
      return [ParsedChapter(title.isEmpty ? '正文' : title, text)];
    }
    return parts.map((p) => ParsedChapter(p.title, p.body)).toList();
  }
}
