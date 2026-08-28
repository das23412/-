import 'dart:io';

import '../core/charset.dart';
import '../core/text_utils.dart';
import 'parser.dart';

/// TXT 文件解析：编码识别 + 章节切分。
class TxtParser {
  /// 常见中文小说章节标题模式。
  static final List<RegExp> chapterPatterns = [
    // 第X章 / 第X节 / 第X卷 / 第X回（X 为数字或中文数字）
    RegExp(r'^\s*第\s*[0-9〇零一二两三四五六七八九十百千万]+\s*[章节回卷部篇]\s*.{0,40}$'),
    // Chapter 12 / CHAPTER XII
    RegExp(r'^\s*chapter\s+[0-9ivxIVX]+\b.{0,40}$', caseSensitive: false),
    // 12.、1234、纯数字行 + 短标题（如 "12 标题"）
    RegExp(r'^\s*[0-9]{1,4}\s*[、.．:：]?\s*[^0-9、.．:：\s].{0,30}$'),
    // 【第X章】 / （第X章）
    RegExp(r'^\s*[\[【（(]\s*第\s*[0-9〇零一二两三四五六七八九十百千万]+\s*[章节回卷]\s*[^)\]】）]*[\])】）]\s*.{0,30}$'),
    // 序章 / 楔子 / 尾声 / 番外
    RegExp(r'^\s*(序章|序言|前言|楔子|引子|尾声|后记|终章|番外)\s*.{0,30}$'),
  ];

  /// 判断一行是否像章节标题。
  static bool looksLikeChapterTitle(String line) {
    final t = line.trim();
    if (t.isEmpty || t.length > 50) return false;
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

  /// 将整本文字切分为章节。
  ///
  /// 若几乎检测不到章节（如纯文本散文），则按固定字数切成大块，避免单章过长。
  static List<ParsedChapter> splitChapters(String bookTitle, String text) {
    final lines = text.split('\n');
    final marks = <int>[]; // 章节起始行号
    int consecutive = 0;
    for (int i = 0; i < lines.length; i++) {
      if (looksLikeChapterTitle(lines[i])) {
        marks.add(i);
        consecutive++;
        // 跳过紧随其后的空行不会误判；连续命中也允许（有的书每章占两行标题）
        if (consecutive > lines.length ~/ 2) break; // 全书都是短行，误判，放弃
      } else {
        consecutive = 0;
      }
    }
    // 命中率过低时认为没有章节
    if (marks.length < 2 ||
        marks.length * 6 < lines.where((l) => l.trim().isNotEmpty).length) {
      if (marks.length < 2) {
        return _chunkBySize(bookTitle, text);
      }
    }
    final chapters = <ParsedChapter>[];
    // 第一章之前的文字（若有）作为“开篇”
    if (marks.first > 0) {
      final head = lines.sublist(0, marks.first).join('\n').trim();
      if (head.isNotEmpty) chapters.add(ParsedChapter('开篇', head));
    }
    for (int m = 0; m < marks.length; m++) {
      final start = marks[m];
      final end = m + 1 < marks.length ? marks[m + 1] : lines.length;
      final title = lines[start].trim();
      final bodyLines = lines.sublist(start + 1, end);
      final body = bodyLines.join('\n').trim();
      chapters.add(ParsedChapter(title, body));
    }
    if (chapters.isEmpty) return _chunkBySize(bookTitle, text);
    return chapters;
  }

  /// 无章节时按约 6000 字切块。
  static List<ParsedChapter> _chunkBySize(String bookTitle, String text) {
    const size = 6000;
    if (text.length <= size) {
      return [ParsedChapter(bookTitle.isEmpty ? '正文' : bookTitle, text)];
    }
    final chapters = <ParsedChapter>[];
    final paragraphs = text.split('\n');
    final buf = StringBuffer();
    int count = 0;
    int idx = 1;
    for (final p in paragraphs) {
      buf.writeln(p);
      count += p.length;
      if (count >= size) {
        chapters.add(ParsedChapter('第$idx部分', buf.toString().trim()));
        idx++;
        buf.clear();
        count = 0;
      }
    }
    final rest = buf.toString().trim();
    if (rest.isNotEmpty) {
      chapters.add(ParsedChapter('第$idx部分', rest));
    }
    return chapters;
  }
}
