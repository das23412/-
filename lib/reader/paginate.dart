import 'dart:math' as math;
import 'package:flutter/painting.dart';

/// 一行文字在章节全文中的定位。
class LineInfo {
  final int paragraph; // 段落号
  final int start; // 段内起始字符（含）
  final int end; // 段内结束字符（不含）
  const LineInfo(this.paragraph, this.start, this.end);
}

/// 一章的分页结果。
class ChapterLayout {
  final List<LineInfo> lines; // 全章行序列
  final List<int> paragraphs; // 每段在章节全文中的起始偏移
  final List<String> paragraphTexts;
  final double lineHeight;
  final int linesPerPage;
  final List<int> pageBreaks; // 每页起始行号（含最后一页结束哨兵）

  ChapterLayout({
    required this.lines,
    required this.paragraphs,
    required this.paragraphTexts,
    required this.lineHeight,
    required this.linesPerPage,
    required this.pageBreaks,
  });

  int get pageCount => pageBreaks.length - 1;

  /// 行号 → 章节全文中的字符偏移。
  int charOffsetOfLine(int lineIdx) {
    if (lineIdx <= 0) return 0;
    if (lineIdx >= lines.length) return _totalChars;
    final l = lines[lineIdx];
    return paragraphs[l.paragraph] + l.start;
  }

  /// 字符偏移 → 行号（用于进度恢复）。
  int lineIndexOfChar(int charOffset) {
    int lo = 0, hi = lines.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (charOffsetOfLine(mid) <= charOffset) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return math.max(0, lo - 1);
  }

  /// 行号 → 页码。
  int pageOfLine(int lineIdx) {
    // pageBreaks 升序，二分
    int lo = 0, hi = pageCount - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (pageBreaks[mid] <= lineIdx) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  int get _totalChars {
    if (paragraphTexts.isEmpty) return 0;
    return paragraphs.last + paragraphTexts.last.length;
  }

  /// 取一页的展示文本（按段落切片重组）。
  String pageText(int page) {
    final startLine = pageBreaks[page];
    final endLine = pageBreaks[page + 1];
    final buf = StringBuffer();
    int i = startLine;
    while (i < endLine && i < lines.length) {
      final p = lines[i].paragraph;
      int j = i;
      while (j < endLine && j < lines.length && lines[j].paragraph == p) {
        j++;
      }
      final slice = paragraphTexts[p]
          .substring(lines[i].start, lines[j - 1].end);
      if (buf.isNotEmpty) buf.write('\n');
      buf.write(slice);
      i = j;
    }
    return buf.toString();
  }
}

/// 分页引擎：把章节文本按样式和视口尺寸切成页。
class Paginator {
  /// 计算一章的布局。
  ///
  /// [indent] 为 true 时每个非空段落首行加两个全角空格（不影响进度偏移的计算）。
  static ChapterLayout layout({
    required String chapterText,
    required TextStyle style,
    required double viewportWidth,
    required double viewportHeight,
    bool indent = true,
  }) {
    final paragraphs = chapterText.split('\n');
    final paragraphTexts = <String>[];
    final paragraphOffsets = <int>[];
    int offset = 0;
    for (final p in paragraphs) {
      paragraphOffsets.add(offset);
      paragraphTexts.add(indent && p.isNotEmpty ? '\u3000\u3000$p' : p);
      offset += p.length + 1; // +1 对应换行符
    }

    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: null,
    );

    final lines = <LineInfo>[];
    double lineHeight = (style.fontSize ?? 16) * (style.height ?? 1.6);
    int linesPerPage = math.max(1, (viewportHeight / lineHeight).floor());

    for (int p = 0; p < paragraphTexts.length; p++) {
      final text = paragraphTexts[p];
      if (text.isEmpty) {
        lines.add(LineInfo(p, 0, 0));
        continue;
      }
      tp.text = TextSpan(text: text, style: style);
      tp.layout(maxWidth: viewportWidth);
      // 用 getLineBoundary 逐行推进，精确得到每个视觉行的字符区间
      int prevStart = 0;
      while (true) {
        final boundary = tp.getLineBoundary(TextPosition(offset: prevStart));
        int end = boundary.end;
        if (end <= prevStart) end = text.length; // 兜底：防死循环
        if (end > text.length) end = text.length;
        lines.add(LineInfo(p, prevStart, end));
        if (end >= text.length) break;
        prevStart = end;
      }
    }
    tp.dispose();

    // 分页
    final pageBreaks = <int>[0];
    for (int i = linesPerPage; i < lines.length; i += linesPerPage) {
      pageBreaks.add(i);
    }
    pageBreaks.add(lines.length);

    return ChapterLayout(
      lines: lines,
      paragraphs: paragraphOffsets,
      paragraphTexts: paragraphTexts,
      lineHeight: lineHeight,
      linesPerPage: linesPerPage,
      pageBreaks: pageBreaks,
    );
  }
}
