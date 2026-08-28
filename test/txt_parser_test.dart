import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/core/text_utils.dart';
import 'package:moyue/parser/parser.dart';
import 'package:moyue/parser/txt_parser.dart';

void main() {
  group('章节标题识别', () {
    test('中文数字章节', () {
      expect(TxtParser.looksLikeChapterTitle('第十二章 风起云涌'), isTrue);
      expect(TxtParser.looksLikeChapterTitle('第一百二十三回 大战'), isTrue);
      expect(TxtParser.looksLikeChapterTitle('第1章'), isTrue);
      expect(TxtParser.looksLikeChapterTitle('1234. 标题'), isTrue);
      expect(TxtParser.looksLikeChapterTitle('序章'), isTrue);
      expect(TxtParser.looksLikeChapterTitle('楔子 灭门之夜'), isTrue);
      expect(TxtParser.looksLikeChapterTitle('Chapter 12: The Fall'), isTrue);
    });

    test('正文不误判', () {
      expect(TxtParser.looksLikeChapterTitle('他慢慢地走进了房间，看着窗外的风景。'), isFalse);
      expect(TxtParser.looksLikeChapterTitle('这是一个关于成长的故事，讲了很多年。'), isFalse);
      expect(TxtParser.looksLikeChapterTitle(''), isFalse);
    });
  });

  group('章节切分', () {
    test('常规切分', () {
      final text = [
        '第一卷 少年',
        '第1章 开端',
        '这是第一章的正文。',
        '第二段落。',
        '第2章 相遇',
        '这是第二章的正文。',
      ].join('\n');
      final chapters = TxtParser.splitChapters('书名', text);
      expect(chapters.length, 3);
      expect(chapters[0].title, '第一卷 少年');
      expect(chapters[1].title, '第1章 开端');
      expect(chapters[2].title, '第2章 相遇');
      expect(chapters[1].text, contains('这是第一章的正文'));
      expect(chapters[2].text, contains('这是第二章的正文'));
    });

    test('无章节时按体量分块', () {
      final text = List.generate(3000, (i) => '这是第$i个段落，讲述一些日常琐事与情节发展。').join('\n');
      final chapters = TxtParser.splitChapters('测试书', text);
      expect(chapters.length, greaterThan(1));
      expect(chapters.first.title, contains('部分'));
      // 拼回来应该完整
      final joined = chapters.map((c) => c.text).join('\n');
      expect(joined.length, greaterThan(60000));
    });

    test('开篇内容保留', () {
      final text = '这本书的版权信息与简介。\n\n第1章 开始\n正文。\n第2章 继续\n正文。';
      final chapters = TxtParser.splitChapters('书', text);
      expect(chapters.first.title, '开篇');
      expect(chapters.first.text, contains('版权信息'));
    });
  });

  group('文本工具', () {
    test('cleanTitle 去除书站后缀', () {
      expect(TextUtils.cleanTitle('斗破苍穹(精校版)'), '斗破苍穹');
      expect(TextUtils.cleanTitle('诡秘之主-全本-TXT'), '诡秘之主');
      expect(TextUtils.cleanTitle('凡人修仙传.txt'), '凡人修仙传');
      expect(TextUtils.cleanTitle('我的书名'), '我的书名');
    });

    test('HTML 实体解码', () {
      expect(TextUtils.decodeEntities('A&amp;B &lt;tag&gt; &#x4f60;&#22909;'), 'A&B <tag> 你好');
    });

    test('字数统计', () {
      expect(TextUtils.countChars('你好  世界\n\ntest'), 8);
    });
  });

  test('ParsedChapter 结构', () {
    final c = ParsedChapter('标题', '内容');
    expect(c.title, '标题');
    expect(c.text, '内容');
  });
}
