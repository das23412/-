import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/painting.dart';

import '../core/book_format.dart';
// book.dart 里也定义了枚举 BookSource（书籍来源），与书源类重名，隐藏之
import '../data/book.dart' hide BookSource;
import '../data/db.dart';
import '../data/settings.dart';
import '../parser/parser.dart';
import '../reader/paginate.dart';
import '../source/book_source.dart';
import '../source/source_service.dart';

/// 章节加载失败时的占位前缀（内存占位，不入缓存；再次进入该章会重试）。
const String _failedPrefix = '[本章加载失败]';

/// 阅读会话状态：负责解析、分页、进度、书签。
class ReaderState extends ChangeNotifier with WidgetsBindingObserver {
  ReaderState(this.book) {
    WidgetsBinding.instance.addObserver(this);
  }

  final Book book;
  final AppDb _db = AppDb.instance;

  List<ParsedChapter> chapters = [];
  List<int> chapterStartChars = [];
  int totalChars = 0;

  /// 解析 isolate 中逐章累加的全书字数（见 ParsedBook.wordCount）。
  int _parsedWordCount = 0;

  int currentChapter = 0;
  int currentPage = 0;

  bool loading = true;
  String? error;

  List<Bookmark> bookmarks = [];

  final Map<int, ChapterLayout> _layouts = {};
  String _layoutKey = '';
  double? _layoutWidth;
  double? _layoutHeight;

  bool get isOnlineBook => book.isOnline;

  /// 当前章正文是否正在联网加载（仅在线书前台加载时为 true）。
  bool chapterLoading = false;

  /// 在线书各章的正文地址（与 chapters 下标对应）。
  List<String> _chapterUrls = [];

  /// 在线书已解析的书源实例（避免每加载一章都查库反序列化）。
  BookSource? _source;

  bool _disposed = false;

  /// 上一次通知是否仅为页码变化（UI 据此跳过菜单关闭时的整页重建）。
  bool lastChangePageOnly = false;

  /// 打开书：解析文件 → 恢复进度 → 载入书签。
  Future<void> load() async {
    loading = true;
    error = null;
    _safeNotify();
    try {
      if (book.isOnline) {
        await _loadOnline();
      } else {
        await _loadLocalFile();
      }
    } catch (e) {
      error = '打开失败：${e.toString()}';
      loading = false;
      _safeNotify();
    }
  }

  Future<void> _loadLocalFile() async {
    final path = book.path;
    if (!File(path).existsSync()) {
      error = '文件不存在，可能已被移动或删除：${book.title}';
      loading = false;
      _safeNotify();
      return;
    }
    ParsedBook parsed;
    try {
      parsed = await compute(
          (String p) => BookParser.parseFile(p, BookFormat.fromPath(p)),
          path);
    } catch (e) {
      throw Exception('解析失败：${e.toString()}');
    }
    chapters = parsed.chapters;
    _parsedWordCount = parsed.wordCount;
    // 过滤空章节
    chapters = chapters.where((c) => c.text.trim().isNotEmpty).toList();
    if (chapters.isEmpty) {
      error = '没有解析到可读的正文内容';
      loading = false;
      _safeNotify();
      return;
    }
    // 章节累计偏移
    chapterStartChars = List<int>.filled(chapters.length, 0);
    int acc = 0;
    for (int i = 0; i < chapters.length; i++) {
      chapterStartChars[i] = acc;
      acc += chapters[i].text.length;
    }
    totalChars = acc;

    currentChapter = book.chapterIndex.clamp(0, chapters.length - 1).toInt();
    currentPage = 0;
    await _refreshMeta();
    bookmarks = await _db.bookmarksOf(book.id!);
    loading = false;
    _safeNotify();
  }

  /// 在线书：目录一次拉取（缓存优先），正文按章加载。
  Future<void> _loadOnline() async {
    if (!AppSettings.instance.allowSources) {
      throw Exception('书源联网未开启：请到 通用设置 → 书源管理 打开开关');
    }
    final source = await BookSource.findById(book.sourceId);
    if (source == null) {
      throw Exception('书源不存在或已损坏：${book.sourceId}');
    }
    _source = source;
    // 目录：优先缓存
    var toc = await _db.loadToc(book.id!);
    if (toc.isEmpty) {
      final info = await SourceService.bookInfo(
          source,
          SourceBook(
            sourceId: book.sourceId,
            sourceName: source.name,
            name: book.title,
            bookUrl: book.bookUrl,
            author: book.author,
          ));
      toc = (await SourceService.loadToc(source, info.tocUrl))
          .map((c) => (title: c.title, url: c.url))
          .toList();
      await _db.saveToc(book.id!, toc);
    }
    _chapterUrls = toc.map((c) => c.url).toList();
    chapters = toc.map((c) => ParsedChapter(c.title, '')).toList();
    chapterStartChars = List<int>.filled(chapters.length, 0);
    totalChars = 0;
    currentChapter = book.chapterIndex.clamp(0, chapters.length - 1).toInt();
    currentPage = 0;
    if (book.chapterCount != chapters.length) {
      book.chapterCount = chapters.length;
      await _db.updateBook(book);
    }
    await _ensureChapterLoaded(currentChapter, foreground: true);
    bookmarks = await _db.bookmarksOf(book.id!);
    loading = false;
    _safeNotify();
  }

