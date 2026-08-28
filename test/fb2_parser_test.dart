import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/parser/fb2_parser.dart';

const sample = '''<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
  <description>
    <title-info>
      <book-title>测试小说</book-title>
      <author><first-name>某</first-name><last-name>作者</last-name></author>
    </title-info>
  </description>
  <body>
    <section>
      <title><p>第一章 启程</p></title>
      <p>清晨的雾气还没有散去。</p>
      <p>他背起行囊出发了。</p>
    </section>
    <section>
      <title><p>第二章 抵达</p></title>
      <p>傍晚时分到达了小镇。</p>
    </section>
  </body>
  <body name="notes">
    <section><title><p>注释</p></title><p>这条不应出现在正文</p></section>
  </body>
</FictionBook>''';

void main() {
  late File file;
  setUp(() {
    file = File(
        '${Directory.systemTemp.path}/moyue_test_${DateTime.now().millisecondsSinceEpoch}.fb2');
    file.writeAsBytesSync(utf8.encode(sample));
  });
  tearDown(() {
    if (file.existsSync()) file.deleteSync();
  });

  test('FB2 解析章节', () {
    final book = Fb2Parser.parse(file);
    expect(book.chapters.length, 2);
    expect(book.chapters[0].title, '第一章 启程');
    expect(book.chapters[0].text, contains('清晨的雾气'));
    expect(book.chapters[0].text, contains('他背起行囊出发了'));
    expect(book.chapters[1].title, '第二章 抵达');
  });

  test('跳过 notes body', () {
    final book = Fb2Parser.parse(file);
    for (final c in book.chapters) {
      expect(c.text, isNot(contains('不应出现在正文')));
    }
  });
}
