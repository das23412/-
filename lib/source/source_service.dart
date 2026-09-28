import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:html/dom.dart';

import 'book_source.dart';
import 'rule_engine.dart';
import 'source_http.dart';

/// 多源搜索结果（单个书源搜到的一本书）。
class SourceBook {
  final String sourceId;
  final String sourceName;
  final String name;
  final String author;
  final String bookUrl;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;

  const SourceBook({
    required this.sourceId,
    required this.sourceName,
    required this.name,
    required this.bookUrl,
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
  });

  /// 用于搜索结果聚合的分组键（同名同作者视为同一本书）。
  String get groupKey => '${name.trim()}|${author.trim()}';
}

/// 在线章节。
class SourceChapter {
  final String title;
  final String url;
  const SourceChapter(this.title, this.url);
}

/// 书籍详情 + 目录入口地址。
class OnlineBookInfo {
  final SourceBook book;
  final String tocUrl;
  const OnlineBookInfo(this.book, this.tocUrl);
}

/// 书源请求描述。
class SourceRequest {
  final String url;
  final String method;
  final String? body;
  final Map<String, String> headers;
  final String? charset;
  const SourceRequest(this.url, this.method, this.body, this.headers, this.charset);
}

/// 书源操作失败（区别于不支持）。
class SourceException implements Exception {
  final String message;
  const SourceException(this.message);
  @override
  String toString() => message;
}

/// 在隔离线程中执行正文抓取+解析+净化。
///
/// 书源自带的 `##正则##` 会在整章正文上运行，嵌套量词类畸形正则会
/// 灾难性回溯——跑在 UI 线程会永久冻结界面（只能杀进程）。
/// 通过 `compute` 调用本函数，冻结被隔离在子线程中。
/// 顶层函数才能被 compute 派发（不能是闭包或实例方法）。
Future<String> loadContentInIsolate(Map<String, String> job) async {
  final raw = job['raw'] ?? '';
  final url = job['url'] ?? '';
  final decoded = jsonDecode(raw);
  final source =
      decoded is Map<String, dynamic> ? BookSource.fromLegadoJson(decoded) : null;
  if (source == null) throw const SourceException('书源数据损坏');
  return await SourceService.loadContent(source, url);
}

/// 书源服务：搜索、详情、目录、正文。
///
/// 解析逻辑（parseSearch/parseToc/parseContent）为纯函数，可离线单测；
/// 网络获取与解析在这里组合。
class SourceService {
  // ---------- 搜索 ----------

  /// 把搜索模板构造成实际请求。模板支持 {{key}} / {{page}} 占位符，
  /// 以及 Legado 的 `url,{...}` 选项段（method/body/headers/charset）。
  static SourceRequest buildSearchRequest(
      BookSource s, String keyword, int page) {
    var tpl = s.searchUrl.trim();
    if (tpl.startsWith('@js:') || tpl.startsWith('<js>')) {
      throw const SourceUnsupportedException('搜索规则需要执行 JS，暂不支持');
    }
    var opts = <String, dynamic>{};
    final idx = tpl.indexOf(',{');
    if (idx >= 0) {
      try {
        final decoded = jsonDecode(tpl.substring(idx + 1));
        if (decoded is Map<String, dynamic>) {
          opts = decoded;
          tpl = tpl.substring(0, idx);
        }
      } catch (_) {}
    }
    final key = Uri.encodeComponent(keyword);
    String fill(String t) =>
        t.replaceAll('{{key}}', key).replaceAll('{{page}}', page.toString());
    final url = _absolute(fill(tpl), s.id);
    final method =
        (opts['method'] == null ? 'GET' : opts['method'].toString()).toUpperCase();
    final body = opts['body'] == null ? null : fill(opts['body'].toString());
    final headers = <String, String>{...s.headers};
    if (opts['headers'] is Map) {
      (opts['headers'] as Map)
          .forEach((k, v) => headers[k.toString()] = v.toString());
    }
    final charset = opts['charset']?.toString();
    return SourceRequest(url, method, body, headers, charset);
  }

  /// 多源搜索：并发执行（默认最多 6 个源同时请求），单源失败/超时被隔离，
  /// 返回成功的结果与失败原因。请求与解析在隔离线程执行
  /// （书源 ##正则## 可能灾难性回溯，不能跑 UI 线程）。
  static Future<(List<SourceBook>, Map<String, String>)> searchAll(
    List<BookSource> sources,
    String keyword, {
    int page = 1,
    Duration timeout = const Duration(seconds: 15),
    int maxConcurrency = 6,
  }) async {
    final results = <SourceBook>[];
    final errors = <String, String>{};
    var index = 0;
    Future<void> worker() async {
      while (index < sources.length) {
        final s = sources[index];
        index++;
        try {
          final books = await search(s, keyword, page: page).timeout(timeout);
          results.addAll(books);
        } on SourceUnsupportedException catch (e) {
          errors[s.id] = e.message;
        } catch (e) {
          errors[s.id] = e.toString();
        }
      }
    }

    final workers = <Future<void>>[];
    for (int i = 0; i < maxConcurrency && i < sources.length; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);
    return (results, errors);
  }