  /// 确保某章正文已加载（在线书）：缓存 → 网络。
  /// 失败时写入内存占位文本（不入缓存），下次进入该章自动重试。
  Future<void> _ensureChapterLoaded(int idx, {bool foreground = false}) async {
    if (idx < 0 || idx >= chapters.length) return;
    final cur = chapters[idx].text;
    if (cur.isNotEmpty && !cur.startsWith(_failedPrefix)) return;
    final cached = await _db.loadContent(book.id!, idx, url: _chapterUrls[idx]);
    if (cached != null && cached.isNotEmpty) {
      _applyChapterText(idx, cached);
      return;
    }
    final source = _source;
    if (source == null) {
      _applyChapterText(idx, '$_failedPrefix 书源不存在或已删除');
      return;
    }
    if (foreground) {
      chapterLoading = true;
      _safeNotify();
    }
    try {
      // 正文抓取+解析+净化全部在隔离线程执行：书源畸形正则不再冻结 UI
      // 恶意书源正则可能让 isolate 永久挂起：超时后本章标记失败可重试
      final text = await compute(loadContentInIsolate, {
        'raw': source.rawJson,
        'url': _chapterUrls[idx],
      }).timeout(const Duration(minutes: 1));
      _applyChapterText(idx, text);
      await _db.saveContent(book.id!, idx, text, url: _chapterUrls[idx]);
    } catch (e) {
      _applyChapterText(idx, '$_failedPrefix ${e.toString()}');
    } finally {
      if (foreground) {
        chapterLoading = false;
        _safeNotify();
      }
    }
  }

  /// 预取章节正文（在线书在空闲时调用，用于翻章前预热相邻章节）。
  Future<void> preloadChapter(int idx) async {
    if (idx < 0 || idx >= chapters.length) return;
    if (chapters[idx].text.isNotEmpty) return;
    if (!AppSettings.instance.allowSources) return;
    await _ensureChapterLoaded(idx);
  }

  void _applyChapterText(int idx, String text) {
    chapters[idx] = ParsedChapter(chapters[idx].title, text);
    _recomputeOffsets();
    _layouts.remove(idx); // 该章文本变化，旧布局作废
    _pruneOnlineMemory(idx);
  }

  /// 在线书正文内存上限：只保留当前章 ±20 章的正文，更远的章节
  /// 卸载正文（progress 已存库，再次进入会重新从缓存加载）。
  void _pruneOnlineMemory(int center) {
    if (!book.isOnline) return;
    const keep = 20;
    for (int i = 0; i < chapters.length; i++) {
      if ((i - center).abs() > keep && chapters[i].text.isNotEmpty) {
        chapters[i] = ParsedChapter(chapters[i].title, '');
      }
    }
  }

  void _recomputeOffsets() {
    int acc = 0;
    chapterStartChars = List<int>.filled(chapters.length, 0);
    for (int i = 0; i < chapters.length; i++) {
      chapterStartChars[i] = acc;
      acc += chapters[i].text.length;
    }
    totalChars = acc;
  }

  Future<void> _refreshMeta() async {
    if (book.chapterCount != chapters.length || book.wordCount == 0) {
      book
        ..chapterCount = chapters.length
        ..wordCount = _parsedWordCount;
      await _db.updateBook(book);
    }
  }

  // ---------- 分页 ----------

  /// 配置变化时清空布局缓存。
  void invalidateLayouts(String key) {
    if (_layoutKey != key) {
      _layoutKey = key;
      _layouts.clear();
      _safeNotify();
    }
  }

  /// 章节正文长度（用于在线书窗口键；越界返回 -1）。
  int chapterTextLength(int idx) =>
      idx >= 0 && idx < chapters.length ? chapters[idx].text.length : -1;

