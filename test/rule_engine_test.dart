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

    test('## 替换串的捕获组组合语法', () {
      // $2/$1 交换分组
      expect(RuleEngine.applyReplaceRegex('ab', r'##(a)(b)##$2$1'), 'ba');
      // ${N} 大括号形式（含两位数组号）
      expect(RuleEngine.applyReplaceRegex('ab', r'##(a)(b)##${2}${1}'), 'ba');
      // $& 整个匹配；$$ 字面量美元符
      expect(RuleEngine.applyReplaceRegex('hello world', r'##world##[$&]'),
          'hello [world]');
      expect(RuleEngine.applyReplaceRegex('a-b', r'##-##$$'), 'a\$b');
      // 越界组号为空串（未匹配的尾部字符保留）
      expect(RuleEngine.applyReplaceRegex('ab', r'##(a)##$9|$1'), '|ab');
    });

    test('|| 与 ## 的优先级：每个分支独立净化（不吞兜底分支）', () {
      final d = RuleEngine.parseHtml(
          '<p id="t">价格：100元</p><p id="t2">备用文本</p>');
      final root = d.documentElement!;
      // 第一个分支带 ## 净化且命中：结果不含第二个分支的规则文本
      expect(
        RuleEngine.evalString(
            '@css:#t@text##：.*##（已改）||@css:#t2@text', root: root),
        '价格（已改）',
      );
      // 第一个分支选择器未命中：落到第二个分支，且第二分支自己的 ## 生效
      expect(
        RuleEngine.evalString(
            '@css:#missing@text||@css:#t2@text##备用##替换', root: root),
        '替换文本',
      );
    });

    test('&& 合并（空部分跳过，换行连接）', () {
      final d = RuleEngine.parseHtml('<p id="a">A文本</p><p id="b">B文本</p>');
      expect(
        RuleEngine.evalString(
            '@css:#a@text&&@css:#b@text', root: d.documentElement!),
        'A文本\nB文本',
      );
    });

    test('&& 中非法选择器视为空，不影响其余部分', () {
      final d = RuleEngine.parseHtml('<p id="b">B文本</p>');
      expect(
        RuleEngine.evalString(
            '@css:##[bad&&@css:#b@text', root: d.documentElement!),
        'B文本',
      );
    });

    test('|| 分支中的非法选择器不中断兜底链', () {
      final d = RuleEngine.parseHtml('<p id="ok">兜底成功</p>');
      expect(
        RuleEngine.evalString(
            '@css:##[nope||@css:#ok@text', root: d.documentElement!),
        '兜底成功',
      );
    });

    test('\$..key 递归下降（前序遍历）', () {
      final json = {
        'title': 'T0',
        'a': {
          'title': 'T1',
          'items': [
            {'title': 'T2'}
          ],
        },
      };
      expect(RuleEngine.evalString('@json:\$..title', json: json), 'T0');
      final nodes = RuleEngine.evalList('@json:\$..title', json: json);
      expect(nodes.map((n) => n.json), ['T0', 'T1', 'T2']);
    });

    test('提取器矩阵与定位链', () {
      final d = RuleEngine.parseHtml(
          '<div id="x"><span>Hi</span><b> yo</b><em>&amp;more</em></div>');
      final root = d.documentElement!;
      // textnodes / ownText：直接文本
      expect(RuleEngine.evalString('@css:#x@textnodes', root: root), 'Hi yo &more');
      // html / all
      expect(RuleEngine.evalString('@css:#x@html', root: root),
          '<span>Hi</span><b> yo</b><em>&amp;more</em>');
      expect(RuleEngine.evalString('@css:#x@all', root: root),
          contains('<div id="x"'));
      // textlen：可见文本长度
      expect(RuleEngine.evalString('@css:#x@textlen', root: root),
          '${'<span>Hi</span><b> yo</b><em>&more</em>'.length}');
      // id.X 链式定位
      expect(
          RuleEngine.evalString('id.x@text', root: root), 'Hi yo &more');
      // Map 上的 [*] 展开
      final json = {'m': {'a': 1, 'b': 2}};
      final nodes = RuleEngine.evalList('@json:\$..[*]', json: json);
      expect(nodes.map((n) => n.json), containsAll([1, 2]));
    });

    test('非法 ## 正则回退为原文本', () {
      expect(RuleEngine.applyReplaceRegex('abc', r'##(unclosed##X'), 'abc');
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
