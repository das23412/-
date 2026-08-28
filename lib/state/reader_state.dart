import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../core/book_format.dart';
import '../core/text_utils.dart';
import '../data/book.dart';
import '../data/db.dart';
import '../parser/parser.dart';
import '../reader/paginate.dart';

/// 阅读会话状态：负责解析、分页、进度、书签。
class ReaderState extends ChangeNotifier {
  ReaderState(this.book);

  final Book book;
  final AppDb _db = AppDb.instance;

  List<ParsedChapter> chapters = [];
  List<int> chapterStartChars = [];
  int totalChars = 0;

  int currentChapter = 0;
  int currentPage = 0;

  bool loading = true;
  String? error;

  List<Bookmark> bookmarks = [];

  final Map<int, ChapterLayout> _layouts = {};
  String _layoutKey = '';

  /// 打开书：解析文件 → 恢复进度 → 载入书签。
  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final path = book.path;
      if (!File(path).existsSync()) {
        error = '文件不存在，可能已被移动或删除：${book.title}';
        loading = false;
        notifyListeners();
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
      // 过滤空章节
      chapters = chapters.where((c) => c.text.trim().isNotEmpty).toList();
      if (chapters.isEmpty) {
        error = '没有解析到可读的正文内容';
        loading = false;
        notifyListeners();
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
      notifyListeners();
    } catch (e) {
      error = '打开失败：${e.toString()}';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshMeta() async {
    if (book.chapterCount != chapters.length || book.wordCount == 0) {
      book
        ..chapterCount = chapters.length
        ..wordCount = TextUtils.countChars(
            chapters.map((c) => c.text).join('\n'));
      await _db.updateBook(book);
    }
  }

  // ---------- 分页 ----------

  /// 配置变化时清空布局缓存。
  void invalidateLayouts(String key) {
    if (_layoutKey != key) {
      _layoutKey = key;
      _layouts.clear();
      notifyListeners();
    }
  }

  ChapterLayout layoutFor(
    int chapterIdx,
    TextStyle style,
    double width,
    double height,
    bool indent,
  ) {
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
    notifyListeners();
  }

  double get percent {
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
    notifyListeners();
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
      notifyListeners();
    }
  }

  Future<void> removeBookmark(int id) async {
    await _db.deleteBookmark(id);
    bookmarks = await _db.bookmarksOf(book.id!);
    notifyListeners();
  }

  /// 当前页是否已有书签（按章+偏移近似匹配）。
  bool hasBookmarkAt(int charOffset) {
    const tolerance = 200;
    return bookmarks.any((b) =>
        b.chapterIndex == currentChapter &&
        (b.charOffset - charOffset).abs() <= tolerance);
  }

  @override
  void dispose() {
    saveNow();
    super.dispose();
  }
}
