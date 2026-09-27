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
  /// 把段落切成 ≤ [_maxSegmentLength] 的排版块；在标点处优先断开，
  /// 返回段落内 [start, end) 区间列表。短段落原样返回单块。
  static const int _maxSegmentLength = 8000;

  static List<(int, int)> _segments(String text) {
    if (text.length <= _maxSegmentLength) return [(0, text.length)];
    final segs = <(int, int)>[];
    final punctuation = RegExp(r'[。！？!?；;…」』”’），,)]');
    int start = 0;
    while (text.length - start > _maxSegmentLength) {
      // 在 [start+3/4上限, start+上限] 窗口内找最后一个标点
      final windowStart = start + _maxSegmentLength * 3 ~/ 4;
      final windowEnd = math.min(text.length, start + _maxSegmentLength + 1);
      int cut = -1;
      for (int i = windowEnd - 1; i >= windowStart; i--) {
        if (punctuation.hasMatch(text[i])) {
          cut = i + 1;
          break;
        }
      }
      if (cut <= start) cut = start + _maxSegmentLength; // 找不到标点则硬切
      segs.add((start, cut));
      start = cut;
    }
    if (start < text.length) segs.add((start, text.length));
    return segs;
  }

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
      // 超长段落按标点分块排版：单个数万字段落一次 layout 可耗时上秒，
      // 分块后每块独立测量；块边界强制换行，字符偏移仍然精确。
      for (final seg in _segments(text)) {
        final sub = text.substring(seg.$1, seg.$2);
        tp.text = TextSpan(text: sub, style: style);
        tp.layout(maxWidth: viewportWidth);
        // 用 getLineBoundary 逐行推进，精确得到每个视觉行的字符区间
        int prevStart = 0;
        while (true) {
          final boundary = tp.getLineBoundary(TextPosition(offset: prevStart));
          int end = boundary.end;
          if (end <= prevStart) end = sub.length; // 兜底：防死循环
          if (end > sub.length) end = sub.length;
          lines.add(LineInfo(p, seg.$1 + prevStart, seg.$1 + end));
          if (end >= sub.length) break;
          prevStart = end;
        }
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
