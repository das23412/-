import 'dart:convert';

import '../data/db.dart';

/// 空值转空字符串的通用工具（库内共用）。
String _s(Object? v) => v == null ? '' : v.toString().trim();

/// 书源各环节规则集（Legado「阅读」3.0 书源 JSON 的常用子集）。
class SearchRules {
  final String bookList;
  final String name;
  final String author;
  final String bookUrl;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;

  const SearchRules({
    this.bookList = '',
    this.name = '',
    this.author = '',
    this.bookUrl = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
  });

  static SearchRules fromJson(Map<String, dynamic> j) => SearchRules(
        bookList: _s(j['bookList']),
        name: _s(j['name']),
        author: _s(j['author']),
        bookUrl: _s(j['bookUrl']),
        coverUrl: _s(j['coverUrl']),
        intro: _s(j['intro']),
        kind: _s(j['kind']),
        lastChapter: _s(j['lastChapter']),
      );
}

class BookInfoRules {
  final String name;
  final String author;
  final String intro;
  final String coverUrl;
  final String tocUrl; // 目录页 URL（默认用书籍详情页）
  final String lastChapter;

  const BookInfoRules({
    this.name = '',
    this.author = '',
    this.intro = '',
    this.coverUrl = '',
    this.tocUrl = '',
    this.lastChapter = '',
  });

  static BookInfoRules fromJson(Map<String, dynamic> j) => BookInfoRules(
        name: _s(j['name']),
        author: _s(j['author']),
        intro: _s(j['intro']),
        coverUrl: _s(j['coverUrl']),
        tocUrl: _s(j['tocUrl']),
        lastChapter: _s(j['lastChapter']),
      );
}

class TocRules {
  final String chapterList;
  final String chapterName;
  final String chapterUrl;
  final String nextTocUrl; // 目录分页（可空）

  const TocRules({
    this.chapterList = '',
    this.chapterName = '',
    this.chapterUrl = '',
    this.nextTocUrl = '',
  });

  static TocRules fromJson(Map<String, dynamic> j) => TocRules(
        chapterList: _s(j['chapterList']),
        chapterName: _s(j['chapterName']),
        chapterUrl: _s(j['chapterUrl']),
        nextTocUrl: _s(j['nextTocUrl']),
      );
}

class ContentRules {
  final String content;
  final String nextContentUrl; // 正文分页（可空）
  final String replaceRegex; // 正文净化（##正则##替换）

  const ContentRules({
    this.content = '',
    this.nextContentUrl = '',
    this.replaceRegex = '',
  });

  static ContentRules fromJson(Map<String, dynamic> j) => ContentRules(
        content: _s(j['content']),
        nextContentUrl: _s(j['nextContentUrl']),
        replaceRegex: _s(j['replaceRegex']),
      );
}

/// 单个书源。原始 JSON 无损保存（入库时存 raw），运行时按需取字段。
class BookSource {
  /// 唯一标识：Legado 用 bookSourceUrl。
  final String id;
  final String name;
  final String group;
  final String searchUrl;
  final SearchRules searchRules;
  final BookInfoRules bookInfoRules;
  final TocRules tocRules;
  final ContentRules contentRules;
  final Map<String, String> headers;
  final String rawJson;
  bool enabled;

  BookSource({
    required this.id,
    required this.name,
    this.group = '',
    required this.searchUrl,
    required this.searchRules,
    required this.bookInfoRules,
    required this.tocRules,
    required this.contentRules,
    this.headers = const {},
    this.rawJson = '',
    this.enabled = true,
  });

  /// 从 Legado 书源 JSON 解析。缺少 id 或 searchUrl 的源返回 null（无法搜索）。
  static BookSource? fromLegadoJson(Map<String, dynamic> j) {
    final id = _s(j['bookSourceUrl']);
    if (id.isEmpty) return null;
    final searchUrl = _s(j['searchUrl']);
    if (searchUrl.isEmpty) return null;
    final ruleSearch = _map(j['ruleSearch']);
    final ruleBookInfo = _map(j['ruleBookInfo']);
    final ruleToc = _map(j['ruleToc']);
    final ruleContent = _map(j['ruleContent']);
    return BookSource(
      id: id,
      name: _s(j['bookSourceName']).isEmpty ? id : _s(j['bookSourceName']),
      group: _s(j['bookSourceGroup']),
      searchUrl: searchUrl,
      searchRules: SearchRules.fromJson(ruleSearch),
      bookInfoRules: BookInfoRules.fromJson(ruleBookInfo),
      tocRules: TocRules.fromJson(ruleToc),
      contentRules: ContentRules.fromJson(ruleContent),
      headers: _parseHeader(_s(j['header'])),
      rawJson: jsonEncode(j),
    );
  }

  static Map<String, dynamic> _map(Object? v) =>
      v is Map<String, dynamic> ? v : const {};

  /// 按库中保存的原始 JSON 找回书源；不存在或损坏返回 null。
  static Future<BookSource?> findById(String id) async {
    final row = await AppDb.instance.sourceRowById(id);
    if (row == null) return null;
    try {
      final decoded = jsonDecode(row['raw'] as String? ?? '');
      if (decoded is Map<String, dynamic>) return fromLegadoJson(decoded);
    } catch (_) {}
    return null;
  }

  /// Legado 的 header 字段是 JSON 字符串，如 '{"User-Agent":"xxx"}'。
  static Map<String, String> _parseHeader(String header) {
    if (header.isEmpty) return const {};
    try {
      final decoded = jsonDecode(header);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return const {};
  }

  /// 从一段导入文本解析书源列表。
  /// 支持：JSON 数组、单个 JSON 对象、以及逐行一个 JSON 对象的合并导出。
  /// 返回解析成功的源；[errors] 记录无法解析的条数。
  static List<BookSource> parseMany(String text, {List<String>? errors}) {
    final result = <BookSource>[];
    var cleaned = text.trim();
    if (cleaned.startsWith('\uFEFF')) cleaned = cleaned.substring(1);
    if (cleaned.isEmpty) return result;

    void tryAdd(Map<String, dynamic> j) {
      final s = fromLegadoJson(j);
      if (s != null) {
        result.add(s);
      } else {
        errors?.add(_s(j['bookSourceName'] ?? '未命名书源'));
      }
    }

    if (cleaned.startsWith('[')) {
      try {
        final decoded = jsonDecode(cleaned);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) tryAdd(item);
          }
          return result;
        }
      } catch (_) {}
    }
    if (cleaned.startsWith('{')) {
      try {
        final decoded = jsonDecode(cleaned);
        if (decoded is Map<String, dynamic>) {
          tryAdd(decoded);
          return result;
        }
      } catch (_) {}
    }
    // 逐行解析（多个对象直接拼接的导出格式）
    for (final line in cleaned.split('\n')) {
      final l = line.trim();
      if (!l.startsWith('{')) continue;
      try {
        final decoded = jsonDecode(l);
        if (decoded is Map<String, dynamic>) tryAdd(decoded);
      } catch (_) {}
    }
    return result;
  }
}

/// 书源规则不被支持时的异常（如需要执行 JS）。
class SourceUnsupportedException implements Exception {
  final String message;
  const SourceUnsupportedException(this.message);
  @override
  String toString() => message;
}
