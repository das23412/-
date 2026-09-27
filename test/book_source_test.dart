import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/source/book_source.dart';
import 'package:moyue/source/source_service.dart';

void main() {
  group('Legado JSON 解析', () {
    const sourceJson = '''
    [
      {
        "bookSourceUrl": "https://a.com",
        "bookSourceName": "甲站",
        "bookSourceGroup": "测试",
        "searchUrl": "https://a.com/search?q={{key}}&p={{page}}",
        "header": "{\\"User-Agent\\":\\"test-ua\\"}",
        "ruleSearch": {
          "bookList": "@css:div.item",
          "name": "@css:h4 a@text",
          "author": "@css:span@text",
          "bookUrl": "@css:h4 a@href"
        },
        "ruleToc": { "chapterList": "@css:ul li", "chapterName": "text", "chapterUrl": "href" },
        "ruleContent": { "content": "@css:#content@text" }
      },
      { "bookSourceUrl": "https://b.com", "bookSourceName": "乙站", "searchUrl": "https://b.com/s/{{key}}" },
      { "bookSourceName": "缺搜索地址的源" }
    ]
    ''';

    test('数组解析：缺 searchUrl 的源被跳过并计入错误', () {
      final errors = <String>[];
      final sources = BookSource.parseMany(sourceJson, errors: errors);
      expect(sources.length, 2);
      expect(errors.length, 1);
      expect(sources[0].name, '甲站');
      expect(sources[0].headers['User-Agent'], 'test-ua');
      expect(sources[0].searchRules.bookList, '@css:div.item');
      expect(sources[0].tocRules.chapterName, 'text');
    });

    test('逐行 JSON 合并格式', () {
      final text = '{"bookSourceUrl":"https://c.com","bookSourceName":"丙",'
              '"searchUrl":"https://c.com/s/{{key}}"}\n'
          + '{"bookSourceUrl":"https://d.com","bookSourceName":"丁",'
              '"searchUrl":"https://d.com/s/{{key}}"}';
      final sources = BookSource.parseMany(text);
      expect(sources.length, 2);
      expect(sources[1].name, '丁');
    });

    test('空文本返回空列表', () {
      expect(BookSource.parseMany('   '), isEmpty);
    });
  });

  group('搜索请求构建', () {
    BookSource src(String searchUrl) => BookSource(
          id: 'https://x.com',
          name: '测试源',
          searchUrl: searchUrl,
          searchRules: const SearchRules(bookList: 'a', name: 'b', bookUrl: 'c'),
          bookInfoRules: const BookInfoRules(),
          tocRules: const TocRules(),
          contentRules: const ContentRules(),
        );

    test('GET 模板填充 {{key}}/{{page}}，关键词 URL 编码', () {
      final req = SourceService.buildSearchRequest(
          src('https://x.com/search?q={{key}}&p={{page}}'), '斗 破', 3);
      expect(req.url, 'https://x.com/search?q=${Uri.encodeComponent('斗 破')}&p=3');
      expect(req.method, 'GET');
    });

    test('带选项段：POST / body / charset / headers', () {
      final req = SourceService.buildSearchRequest(
        src('https://x.com/s,{"method":"POST","body":"kw={{key}}&p={{page}}","charset":"gbk","headers":{"Referer":"https://x.com/"}}'),
        '剑',
        1,
      );
      expect(req.method, 'POST');
      expect(req.body, 'kw=${Uri.encodeComponent('剑')}&p=1');
      expect(req.charset, 'gbk');
      expect(req.headers['Referer'], 'https://x.com/');
    });

    test('相对地址以书源 id 为基准解析', () {
      final req = SourceService.buildSearchRequest(src('/search?key={{key}}'), 'x', 1);
      expect(req.url, 'https://x.com/search?key=x');
    });

    test('JS 搜索规则抛不支持异常', () {
      expect(
        () => SourceService.buildSearchRequest(src('@js:1'), 'x', 1),
        throwsA(isA<SourceUnsupportedException>()),
      );
    });
  });
}
