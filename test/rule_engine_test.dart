import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/source/book_source.dart';
import 'package:moyue/source/rule_engine.dart';

void main() {
  final doc = RuleEngine.parseHtml('''
    <html><body>
      <div id="main">
        <div class="item"><h4><a href="/book/1">斗破苍穹</a><span>作者：天蚕土豆</span></h4><p class="intro">这是简介</p></div>
        <div class="item"><h4><a href="/book/2">凡人修仙传</a><span>作者：忘语</span></h4><p class="intro">这是简介2</p></div>
      </div>
      <div id="content">第一段<br>第二段<p>第三段</p><script>bad()</script></div>
    </body></html>
  ''');
  final root = doc.documentElement!;

  group('CSS 规则', () {
    test('提取文本（多元素换行连接）', () {
      expect(RuleEngine.evalString('@css:#main a@text', root: root),
          '斗破苍穹\n凡人修仙传');
    });

    test('提取属性并以基准地址解析相对路径', () {
      expect(
          RuleEngine.evalString('@css:#main a@href',
              root: root, baseUrl: 'http://x.com/list/'),
          'http://x.com/book/1');
    });

    test('data-src 等未收录属性按属性名兜底', () {
      final d = RuleEngine.parseHtml('<img data-src="/c/1.jpg">');
      expect(
          RuleEngine.evalString('@css:img@data-src',
              root: d.documentElement!, baseUrl: 'http://x.com/a/'),
          'http://x.com/c/1.jpg');
    });

    test('text 提取保留换行（br 与块级边界），跳过 script', () {
      expect(RuleEngine.evalString('@css:#content@text', root: root),
          '第一段\n第二段\n第三段');
    });
  });

  group('JSON 规则', () {
    final json = {
      'data': {
        'list': [
          {'name': '书名一', 'url': '/j/1'},
          {'name': '书名二', 'url': '/j/2'},
        ]
      }
    };

    test('路径取值', () {
      expect(RuleEngine.evalString('@json:\$.data.list[0].name', json: json),
          '书名一');
    });

    test('[*] 展开列表', () {
      final nodes =
          RuleEngine.evalList('@json:\$.data.list[*]', json: json);
      expect(nodes.length, 2);
      expect(RuleEngine.evalString('name', json: nodes[1].json), '书名二');
    });

    test('负下标', () {
      expect(RuleEngine.evalString('@json:\$.data.list[-1].name', json: json),
          '书名二');
    });
  });

  group('默认链式规则', () {
    test('class 定位列表', () {
      final items = RuleEngine.evalList('class.item', root: root);
      expect(items.length, 2);
    });

    test('链式下钻 + 属性提取 + 相对路径解析', () {
      final item = RuleEngine.evalList('class.item', root: root).first;
      expect(
          RuleEngine.evalString('tag.a@href', root: item.element,
              baseUrl: 'http://x.com/'),
          'http://x.com/book/1');
      expect(
          RuleEngine.evalString('class.intro@text', root: item.element),
          '这是简介');
    });

    test('下标定位（0 与 -1）', () {
      expect(
          RuleEngine.evalString('tag.a.0@href', root: root,
              baseUrl: 'http://x.com/'),
          'http://x.com/book/1');
      expect(
          RuleEngine.evalString('tag.a.-1@href', root: root,
              baseUrl: 'http://x.com/'),
          'http://x.com/book/2');
    });

    test('text.X 按包含文本定位', () {
      expect(
          RuleEngine.evalString('text.凡人@text', root: root),
          contains('凡人修仙传'));
    });
  });

  group('规则组合', () {
    test('|| 兜底', () {
      expect(
          RuleEngine.evalString('@css:.nope@text||@css:#main a@text',
              root: root),
          '斗破苍穹\n凡人修仙传');
    });

    test('## 后处理删除与替换', () {
      expect(RuleEngine.applyReplaceRegex('正文广告\n内容', '##广告##'), '正文\n内容');
      expect(
          RuleEngine.applyReplaceRegex('第1章', r'##第(\d+)章##第$1回'), '第1回');
    });

    test('净化作用于规则结果', () {
      final d = RuleEngine.parseHtml('<p>标题（广告）</p>');
      expect(
          RuleEngine.evalString('@css:p@text##（广告）##',
              root: d.documentElement!),
          '标题');
    });
  });

  group('不支持的情况', () {
    test('纯 JS 规则抛 SourceUnsupportedException', () {
      expect(
          () => RuleEngine.evalString('@js:1+1', root: root),
          throwsA(isA<SourceUnsupportedException>()));
    });

    test('JS 分支被 || 兜底跳过', () {
      expect(
          RuleEngine.evalString('@js:1+1||@css:#main a@text', root: root),
          '斗破苍穹\n凡人修仙传');
    });
  });
}
