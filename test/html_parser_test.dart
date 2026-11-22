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

  test('GBK 声明 + 散点替换符：按声明重解并采纳（结果校验回归）', () {
    // 正文 GBK 字节混入大量 ASCII（压低替换率，避免 CharsetDecoder 整本
    // 回退 GBK，从而精确走到 FFFD 重解分支）；'测试好书' 的 GBK 字节
    // 在 lenient UTF-8 下产生 ≥2 个替换符，重解后归零 → 采纳
    final gbk = <int>[
      0xB2, 0xE2, 0xCA, 0xD4, 0xBA, 0xC3, 0xCA, 0xE9, // 测试好书
    ];
    final pad = 'x' * 1000;
    final head = '<html><head><meta charset="gbk"><title>t</title></head>'
        '<body><h1>第一章 开局</h1>';
    final headBytes = utf8.encode(head);
    final padBytes = utf8.encode(pad);
    final file2 = File(
        '${Directory.systemTemp.path}/moyue_test_gbk_${DateTime.now().millisecondsSinceEpoch}.html');
    file2.writeAsBytesSync([...headBytes, ...gbk, ...padBytes]);
    try {
      final book = HtmlParser.parse(file2);
      final text = book.chapters.map((c) => c.text).join('\n');
      expect(text, contains('测试好书'));
      expect(text.contains('\uFFFD'), isFalse);
    } finally {
      if (file2.existsSync()) file2.deleteSync();
    }
  });
}
