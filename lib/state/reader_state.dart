import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

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

  /// 上次排版调用的样式参数（layoutFor 记录）：下次打开书时
  /// 隔离线程预排版窗口复用同一套参数，保证与 build 期排版完全一致。
  double? _lastStyleFontSize;
  double? _lastStyleHeight;
  String? _lastStyleFontFamily;
  bool? _lastStyleIndent;

  bool get isOnlineBook => book.isOnline;

  /// 在途章节加载任务（按章去重：同一章并发请求复用同一个 Future）。
  final Map<int, Future<void>> _inflight = {};

  /// 在途任务中由前台触发的章（chapterLoading 的"前台"标记）。
  final Set<int> _inflightForeground = {};

  /// 当前章正文是否正在联网加载（仅在线书前台加载时为 true）。
  /// 派生自在途任务表，不再单独维护布尔字段。
  bool get chapterLoading =>
      _inflight.containsKey(currentChapter) &&
      _inflightForeground.contains(currentChapter);

  /// 在线书各章的正文地址（与 chapters 下标对应）。
  List<String> _chapterUrls = [];

  /// 在线书已解析的书源实例（避免每加载一章都查库反序列化）。
  BookSource? _source;

  bool _disposed = false;

  /// 在途 load 单飞：并发调用（如连续切换编码）复用同一 Future，
  /// 防止两次解析交错覆盖 chapters/currentChapter 等共享状态。
  Future<void>? _loadFuture;

  /// 上一次通知是否仅为页码变化（UI 据此跳过菜单关闭时的整页重建）。
  bool lastChangePageOnly = false;

  /// 打开书：解析文件 → 恢复进度 → 载入书签。单飞：在途时复用同一 Future。
  Future<void> load() {
    final f = _loadFuture;
    if (f != null) return f;
    final task = _doLoad();
    _loadFuture = task;
    return task.whenComplete(() => _loadFuture = null);
  }

  Future<void> _doLoad() async {
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

  /// 手动切换本地 TXT 书的解析编码并重解析；进度由既有恢复链路保留
  /// （切换前设 _pendingCharOffset，load 后 restorePage 按 book.charOffset
  /// 恢复页内位置；load 单飞保证连续切换串行化）。
  Future<void> switchEncoding(String enc) async {
    if (book.isOnline || book.format != BookFormat.txt) return;
    if (book.encoding == enc) return;
    // 在途重解析先等它落地，避免两次 load 并发交错覆盖共享状态
    final pending = _loadFuture;
    if (pending != null) await pending;
    if (book.encoding == enc) return;
    book.encoding = enc;
    if (book.id != null) await _db.updateBook(book);
    await load();
  }

  /// 本地书解析 job（compute 目标须为顶层/静态函数）。
  static Future<ParsedBook> _parseLocalBookJob(Map<String, Object?> args) async {
    final path = args['path']! as String;
    final enc = (args['encoding'] as String?) ?? '';
    return BookParser.parseFile(path, BookFormat.fromPath(path),
        encodingOverride: enc.isEmpty ? null : enc);
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
      parsed = await compute(_parseLocalBookJob, {
        'path': path,
        'encoding': book.encoding,
      });
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
    // 加载期（UI 仍显示 loading）在隔离线程预排版当前窗口，
    // 消除打开大书后 build 期同步排版造成的约 1 秒顿挫
    await _precomputeWindowLayouts();
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
      final info = await SourceService.bookInfoIsolated(
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
  /// 去重：同一章已有在途加载时直接返回该 Future；前台请求会把在途任务
  /// 升级为前台，让 UI 显示加载状态。
  Future<void> _ensureChapterLoaded(int idx, {bool foreground = false}) async {
    if (idx < 0 || idx >= chapters.length) return;
    final existing = _inflight[idx];
    if (existing != null) {
      if (foreground && !_inflightForeground.contains(idx)) {
        _inflightForeground.add(idx);
        _safeNotify();
      }
      return existing;
    }
    final task = _loadChapter(idx, foreground: foreground);
    _inflight[idx] = task;
    return task;
  }

  /// 单章实际加载：缓存 → 网络；无论成败都在 finally 清理在途标记。
  Future<void> _loadChapter(int idx, {required bool foreground}) async {
    // 前台旗标必须在进入处就加入：缓存命中/内存命中分支会提前 return，
    // 若在缓存检查后才加旗标，命中路径全程零 notify，跳章后 UI 停在
    // 空白页且无加载指示（文本落定后无人再触发重建）。
    if (foreground && _inflightForeground.add(idx)) {
      _safeNotify();
    }
    try {
      final cur = chapters[idx].text;
      if (cur.isNotEmpty && !cur.startsWith(_failedPrefix)) return;
      final cached =
          await _db.loadContent(book.id!, idx, url: _chapterUrls[idx]);
      if (cached != null && cached.isNotEmpty) {
        _applyChapterText(idx, cached);
        return;
      }
      final source = _source;
      if (source == null) {
        _applyChapterText(idx, '$_failedPrefix 书源不存在或已删除');
        return;
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
      }
    } finally {
      _inflight.remove(idx);
      if (_inflightForeground.remove(idx)) {
        _safeNotify(); // 加载结束：撤销加载指示
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
    // 正文卸载的同时清掉远章的排版缓存，避免旧分页结果继续占内存
    _layouts.removeWhere((k, _) => (k - center).abs() > keep);
  }

  /// 在隔离线程预排版打开窗口（当前章 ±1）。
  /// 依赖上次会话记录的视口/样式参数（layoutFor 调用时记录）；
  /// 首次安装后无记录、或隔离排版失败时静默跳过——build 期
  /// layoutFor 的同步排版兜底，正确性不受影响。
  Future<void> _precomputeWindowLayouts() async {
    final fs = _lastStyleFontSize;
    final lh = _lastStyleHeight;
    final ff = _lastStyleFontFamily;
    final ind = _lastStyleIndent;
    final w = _layoutWidth;
    final h = _layoutHeight;
    if (fs == null || lh == null || ind == null || w == null || h == null) {
      return;
    }
    try {
      final jobs = <Map<String, Object?>>[
        for (final idx in [
          currentChapter - 1,
          currentChapter,
          currentChapter + 1,
        ])
          if (idx >= 0 && idx < chapters.length && !_layouts.containsKey(idx))
            {'idx': idx, 'text': chapters[idx].text},
      ];
      if (jobs.isEmpty) return;
      final results = await compute(_precomputeLayoutJob, {
        'jobs': jobs,
        'fontSize': fs,
        'lineHeight': lh,
        'fontFamily': ff,
        'indent': ind,
        'viewportWidth': w,
        'viewportHeight': h,
      });
      for (final entry in results) {
        _layouts[entry.key] = entry.value;
      }
    } catch (_) {
      // 隔离排版失败不影响打开：build 期 layoutFor 同步排版兜底
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
    // 记录样式参数：下次打开书时隔离线程预排版窗口复用同一套参数
    _lastStyleFontSize = style.fontSize;
    _lastStyleHeight = style.height;
    _lastStyleFontFamily = style.fontFamily;
    _lastStyleIndent = indent;
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
    // 跳章同样要落进度（字段口径与 onPageChanged/saveNow 一致）：
    // 否则从目录跳章后直接退出，进度仍停留在跳转前的章节
    book
      ..chapterIndex = currentChapter
      ..charOffset = charOffsetInChapter
      ..percent = percent;
    _saveDebounced();
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
  Timer? _saveTimer;

  /// 节流落盘：2 秒内的连续改动合并为一次写库。
  /// 用可取消的 Timer 而非 Future.delayed，dispose 时能撤掉未触发的保存。
  void _saveDebounced() {
    if (_savePending) return;
    _savePending = true;
    _saveTimer = Timer(const Duration(seconds: 2), () async {
      try {
        await saveNow();
      } catch (_) {
        // 定时落盘失败不冒泡成未捕获异常；下次翻页/退后台/退出会再试
      } finally {
        _savePending = false; // 写库结束（含失败）后再复位
      }
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

  // ---------- 全文搜索 ----------

  List<({int chapter, int offset, String preview})> searchResults = [];
  String lastQuery = '';
  bool searching = false;
  String? searchError;

  /// 全书关键词搜索（隔离线程分批执行，逐章定位所有命中）。
  Future<void> searchBook(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    lastQuery = q;
    searching = true;
    searchError = null;
    searchResults = [];
    _safeNotify();
    try {
      // 分批把章节文本送进搜索 isolate，避免整书一次性拷贝；批内每章
      // 带上章下标，合并命中时仍是全局 (章顺序, 章内位置) 排列
      const batch = 100;
      final hits = <({int chapter, int offset, String preview})>[];
      for (int start = 0;
          start < chapters.length && hits.length < 500;
          start += batch) {
        final end = (start + batch).clamp(0, chapters.length);
        final part = <({int idx, String text})>[
          for (int i = start; i < end; i++) (idx: i, text: chapters[i].text),
        ];
        final found = await compute(_searchBatchJob, {
          'chapters': part,
          'query': q,
          'limit': 500 - hits.length,
        });
        for (final (idx, offset) in found) {
          final text = chapters[idx].text;
          final s = (offset - 20).clamp(0, text.length);
          final e = (offset + q.length + 20).clamp(0, text.length);
          hits.add(
              (chapter: idx, offset: offset, preview: text.substring(s, e)));
        }
      }
      searchResults = hits;
    } catch (e) {
      searchError = '搜索失败：$e';
    }
    searching = false;
    _safeNotify();
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
      unawaited(saveNow().catchError((_) {})); // 不能 await：失败不抛未捕获异常
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
    _saveTimer?.cancel(); // 撤掉未触发的节流保存，改为立即落盘
    unawaited(saveNow().catchError((_) {})); // dispose 不能 await：失败不抛未捕获异常
    super.dispose();
  }
}

/// 单批章节搜索（隔离线程执行）：逐章定位命中，返回 (章下标, 章内偏移) 列表。
/// 只接收本批文本，避免整书一次性拷贝进 isolate；预览由主 isolate 依偏移截取。
List<(int, int)> _searchBatchJob(Map<String, Object?> job) {
  final chapters = job['chapters'] as List<({int idx, String text})>;
  final query = job['query'] as String;
  final limit = job['limit'] as int;
  final found = <(int, int)>[];
  for (final c in chapters) {
    if (found.length >= limit) break;
    final text = c.text;
    var pos = text.indexOf(query);
    var inChapter = 0;
    while (pos >= 0 && inChapter < 50 && found.length < limit) {
      found.add((c.idx, pos));
      pos = text.indexOf(query, pos + query.length);
      inChapter++;
    }
  }
  return found;
}

/// 打开窗口预排版（隔离线程执行）：按主 isolate 传入的样式与视口参数排版，
/// 返回可直接写入 _layouts 的布局。样式只取影响分页的三个量
/// （字号/行高/字体），颜色等渲染属性不参与排版。
List<MapEntry<int, ChapterLayout>> _precomputeLayoutJob(
    Map<String, Object?> args) {
  final style = TextStyle(
    fontSize: args['fontSize']! as double,
    height: args['lineHeight']! as double,
    fontFamily: args['fontFamily'] as String?,
  );
  final width = args['viewportWidth']! as double;
  final height = args['viewportHeight']! as double;
  final indent = args['indent']! as bool;
  final out = <MapEntry<int, ChapterLayout>>[];
  for (final job in (args['jobs']! as List).cast<Map<dynamic, dynamic>>()) {
    final idx = (job['idx']! as num).toInt();
    final text = job['text']! as String;
    out.add(MapEntry(
        idx,
        Paginator.layout(
          chapterText: text,
          style: style,
          viewportWidth: width,
          viewportHeight: height,
          indent: indent,
        )));
  }
  return out;
}
