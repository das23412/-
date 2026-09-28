import 'dart:io';

import '../core/charset.dart';
import '../core/text_utils.dart';
import 'chapter_splitter.dart';
import 'parser.dart';

/// TXT 文件解析：编码识别 + 章节切分。
class TxtParser {
  /// 常见中文小说章节标题模式。
  static final List<RegExp> chapterPatterns = [
    // 第X章 / 第X节 / 第X卷 / 第X回（X 为数字或中文数字）
    RegExp(r'^\s*第\s*[0-9〇零一二两三四五六七八九十百千万]+\s*[章节回卷部篇]\s*.{0,40}$'),
    // Chapter 12 / CHAPTER XII
    RegExp(r'^\s*chapter\s+[0-9ivxIVX]+\b.{0,40}$', caseSensitive: false),
    // 12.、1234.、纯数字行 + 分隔符 + 短标题（必须有分隔符，否则
    // '2023年冬天，雪下得很大。' 这类正文会被误判）
    RegExp(r'^\s*[0-9]{1,4}\s*[、.．:：]\s*[^0-9、.．:：\s].{0,30}$'),
    // 【第X章】 / （第X章）
    RegExp(r'^\s*[\[【（(]\s*第\s*[0-9〇零一二两三四五六七八九十百千万]+\s*[章节回卷]\s*[^)\]】）]*[\])】）]\s*.{0,30}$'),
    // 序章 / 楔子 / 尾声 / 番外
    RegExp(r'^\s*(序章|序言|前言|楔子|引子|尾声|后记|终章|番外)\s*.{0,30}$'),
  ];

  /// 判断一行是否像章节标题。
  static bool looksLikeChapterTitle(String line) {
    final t = line.trim();
    if (t.isEmpty || t.length > 50) return false;
    // 目录页特征：省略号/点导线 + 页码结尾，或多个空格 + 页码结尾
    if (RegExp(r'[.…·•]{2,}\s*[0-9]{1,4}\s*$').hasMatch(t)) return false;
    if (RegExp(r'\s{2,}[0-9]{1,4}\s*$').hasMatch(t)) return false;
    // 排除明显是正文的长句（含句号句尾的概率高）
    for (final p in chapterPatterns) {
      if (p.hasMatch(t)) return true;
    }
    return false;
  }

  static ParsedBook parse(File file) {
    final raw = file.readAsBytesSync();
    var text = CharsetDecoder.decode(raw);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // 去掉 UTF-16 场景可能残留的 BOM 字符
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
    return ParsedBook(splitChapters(TextUtils.cleanTitle(
        file.uri.pathSegments.last), text));
  }

  /// 将整本文字切分为章节（逻辑统一在 ChapterSplitter，三格式共用）。
  static List<ParsedChapter> splitChapters(String bookTitle, String text) {
    final parts = ChapterSplitter.split(
      text: text,
      bookTitle: bookTitle,
      titlePatterns: chapterPatterns,
      collapseTocRuns: true,
      chunkFallback: true,
      bookTitleFallback: '正文',
    );
    return parts.map((p) => ParsedChapter(p.title, p.body)).toList();
  }
}
