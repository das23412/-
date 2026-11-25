import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/book_format.dart';
import '../core/text_utils.dart';
// book.dart 里也定义了枚举 BookSource（书籍来源），与书源类重名，隐藏之
import '../data/book.dart' hide BookSource;
import '../data/db.dart';
import '../data/settings.dart';
import '../services/scan_service.dart';
import '../source/book_source.dart';
import '../source/source_service.dart';

/// 书架排序方式。
enum SortMode { lastRead, addedTime, title }

/// 书架状态：书籍列表、扫描、导入、批量操作。
class LibraryState extends ChangeNotifier {
  final AppDb _db = AppDb.instance;
  final AppSettings settings = AppSettings.instance;

  List<Book> books = [];

  /// 书架全部标签（随 reload 刷新，界面直接读取，避免每次重建都查库）。
  Set<String> tags = {};

  bool scanning = false;
  String scanHint = '';

  /// 导入副本文件名的自增序号，避免同一毫秒内的文件名碰撞覆盖。
  int _importSeq = 0;

  /// 扫描发现、等待用户勾选确认的候选书籍。
  List<Book> pendingCandidates = [];

  /// 「所有文件访问」未授权时为 true：扫描结果不完整。
  bool scanRestricted = false;

  /// 最近一次扫描的报告（供界面展示）。
  String scanReport = '';

  // 界面状态
  SortMode sortMode = SortMode.lastRead;
  String searchQuery = '';
  String? activeTag; // null = 全部
  bool selectionMode = false;
  final Set<int> selectedIds = {};

  /// visibleBooks 结果缓存：books/搜索词/标签/排序任一变化时置脏，
  /// 下次访问重算一次，其余访问直接复用，书架频繁重建不再重复过滤+排序。
  List<Book> _visibleCache = const [];
  bool _visibleDirty = true;

  // ---------- 数据加载 ----------

  Future<void> reload() async {
    books = await _db.allBooks();
    tags = await _db.allTags();
    _visibleDirty = true;
    notifyListeners();
  }

  List<Book> get visibleBooks {
    if (_visibleDirty) {
      _visibleCache = _computeVisibleBooks();
      _visibleDirty = false;
    }
    return _visibleCache;
  }

