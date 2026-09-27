import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/source/book_source.dart';
import 'package:moyue/source/source_service.dart';

/// 构造一个用 CSS 规则的测试书源。
BookSource cssSource() => BookSource(
      id: 'https://test.com',
      name: '测试书源',
      searchUrl: 'https://test.com/search?q={{key}}&p={{page}}',
      searchRules: const SearchRules(
        bookList: '@css:div.result',
        name: '@css:h3 a@text',
        author: '@css:span.author@text',
        bookUrl: '@css:h3 a@href',
        intro: '@css:p.intro@text',
      ),
      bookInfoRules: const BookInfoRules(
        intro: '@css:#intro@text',
        tocUrl: '@css:a.read-now@href',
      ),
      tocRules: const TocRules(
        chapterList: '@css:ul#toc li a',
        chapterName: 'text',
        chapterUrl: 'href',
        nextTocUrl: '@css:a.next@href',
      ),
      contentRules: const ContentRules(
        content: '@css:#nr@text',
        replaceRegex: '##（广告）##',
      ),
    );

const searchPageHtml = '''
<html><body>
  <div class="result"><h3><a href="/book/11">斗破苍穹</a></h3>
    <span class="author">天蚕土豆</span><p class="intro">天才少年。</p></div>
  <div class="result"><h3><a href="/book/22">凡人修仙传</a></h3>
    <span class="author">忘语</span><p class="intro">凡人流开山作。</p></div>
</body></html>
''';

const tocPageHtml = '''
<html><body>
  <ul id="toc">
    <li><a href="/c/1.html">第一章 起点</a></li>
    <li><a href="/c/2.html">第二章 风波</a></li>
  </ul>
  <a class="next" href="/toc_2.html">下一页</a>
</body></html>
''';

const contentPageHtml = '''
<html><body><div id="nr">萧炎抬头。（广告）<br>望向远方。</div></body></html>
''';

void main() {
  group('搜索解析', () {
    test('提取书名/作者/相对地址解析', () {
      final books = SourceService.parseSearch(
          cssSource(), searchPageHtml, 'https://test.com/search?q=x');
      expect(books.length, 2);
      expect(books[0].name, '斗破苍穹');
      expect(books[0].author, '天蚕土豆');
      expect(books[0].bookUrl, 'https://test.com/book/11');
      expect(books[1].name, '凡人修仙传');
    });
  });

  group('目录解析', () {
    test('章节列表 + 相对地址 + 下一页目录', () {
      final (chapters, next) = SourceService.parseTocPage(
          cssSource(), tocPageHtml, 'https://test.com/book/11');
      expect(chapters.length, 2);
      expect(chapters[0].title, '第一章 起点');
      expect(chapters[0].url, 'https://test.com/c/1.html');
      expect(next, 'https://test.com/toc_2.html');
    });

    test('无下一页规则时 next 为空', () {
      final s = BookSource(
        id: 'https://t2.com',
        name: '无分页源',
        searchUrl: 'https://t2.com/s',
        searchRules: const SearchRules(bookList: 'a', name: 'b', bookUrl: 'c'),
        bookInfoRules: const BookInfoRules(),
        tocRules: const TocRules(
            chapterList: '@css:ul#toc li a', chapterName: 'text', chapterUrl: 'href'),
        contentRules: const ContentRules(content: '@css:#nr@text'),
      );
      final (chapters, next) =
          SourceService.parseTocPage(s, tocPageHtml, 'https://t2.com/b');
      expect(chapters.length, 2);
      expect(next, '');
    });
  });

  group('正文解析', () {
    test('正文提取 + replaceRegex 净化', () {
      final (text, next) = SourceService.parseContentPage(
          cssSource(), contentPageHtml, 'https://test.com/c/1.html');
      expect(text, contains('萧炎抬头。'));
      expect(text, contains('望向远方。'));
      expect(text, isNot(contains('（广告）')));
      expect(next, '');
    });

    test('JS 规则的书源抛不支持异常', () {
      final s = BookSource(
        id: 'https://t3.com',
        name: 'JS 源',
        searchUrl: 'https://t3.com/s',
        searchRules: const SearchRules(bookList: 'a', name: 'b', bookUrl: 'c'),
        bookInfoRules: const BookInfoRules(),
        tocRules: const TocRules(
            chapterList: '@css:li', chapterName: 'text', chapterUrl: 'href'),
        contentRules: const ContentRules(content: '<js>1</js>'),
      );
      expect(
        () => SourceService.parseContentPage(s, contentPageHtml, 'https://t3.com/c'),
        throwsA(isA<SourceUnsupportedException>()),
      );
    });
  });

  group('JSON 页面解析', () {
    test('json 数据源走 @json: 规则', () {
      final s = BookSource(
        id: 'https://api.com',
        name: 'API 源',
        searchUrl: 'https://api.com/search?q={{key}}',
        searchRules: const SearchRules(
          bookList: '@json:\$.data[*]',
          name: '@json:\$.title',
          bookUrl: '@json:\$.url',
          author: '@json:\$.author',
        ),
        bookInfoRules: const BookInfoRules(),
        tocRules: const TocRules(),
        contentRules: const ContentRules(),
      );
      const body =
          '{"data":[{"title":"在线书","url":"/api/b/1","author":"某人"}]}';
      final books = SourceService.parseSearch(s, body, 'https://api.com/search');
      expect(books.length, 1);
      expect(books[0].name, '在线书');
      expect(books[0].author, '某人');
      expect(books[0].bookUrl, 'https://api.com/api/b/1');
    });
  });
}