  /// 搜索（隔离线程执行：书源正则可能灾难性回溯，不能冻结 UI）。
  static Future<List<SourceBook>> search(BookSource s, String keyword,
      {int page = 1}) {
    return compute(_searchJob, {
      'raw': s.rawJson,
      'keyword': keyword,
      'page': page,
    }).timeout(const Duration(minutes: 1));
  }

  /// 隔离线程搜索入口（顶层函数，compute 目标）。
  static Future<List<SourceBook>> _searchJob(Map<String, Object?> job) async {
    final raw = job['raw'] as String;
    final decoded = jsonDecode(raw);
    final source =
        decoded is Map<String, dynamic> ? BookSource.fromLegadoJson(decoded) : null;
    if (source == null) throw const SourceException('书源数据损坏');
    return _searchSync(
        source, job['keyword'] as String, page: job['page'] as int);
  }

  /// 同步搜索：构建请求 → 抓取 → 解析（供隔离线程调用）。
  static Future<List<SourceBook>> _searchSync(BookSource s, String keyword,
      {int page = 1}) async {
    final req = buildSearchRequest(s, keyword, page);
    final resp = await SourceHttp.request(
      req.url,
      method: req.method,
      body: req.body,
      headers: req.headers,
      charset: req.charset,
    );
    final books = parseSearch(s, resp.body, resp.finalUrl);
    if (books.isEmpty) {
      throw const SourceException('没有搜索到结果（检查关键词或书源规则）');
    }
    return books;
  }

  /// 解析搜索页（纯函数，可单测）。
  static List<SourceBook> parseSearch(BookSource s, String body, String baseUrl) {
    if (s.searchRules.bookList.isEmpty) {
      throw const SourceException('书源缺少搜索结果列表规则');
    }
    final (rootEl, rootJson) = _rootNode(body);
    final items = RuleEngine.evalList(
      s.searchRules.bookList,
      root: rootEl,
      json: rootJson,
    );
    final books = <SourceBook>[];
    for (final item in items) {
      final name = _evalOn(s.searchRules.name, item, baseUrl);
      final bookUrl = _evalOn(s.searchRules.bookUrl, item, baseUrl);
      if (name == null || name.trim().isEmpty) continue;
      if (bookUrl == null || bookUrl.trim().isEmpty) continue;
      books.add(SourceBook(
        sourceId: s.id,
        sourceName: s.name,
        name: name.trim(),
        bookUrl: _absolute(bookUrl.trim(), baseUrl),
        author: (_evalOn(s.searchRules.author, item, baseUrl) ?? '').trim(),
        coverUrl: _absolute(
            (_evalOn(s.searchRules.coverUrl, item, baseUrl) ?? '').trim(),
            baseUrl),
        intro: (_evalOn(s.searchRules.intro, item, baseUrl) ?? '').trim(),
        kind: (_evalOn(s.searchRules.kind, item, baseUrl) ?? '').trim(),
        lastChapter:
            (_evalOn(s.searchRules.lastChapter, item, baseUrl) ?? '').trim(),
      ));
    }
    return books;
  }

  // ---------- 详情与目录 ----------

  /// 获取详情并返回目录入口。详情规则缺失/失败时直接用搜索结果回填。
  static Future<OnlineBookInfo> bookInfo(BookSource s, SourceBook hint) async {
    var name = hint.name;
    var author = hint.author;
    var intro = hint.intro;
    var coverUrl = hint.coverUrl;
    var tocUrl = hint.bookUrl;
    final r = s.bookInfoRules;
    final hasRules = r.name.isNotEmpty ||
        r.author.isNotEmpty ||
        r.intro.isNotEmpty ||
        r.coverUrl.isNotEmpty ||
        r.tocUrl.isNotEmpty;
    if (hasRules) {
      try {
        final resp = await SourceHttp.request(hint.bookUrl, headers: s.headers);
        final (el, jsonv) = _rootNode(resp.body);
        String? f(String rule) =>
            rule.isEmpty ? null : _evalOn(rule, RuleNode.root(el, jsonv), resp.finalUrl);
        name = f(r.name) ?? name;
        author = f(r.author) ?? author;
        intro = f(r.intro) ?? intro;
        coverUrl = f(r.coverUrl) ?? coverUrl;
        tocUrl = f(r.tocUrl) ?? tocUrl;
      } catch (_) {
        // 详情页失败不致命：继续用搜索结果的信息
      }
    }
    return OnlineBookInfo(
      SourceBook(
        sourceId: s.id,
        sourceName: s.name,
        name: name.trim(),
        bookUrl: hint.bookUrl,
        author: author.trim(),
        coverUrl: coverUrl.trim(),
        intro: intro.trim(),
        kind: hint.kind,
        lastChapter: hint.lastChapter,
      ),
      tocUrl.trim().isEmpty ? hint.bookUrl : _absolute(tocUrl.trim(), hint.bookUrl),
    );
  }

