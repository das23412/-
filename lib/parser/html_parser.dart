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
    // 若 <meta charset="gbk"> 等声明与 UTF-8 解码结果冲突，简单启发：出现大量替换符则按 GBK 重解
    if (html.contains('\uFFFD\uFFFD')) {
      final retry = _decodeWithDeclaredCharset(bytes);
      if (retry != null) html = retry;
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
    );
    if (parts.isEmpty) {
      return [ParsedChapter(title.isEmpty ? '正文' : title, text)];
    }
    return parts.map((p) => ParsedChapter(p.title, p.body)).toList();
  }
}