  ChapterLayout layoutFor(
    int chapterIdx,
    TextStyle style,
    double width,
    double height,
    bool indent,
  ) {
    // 视口尺寸变化（旋转/分屏/窗口调整）时，旧尺寸排出的版式全部失效，
    // 否则会拿到与当前屏幕不符的分页（文字溢出或留大片空白）。
    if (_layoutWidth != width || _layoutHeight != height) {
      _layoutWidth = width;
      _layoutHeight = height;
      _layouts.clear();
    }
    // 排版缓存容量上限（命中时刷新插入顺序，淘汰近似 LRU）：
    // 读完全书也不至于常驻全部分页结果
    final cached = _layouts[chapterIdx];
    if (cached != null) {
      _layouts.remove(chapterIdx);
      _layouts[chapterIdx] = cached;
      return cached;
    }
    if (_layouts.length >= 12) {
      _layouts.remove(_layouts.keys.first);
    }
    return _layouts.putIfAbsent(
      chapterIdx,
      () => Paginator.layout(
        chapterText: chapters[chapterIdx].text,
        style: style,
        viewportWidth: width,
        viewportHeight: height,
        indent: indent,
      ),
    );
  }

  int pageCountOf(int chapterIdx, ChapterLayout layout) => layout.pageCount;

  // ---------- 进度 ----------

  /// 章内字符偏移（由 UI 在翻页/滚动时同步）。
  int charOffsetInChapter = 0;

  /// 跳转到某章（目录/上一章/下一章）。
  void goToChapter(int idx, {int charOffset = 0}) {
    if (chapters.isEmpty) return;
    currentChapter = idx.clamp(0, chapters.length - 1).toInt();
    currentPage = 0;
    charOffsetInChapter = charOffset;
    if (book.isOnline) {
      // 正文按需加载：加载完成后 notify 界面重排（前台加载显示进度）
      _ensureChapterLoaded(currentChapter, foreground: true);
    }
    _safeNotify();
  }

  double get percent {
    if (book.isOnline) {
      // 在线书未加载的章节没有字数信息，进度按章节计
      if (chapters.isEmpty) return 0;
      return ((currentChapter + 1) / chapters.length * 100).clamp(0.0, 100.0);
    }
    if (totalChars == 0) return 0;
    final done = chapterStartChars[currentChapter] + charOffsetInChapter;
    return (done / totalChars * 100).clamp(0.0, 100.0);
  }

  /// 翻页时调用，更新进度并节流写库。
  void onPageChanged(int chapterIdx, int pageIdx, int charOffset) {
    currentChapter = chapterIdx;
    currentPage = pageIdx;
    charOffsetInChapter = charOffset;
    book
      ..chapterIndex = chapterIdx
      ..charOffset = charOffset
      ..percent = percent
      ..lastReadAt = DateTime.now().millisecondsSinceEpoch
      ..finished = percent >= 99.5;
    _saveDebounced();
    _safeNotify(pageOnly: true);
  }

  Future<void> saveNow() async {
    if (book.id == null) return;
    book.percent = percent;
    await _db.updateBook(book);
  }

  bool _savePending = false;
  void _saveDebounced() {
    if (_savePending) return;
    _savePending = true;
    Future.delayed(const Duration(seconds: 2), () async {
      _savePending = false;
      await saveNow();
    });
  }

  /// 恢复进度：布局完成后由 UI 调一次，返回应显示的页码。
  int restorePage(ChapterLayout layout) {
    if (book.charOffset > 0 &&
        book.chapterIndex == currentChapter &&
        layout.pageCount > 0) {
      final line = layout.lineIndexOfChar(book.charOffset);
      final page = layout.pageOfLine(line);
      currentPage = page.clamp(0, layout.pageCount - 1).toInt();
    }
    return currentPage;
  }

  // ---------- 书签 ----------

  Future<void> addBookmark(String preview) async {
    final ch = chapters[currentChapter];
    final bm = Bookmark(
      bookId: book.id!,
      chapterIndex: currentChapter,
      chapterTitle: ch.title,
      charOffset: charOffsetInChapter,
      preview: preview,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    final id = await _db.insertBookmark(bm);
    if (id > 0) {
      bookmarks = await _db.bookmarksOf(book.id!);
      _safeNotify();
    }
  }

  Future<void> removeBookmark(int id) async {
    await _db.deleteBookmark(id);
    bookmarks = await _db.bookmarksOf(book.id!);
    _safeNotify();
  }

  /// 当前页是否已有书签（按章+偏移近似匹配）。
  bool hasBookmarkAt(int charOffset) {
    const tolerance = 200;
    return bookmarks.any((b) =>
        b.chapterIndex == currentChapter &&
        (b.charOffset - charOffset).abs() <= tolerance);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台时立刻落盘：这是系统回收进程前唯一的保存机会
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      saveNow();
    }
  }

  void _safeNotify({bool pageOnly = false}) {
    lastChangePageOnly = pageOnly;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    saveNow();
    super.dispose();
  }
}
