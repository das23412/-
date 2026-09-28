import 'dart:math' as math;

/// 统一的章节切分引擎：TXT / MOBI / HTML 三种解析器共用同一套
/// 标题识别、目录块折叠、开篇保留与体量分块逻辑，
/// 避免三份实现规则漂移（历史 bug 温床）。
class ChapterSplitter {
  /// 按标题模式切分 [text]。
  ///
  /// - [titlePatterns]：任一模式命中的短行视为章节标题；
  /// - [collapseTocRuns]：连续 3 个及以上、彼此间隔 ≤2 行的标题块
  ///   （书前目录页特征）只保留第一个标记；
  /// - [chunkFallback]：几乎检测不到标记时按 [chunkSize] 字切块，
  ///   章节名为"第N部分"（TXT 散文体）；false 时返回空列表，由调用方兜底。
  ///
  /// 返回 (title, body) 记录列表；开篇内容标题为"开篇"。
  static List<({String title, String body})> split({
    required String text,
    required String bookTitle,
    required List<RegExp> titlePatterns,
    bool collapseTocRuns = false,
    bool chunkFallback = false,
    String bookTitleFallback = '正文',
    int chunkSize = 6000,
  }) {
    final lines = text.split('\n');
    final marks = <int>[];
    for (int i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty || t.length > 50) continue;
      if (titlePatterns.any((p) => p.hasMatch(t))) marks.add(i);
    }

    if (collapseTocRuns) {
      // 目录块折叠：连续 ≥3 个、彼此间隔 ≤2 行的标记只保留第一个
      final collapsed = <int>[];
      int prev = -10;
      int runLen = 0;
      for (final m in marks) {
        if (m - prev > 2) {
          if (runLen >= 3) {
            collapsed.removeRange(
                collapsed.length - (runLen - 1), collapsed.length);
          }
          runLen = 1;
        } else {
          runLen++;
        }
        collapsed.add(m);
        prev = m;
      }
      if (runLen >= 3) {
        collapsed.removeRange(collapsed.length - (runLen - 1), collapsed.length);
      }
      marks
        ..clear()
        ..addAll(collapsed);
    }

    final result = <({String title, String body})>[];
    if (marks.length < 2) {
      if (chunkFallback) return _chunkBySize(bookTitle, bookTitleFallback, text, chunkSize);
      return result;
    }

    if (marks.first > 0) {
      final head = lines.sublist(0, marks.first).join('\n').trim();
      if (head.isNotEmpty) result.add((title: '开篇', body: head));
    }
    for (int m = 0; m < marks.length; m++) {
      final start = marks[m];
      final end = m + 1 < marks.length ? marks[m + 1] : lines.length;
      final body = lines.sublist(start + 1, end).join('\n').trim();
      result.add((title: lines[start].trim(), body: body));
    }
    return result;
  }

  /// 无标记文本按体量切块；短文本整体作为一章（用书名作章名）。
  static List<({String title, String body})> _chunkBySize(
      String bookTitle, String fallbackTitle, String text, int size) {
    if (text.length <= size) {
      return [(title: bookTitle.isEmpty ? fallbackTitle : bookTitle, body: text)];
    }
    final chapters = <({String title, String body})>[];
    final buf = StringBuffer();
    int count = 0;
    int idx = 1;
    for (final paragraph in text.split('\n')) {
      buf.writeln(paragraph);
      count += paragraph.length;
      if (count >= size) {
        chapters.add((title: '第$idx部分', body: buf.toString().trim()));
        idx++;
        buf.clear();
        count = 0;
      }
    }
    final rest = buf.toString().trim();
    if (rest.isNotEmpty) chapters.add((title: '第$idx部分', body: rest));
    return chapters;
  }
}