  /// 拉取完整目录（自动翻目录页，最多 50 页防失控）。隔离线程执行。
  static Future<List<SourceChapter>> loadToc(BookSource s, String tocUrl) {
    return compute(_tocJob, {'raw': s.rawJson, 'url': tocUrl})
        .timeout(const Duration(minutes: 2));
  }

  static Future<List<SourceChapter>> _tocJob(Map<String, String> job) async {
    final source = BookSource.fromLegadoJson(jsonDecode(job['raw']!));
    if (source == null) throw const SourceException('书源数据损坏');
    return SourceService.loadTocSync(source, job['url']!);
  }

  static Future<List<SourceChapter>> loadTocSync(BookSource s, String tocUrl) async {
    if (s.tocRules.chapterList.isEmpty) {
      throw const SourceException('书源缺少目录列表规则');
    }
    final result = <SourceChapter>[];
    var url = tocUrl;
    final visited = <String>{};
    var pages = 0;
    while (url.isNotEmpty && visited.add(url) && pages < 50) {
      pages++;
      final resp = await SourceHttp.request(url, headers: s.headers);
      final (chapters, next) = parseTocPage(s, resp.body, resp.finalUrl);
      result.addAll(chapters);
      url = next;
    }
    if (result.isEmpty) {
      throw const SourceException('没有解析到章节目录');
    }
    return result;
  }

  /// 解析一页目录（纯函数，可单测）。返回章节列表与下一页目录地址。
  static (List<SourceChapter>, String) parseTocPage(
      BookSource s, String body, String baseUrl) {
    final (el, jsonv) = _rootNode(body);
    final items = RuleEngine.evalList(
      s.tocRules.chapterList,
      root: el,
      json: jsonv,
    );
    final chapters = <SourceChapter>[];
    for (final item in items) {
      final title = _evalOn(s.tocRules.chapterName, item, baseUrl);
      final chapterUrl = _evalOn(s.tocRules.chapterUrl, item, baseUrl);
      if (title == null || title.trim().isEmpty) continue;
      if (chapterUrl == null || chapterUrl.trim().isEmpty) continue;
      chapters.add(SourceChapter(title.trim(), _absolute(chapterUrl.trim(), baseUrl)));
    }
    var next = '';
    if (s.tocRules.nextTocUrl.isNotEmpty) {
      final raw =
          _evalOn(s.tocRules.nextTocUrl, RuleNode.root(el, jsonv), baseUrl);
      if (raw != null && raw.trim().isNotEmpty) {
        next = _absolute(raw.trim(), baseUrl);
      }
    }
    return (chapters, next);
  }

  // ---------- 正文 ----------

  /// 拉取一章正文（自动拼接正文分页，最多 30 页防失控）。
  static Future<String> loadContent(BookSource s, String chapterUrl) async {
    if (s.contentRules.content.isEmpty) {
      throw const SourceException('书源缺少正文规则');
    }
    final buf = StringBuffer();
    var url = chapterUrl;
    final visited = <String>{};
    var pages = 0;
    while (url.isNotEmpty && visited.add(url) && pages < 30) {
      pages++;
      final resp = await SourceHttp.request(url, headers: s.headers);
      final (text, next) = parseContentPage(s, resp.body, resp.finalUrl);
      if (text.isNotEmpty) buf.writeln(text);
      url = next;
    }
    final content = buf.toString().trim();
    if (content.length > 2000000) {
      throw const SourceException('正文超过 2MB，疑似异常页面');
    }
    if (content.isEmpty) {
      throw const SourceException('正文内容为空');
    }
    return content;
  }

  /// 解析一页正文（纯函数，可单测）。返回正文（已应用书源净化规则）与下一页地址。
  static (String, String) parseContentPage(
      BookSource s, String body, String baseUrl) {
    final (el, jsonv) = _rootNode(body);
    var text =
        _evalOn(s.contentRules.content, RuleNode.root(el, jsonv), baseUrl) ?? '';
    text = text.trim();
    if (s.contentRules.replaceRegex.isNotEmpty) {
      text = RuleEngine.applyReplaceRegex(text, s.contentRules.replaceRegex);
    }
    var next = '';
    if (s.contentRules.nextContentUrl.isNotEmpty) {
      final raw = _evalOn(
          s.contentRules.nextContentUrl, RuleNode.root(el, jsonv), baseUrl);
      if (raw != null && raw.trim().isNotEmpty) {
        next = _absolute(raw.trim(), baseUrl);
      }
    }
    return (text, next);
  }

  // ---------- 工具 ----------

  static (Element?, dynamic) _rootNode(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return (null, jsonDecode(body));
      } catch (_) {}
    }
    return (RuleEngine.parseHtml(body).documentElement, null);
  }

  static String? _evalOn(String rule, RuleNode node, String baseUrl) {
    return RuleEngine.evalString(
      rule,
      root: node.element,
      json: node.json,
      baseUrl: baseUrl,
    );
  }

  static String _absolute(String url, String base) {
    if (url.isEmpty) return url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    try {
      final b = Uri.parse(base);
      if (b.hasScheme) return b.resolve(url).toString();
    } catch (_) {}
    return url;
  }
}
