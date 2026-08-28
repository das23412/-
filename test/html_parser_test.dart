import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/parser/html_parser.dart';

const sample = '''<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>网页小说示例</title></head>
<body>
<h1>第一章 开局</h1>
<p>夜色如墨，城市灯火阑珊。</p>
<p>他握紧了手中的信封。</p>
<h1>第二章 转折</h1>
<p>第二天清晨，一切都不一样了。</p>
</body>
</html>''';

void main() {
  late File file;
  setUp(() {
    file = File(
        '${Directory.systemTemp.path}/moyue_test_${DateTime.now().millisecondsSinceEpoch}.html');
    file.writeAsBytesSync(utf8.encode(sample));
  });
  tearDown(() {
    if (file.existsSync()) file.deleteSync();
  });

  test('HTML 解析出两章', () {
    final book = HtmlParser.parse(file);
    expect(book.chapters.length, 2);
    expect(book.chapters[0].title, '第一章 开局');
    expect(book.chapters[0].text, contains('夜色如墨'));
    expect(book.chapters[1].title, '第二章 转折');
  });
}
