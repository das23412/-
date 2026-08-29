import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/book_format.dart';
import '../core/text_utils.dart';
import '../data/book.dart';
import '../data/db.dart';
import '../data/settings.dart';
import '../services/scan_service.dart';

/// 书架排序方式。
enum SortMode { lastRead, addedTime, title }

/// 书架状态：书籍列表、扫描、导入、批量操作。
class LibraryState extends ChangeNotifier {
  final AppDb _db = AppDb.instance;
  final AppSettings settings = AppSettings.instance;

  List<Book> books = [];
  bool scanning = false;
  String scanHint = '';

  /// 扫描发现、等待用户勾选确认的候选书籍。
  List<Book> pendingCandidates = [];

  // 界面状态
  SortMode sortMode = SortMode.lastRead;
  String searchQuery = '';
  String? activeTag; // null = 全部
  bool selectionMode = false;
  final Set<int> selectedIds = {};

  // ---------- 数据加载 ----------

  Future<void> reload() async {
    books = await _db.allBooks();
    notifyListeners();
  }

  List<Book> get visibleBooks {
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
    notifyListeners();

    try {
      books = await _db.allBooks();
      final roots = <String>[];
      if (fullScan) roots.add(ScanService.primaryRoot);
      roots.addAll(settings.scanFolders);
      final existingRoots = roots.where((r) => Directory(r).existsSync()).toList();
      final found = await compute(ScanService.scan, existingRoots);

      final existing = books.map((b) => b.path).toSet();
      final ignored = settings.ignoredScanPaths.toSet();
      final candidates = <Book>[];
      for (final f in found) {
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
      scanHint = candidates.isEmpty
          ? '没有发现新的书籍'
          : '发现 ${candidates.length} 本候选书籍，请在清单中勾选导入';
      settings.firstScanDone = true;
      notifyListeners();
    } catch (e) {
      scanHint = '扫描失败：$e';
      notifyListeners();
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// 确认导入勾选的候选书籍；未勾选的可选择记住（以后扫描不再提示）。
  Future<int> confirmCandidates(
    Set<String> paths, {
    bool rememberUnselected = true,
  }) async {
    var n = 0;
    for (final b in pendingCandidates) {
      if (paths.contains(b.path)) {
        final id = await _db.insertBook(b);
        if (id > 0) n++;
      } else if (rememberUnselected) {
        await _ignorePaths([b.path]);
      }
    }
    pendingCandidates = [];
    await reload();
    scanHint = n > 0 ? '已导入 $n 本书' : '';
    notifyListeners();
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
    for (final p in paths) {
      if (!list.contains(p)) list.add(p);
    }
    await settings.setIgnoredScanPaths(list);
  }

  Future<int> resetIgnoredPaths() async {
    final n = settings.ignoredScanPaths.length;
    await settings.setIgnoredScanPaths([]);
    return n;
  }

  int get ignoredCount => settings.ignoredScanPaths.length;

  /// 清理已失效的引用（原文件被删除的书）。
  Future<int> cleanMissing() async {
    final missing = <String>[];
    for (final b in books) {
      if (!b.imported && !File(b.path).existsSync()) missing.add(b.path);
    }
    await _db.removeBooksByPaths(missing);
    await reload();
    return missing.length;
  }

  // ---------- 导入 ----------

  /// 手动选文件导入：复制到应用私有目录，不依赖任何存储权限。
  Future<List<String>> importFiles(List<String> pickedPaths) async {
    final importedTitles = <String>[];
    final baseDir = await _importDir();
    for (final src in pickedPaths) {
      try {
        final srcFile = File(src);
        if (!srcFile.existsSync()) continue;
        final name = p.basename(src);
        final format = BookFormat.fromPath(name);
        if (format == BookFormat.unknown) continue;
        final dest = p.join(
            baseDir.path,
            '${DateTime.now().millisecondsSinceEpoch}_${p.basename(name)}');
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
        if (id > 0) importedTitles.add(book.title);
      } catch (_) {
        // 单个失败不影响其他
      }
    }
    await reload();
    return importedTitles;
  }

  /// 其他 App “用墨阅打开”传来的文件（原生层已拷贝到缓存目录）。
  Future<void> importFromIntent(String path) async {
    await importFiles([path]);
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

  Future<void> setTags(Book b, List<String> tags) async {
    b.tags = tags.toSet().join(',');
    await _db.updateBook(b);
    await reload();
  }

  Future<void> deleteByIds(List<int> ids, {bool deleteFiles = false}) async {
    if (deleteFiles) {
      for (final id in ids) {
        final b = books.firstWhere((e) => e.id == id, orElse: () => Book(
            path: '', title: '', format: BookFormat.unknown, sizeBytes: 0, addedAt: 0));
        if (b.imported && b.path.isNotEmpty) {
          try {
            File(b.path).deleteSync();
          } catch (_) {}
        }
      }
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
      ..addAll(visibleBooks.map((b) => b.id!).whereType<int>());
    notifyListeners();
  }

  void exitSelectionMode() {
    selectionMode = false;
    selectedIds.clear();
    notifyListeners();
  }

  void setSearch(String q) {
    searchQuery = q;
    notifyListeners();
  }

  void setSortMode(SortMode m) {
    sortMode = m;
    notifyListeners();
  }

  void setActiveTag(String? tag) {
    activeTag = tag;
    notifyListeners();
  }
}