  /// 重算过滤+排序结果（仅在缓存失效时调用）。
  List<Book> _computeVisibleBooks() {
    Iterable<Book> list = books;
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      list = list.where((b) => b.title.toLowerCase().contains(q));
    }
    if (activeTag != null && activeTag!.isNotEmpty) {
      list = list.where((b) => b.tagList.contains(activeTag));
    }
    final sorted = list.toList();
    sorted.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      switch (sortMode) {
        case SortMode.lastRead:
          return b.lastReadAt.compareTo(a.lastReadAt);
        case SortMode.addedTime:
          return b.addedAt.compareTo(a.addedAt);
        case SortMode.title:
          return a.title.compareTo(b.title);
      }
    });
    return sorted;
  }

  // ---------- 扫描 ----------

  /// 全盘 + 用户文件夹扫描。结果不直接入库，而是生成候选清单交给用户勾选。
  Future<void> scan({bool fullScan = true}) async {
    if (scanning) return;
    scanning = true;
    scanHint = fullScan ? '正在全盘扫描…' : '正在扫描…';
    scanRestricted = false;
    notifyListeners();

    try {
      books = await _db.allBooks();
      _visibleDirty = true;
      // 权限预检：未授权时安卓会返回空目录列表，扫描注定不完整
      final manageGranted = await Permission.manageExternalStorage.isGranted;
      scanRestricted = !manageGranted;

      final roots = <String>[];
      if (fullScan) {
        roots.addAll(ScanService.defaultRoots()); // 内置存储 + SD 卡 + U 盘
      }
      roots.addAll(settings.scanFolders);
      final existingRoots =
          roots.where((r) => Directory(r).existsSync()).toList();
      final report = await compute(ScanService.scan, existingRoots);

      final existing = books.map((b) => b.path).toSet();
      final ignored = settings.ignoredScanPaths.toSet();
      final candidates = <Book>[];
      for (final f in report.found) {
        if (existing.contains(f.path) || ignored.contains(f.path)) continue;
        candidates.add(Book(
          path: f.path,
          title: f.title,
          format: f.format,
          sizeBytes: f.size,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      pendingCandidates = candidates;
      scanReport =
          '存储区 ${report.roots.length} 个 · 进入目录 ${report.dirsWalked} 个 · '
          '跳过 ${report.skippedDirs} 个 · 无法读取 ${report.unreadableDirs} 个 · '
          '候选 ${candidates.length} 本';
      if (scanRestricted) {
        scanHint = '未授予「所有文件访问」权限，扫描结果不完整';
      } else if (candidates.isEmpty) {
        scanHint = report.found.isEmpty
            ? '没有发现新的书籍（详见扫描报告）'
            : '发现的书籍都已在书架或忽略列表中';
      } else {
        scanHint = '发现 ${candidates.length} 本候选书籍，请在清单中勾选导入';
      }
      settings.firstScanDone = true;
    } catch (e) {
      scanHint = '扫描失败：$e';
    } finally {
      // 过程中只更新字段不 notify，统一在 finally 收尾：全程开始 1 次 + 结束 1 次
      scanning = false;
      notifyListeners();
    }
  }

  /// 确认导入勾选的候选书籍；未勾选的可选择记住（以后扫描不再提示）。
  Future<int> confirmCandidates(
    Set<String> paths, {
    bool rememberUnselected = true,
  }) async {
    final toInsert = <Book>[];
    final toIgnore = <String>[];
    for (final b in pendingCandidates) {
      if (paths.contains(b.path)) {
        toInsert.add(b);
      } else if (rememberUnselected) {
        toIgnore.add(b.path);
      }
    }
    // 单次事务入库 + 一次性写忽略列表，避免逐本写库/写配置
    final n = await _db.insertBooks(toInsert);
    if (toIgnore.isNotEmpty) await _ignorePaths(toIgnore);
    pendingCandidates = [];
    // scanHint 先赋值再 reload：reload 自带一次 notify，避免连续重复通知
    scanHint = n > 0 ? '已导入 $n 本书' : '';
    await reload();
    return n;
  }

  /// 全部忽略这批候选（记住，以后不再提示）。
  Future<void> ignoreAllCandidates() async {
    await _ignorePaths(pendingCandidates.map((b) => b.path).toList());
    pendingCandidates = [];
    scanHint = '已忽略本批候选文件';
    notifyListeners();
  }

  /// 暂不处理（不记住，下次扫描还会提示）。
  void discardCandidates() {
    pendingCandidates = [];
    scanHint = '';
    notifyListeners();
  }

  Future<void> _ignorePaths(List<String> paths) async {
    final list = settings.ignoredScanPaths;
    final existing = list.toSet();
    var changed = false;
    for (final path in paths) {
      if (existing.add(path)) {
        list.add(path);
        changed = true;
      }
    }
    if (changed) await settings.setIgnoredScanPaths(list);
  }

  Future<int> resetIgnoredPaths() async {
    final n = settings.ignoredScanPaths.length;
    await settings.setIgnoredScanPaths([]);
    return n;
  }

  int get ignoredCount => settings.ignoredScanPaths.length;

  /// 清理已失效的引用（原文件被删除的书）。在线书没有本地文件，跳过。
  /// existsSync 逐本检查在隔离线程执行，千本书不卡 UI。
  Future<int> cleanMissing() async {
    final candidates = books
        .where((b) => !b.isOnline && !b.imported)
        .map((b) => b.path)
        .toList();
    final missing = await compute(_findMissingFiles, candidates);
    await _db.removeBooksByPaths(missing);
    await reload();
    return missing.length;
  }

  // ---------- 导入 ----------

  /// 手动选文件导入：复制到应用私有目录，不依赖任何存储权限。
  /// 返回导入成功的书名列表；路径冲突被库忽略的旧书也计入统计。
  Future<List<String>> importFiles(List<String> pickedPaths) async {
    final importedTitles = <String>[];
    final baseDir = await _importDir();
    for (final src in pickedPaths) {
      final book = await _importOne(baseDir, src);
      if (book != null) importedTitles.add(book.title);
    }
    await reload();
    return importedTitles;
  }

  /// 导入单个文件：复制到导入目录、入库，返回带 id 的新书（调用方可直接打开）。
  /// 文件不存在/格式不支持/拷贝或入库异常返回 null；路径冲突被忽略（id<=0）
  /// 时返回库里已存在的旧记录，调用方照常统计与打开。
  Future<Book?> _importOne(Directory baseDir, String src) async {
    try {
      final srcFile = File(src);
      if (!srcFile.existsSync()) return null;
      final name = p.basename(src);
      final format = BookFormat.fromPath(name);
      if (format == BookFormat.unknown) return null;
      final dest = p.join(baseDir.path,
          '${DateTime.now().millisecondsSinceEpoch}_${_importSeq++}_${p.basename(name)}');
      await srcFile.copy(dest);
      final stat = File(dest).statSync();
      final book = Book(
        path: dest,
        title: TextUtils.cleanTitle(p.basenameWithoutExtension(src)),
        format: format,
        sizeBytes: stat.size,
        addedAt: DateTime.now().millisecondsSinceEpoch,
        imported: true,
      );
      final id = await _db.insertBook(book);
      // Book.id 是 final：用 copyWith 带回新插入的自增 id，
      // ReaderPage 的进度保存/书签/目录都依赖 book.id
      if (id > 0) return book.copyWith(id: id);
      return await _db.bookByPath(dest);
    } catch (_) {
      // 单个失败不影响其他
      return null;
    }
  }

  /// 其他 App “用墨阅打开/分享”传来的文件（原生层已拷贝到缓存目录）。
  /// 返回入库后的书（含 id，调用方直接打开），失败返回 null。
  /// 不在此处 reload：批量导入由调用方整批完成后统一刷一次书架，
  /// 避免 25 个文件触发 25 次全量查库。
  Future<Book?> importFromIntent(String path) async {
    final baseDir = await _importDir();
    return _importOne(baseDir, path);
  }

  /// 应用私有导入目录（也是链接下载的目标目录）。
  Future<Directory> importDirectory() => _importDir();

  /// 把搜索到的在线书加入书架；已存在时直接返回现有记录。
  /// 返回 null 表示入库失败。
  Future<Book?> addOnlineBook(SourceBook hint) async {
    final path = Book.onlinePath(hint.sourceId, hint.bookUrl);
    final existing = await _db.bookByPath(path);
    if (existing != null) return existing;
    var name = hint.name;
    var author = hint.author;
    var coverUrl = hint.coverUrl;
    // 书源联网开关关闭时跳过详情页请求，直接用搜索结果字段
    final source =
        settings.allowSources ? await BookSource.findById(hint.sourceId) : null;
    if (source != null) {
      try {
        // 详情页失败不致命：继续用搜索结果的信息
        final info = await SourceService.bookInfoIsolated(source, hint);
        name = info.book.name;
        author = info.book.author;
        coverUrl = info.book.coverUrl;
      } catch (_) {}
    }
    final book = Book(
      path: path,
      title: name,
      format: BookFormat.online,
      sizeBytes: 0,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      author: author,
      coverUrl: coverUrl,
      isOnline: true,
      sourceId: hint.sourceId,
      bookUrl: hint.bookUrl,
    );
    await _db.insertBook(book);
    await reload();
    return _db.bookByPath(path);
  }

  /// 把已下载到应用目录的文件登记进书架（链接导入用）。
  Future<Book> registerDownloadedFile(String path) async {
    final file = File(path);
    final stat = file.statSync();
    final name = p.basename(path);
    final book = Book(
      path: path,
      title: TextUtils.cleanTitle(p.basenameWithoutExtension(name)),
      format: BookFormat.fromPath(name),
      sizeBytes: stat.size,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      imported: true,
    );
    await _db.insertBook(book);
    await reload();
    return book;
  }

  Future<Directory> _importDir() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(doc.path, 'books'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  // ---------- 单书操作 ----------

  Future<void> rename(Book b, String newTitle) async {
    b.title = newTitle.trim().isEmpty ? b.title : newTitle.trim();
    await _db.updateBook(b);
    await reload();
  }

  Future<void> togglePin(Book b) async {
    b.pinned = !b.pinned;
    await _db.updateBook(b);
    await reload();
  }

  /// 批量置顶：单条 UPDATE ... WHERE id IN (...) 完成（不再逐本 update），
  /// 随后统一 reload 刷新书架。
  Future<void> pinByIds(Set<int> ids) async {
    if (ids.isEmpty) return;
    await _db.setPinnedBatch(ids.toList(), true);
    await reload();
  }

  Future<void> setTags(Book b, List<String> tags) async {
    b.tags = tags.toSet().join(',');
    await _db.updateBook(b);
    await reload();
  }

  Future<void> deleteByIds(List<int> ids, {bool deleteFiles = false}) async {
    if (deleteFiles) {
      // 文件删除移入 compute 隔离线程：主 isolate 只收集待删路径
      //（imported 副本且路径非空才删），逐个同步 IO 不再占用 UI 线程
      final paths = books
          .where((b) => ids.contains(b.id) && b.imported && b.path.isNotEmpty)
          .map((b) => b.path)
          .toList();
      await compute(_deleteFiles, paths);
    }
    await _db.deleteBooks(ids);
    exitSelectionMode();
    await reload();
  }

  Future<Set<String>> allTags() => _db.allTags();

  // ---------- 选择模式 ----------

  void enterSelectionMode(int firstId) {
    selectionMode = true;
    selectedIds.clear();
    selectedIds.add(firstId);
    notifyListeners();
  }

  void toggleSelect(int id) {
    if (selectedIds.contains(id)) {
      selectedIds.remove(id);
    } else {
      selectedIds.add(id);
    }
    if (selectedIds.isEmpty) exitSelectionMode();
    notifyListeners();
  }

  void selectAll() {
    selectedIds
      ..clear()
      ..addAll(visibleBooks.map((b) => b.id).whereType<int>());
    notifyListeners();
  }

  void exitSelectionMode() {
    selectionMode = false;
    selectedIds.clear();
    notifyListeners();
  }

  void setSearch(String q) {
    searchQuery = q;
    _visibleDirty = true; // 搜索词变化必须置脏，否则可见列表缓存不刷新
    notifyListeners();
  }

  void setSortMode(SortMode m) {
    sortMode = m;
    _visibleDirty = true; // 排序变化必须置脏
    notifyListeners();
  }

  void setActiveTag(String? tag) {
    activeTag = tag;
    _visibleDirty = true; // 标签筛选变化必须置脏
    notifyListeners();
  }
}

/// 逐本检查文件是否存在（隔离线程执行，compute 目标须为顶层函数）。
List<String> _findMissingFiles(List<String> paths) {
  return paths.where((p) => !File(p).existsSync()).toList();
}

/// 批量删除导入副本文件（隔离线程执行，compute 目标须为顶层函数）。
/// 返回删除失败的个数。
int _deleteFiles(List<String> paths) {
  var failed = 0;
  for (final path in paths) {
    try {
      File(path).deleteSync();
    } catch (_) {
      failed++;
    }
  }
  return failed;
}
