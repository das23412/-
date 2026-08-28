import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/reader/paginate.dart';

void main() {
  const style = TextStyle(fontSize: 16, height: 1.5, color: Colors.black);
  const viewportWidth = 300.0;
  const viewportHeight = 480.0;

  testWidgets('长章节正确分页', (tester) async {
    final text = List.generate(200, (i) => '这是第$i个段落，包含一些中文内容用来撑起行数。').join('\n');
    final layout = Paginator.layout(
      chapterText: text,
      style: style,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      indent: true,
    );
    expect(layout.pageCount, greaterThan(1));
    expect(layout.linesPerPage, greaterThan(0));
    // 每页文本非空
    for (int i = 0; i < layout.pageCount; i++) {
      expect(layout.pageText(i), isNotEmpty);
    }
  });

  testWidgets('行偏移映射一致', (tester) async {
    final text = '第一段落内容。\n第二段落内容。\n第三段落内容，稍微长一些，用来测试换行行为。';
    final layout = Paginator.layout(
      chapterText: text,
      style: style,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    expect(layout.pageCount, greaterThanOrEqualTo(1));
    // 单行书页时应为 1 页
    expect(layout.pageCount, 1);
    // charOffsetOfLine(0) == 0
    expect(layout.charOffsetOfLine(0), 0);
    // 最后一行映射不越界
    final last = layout.charOffsetOfLine(layout.lines.length - 1);
    expect(last, lessThanOrEqualTo(text.length));
  });

  testWidgets('进度恢复映射', (tester) async {
    final text = List.generate(60, (i) => '段落$i，一些用来填充的内容文字。').join('\n');
    final layout = Paginator.layout(
      chapterText: text,
      style: style,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    // 取中间某行的偏移，应能映射回同一行或附近的行
    final midLine = layout.lines.length ~/ 2;
    final offset = layout.charOffsetOfLine(midLine);
    final restored = layout.lineIndexOfChar(offset);
    expect((restored - midLine).abs(), lessThanOrEqualTo(1));
    // 页码恢复
    final page = layout.pageOfLine(restored);
    expect(page, inInclusiveRange(0, layout.pageCount - 1));
  });

  testWidgets('空章节与短章节', (tester) async {
    final short = Paginator.layout(
      chapterText: '短内容',
      style: style,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    expect(short.pageCount, 1);
    expect(short.pageText(0), contains('短内容'));

    final empty = Paginator.layout(
      chapterText: '',
      style: style,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    expect(empty.pageCount, 1);
  });
}
