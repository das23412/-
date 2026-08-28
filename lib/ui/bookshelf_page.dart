import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/book_format.dart';
import '../data/book.dart';
import '../state/library_state.dart';
import 'book_detail_sheet.dart';
import 'common.dart';
import 'folders_page.dart';
import 'reader_page.dart';

/// 书架主页。
class BookshelfPage extends StatefulWidget {
  const BookshelfPage({super.key});

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage> {
  bool _searching = false;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final lib = context.read<LibraryState>();
    lib.reload();
  }

  Future<void> _openBook(Book book) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderPage(book: book)),
    );
    if (mounted) context.read<LibraryState>().reload();
  }

  Future<void> _importFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub', 'mobi', 'azw3', 'azw', 'fb2', 'html', 'htm'],
    );
    if (result == null || result.paths.isEmpty) return;
    if (!mounted) return;
    final lib = context.read<LibraryState>();
    final titles = await lib.importFiles(result.paths.whereType<String>().toList());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(titles.isEmpty ? '没有成功导入的文件' : '已导入 ${titles.length} 本：${titles.take(3).join('、')}${titles.length > 3 ? ' 等' : ''}'),
      ));
    }
  }

  void _showImportSheet() {
    final lib = context.read<LibraryState>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('从手机选择文件导入'),
              subtitle: const Text('支持 TXT / EPUB / MOBI / AZW3 / FB2 / HTML'),
              onTap: () {
                Navigator.pop(ctx);
                _importFiles();
              },
            ),
            ListTile(
              leading: const Icon(Icons.manage_search),
              title: const Text('全盘扫描手机里的小说'),
              onTap: () {
                Navigator.pop(ctx);
                lib.scan(fullScan: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('管理扫描文件夹'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => FoldersPage(library: lib)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清理已丢失的书籍'),
              subtitle: const Text('原文件被删除的书会从书架移除'),
              onTap: () async {
                Navigator.pop(ctx);
                final n = await lib.cleanMissing();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(n == 0 ? '没有需要清理的书籍' : '已移除 $n 本失效书籍')));
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showDetail(Book book) {
    final lib = context.read<LibraryState>();
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: BookDetailSheet(book: book, library: lib),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryState>();
    final shown = lib.visibleBooks;

    return PopScope(
      canPop: !lib.selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && lib.selectionMode) lib.exitSelectionMode();
      },
      child: Scaffold(
        appBar: _appBar(context, lib, shown.length),
        body: Column(
          children: [
            _tagBar(lib),
            if (lib.scanning || lib.scanHint.isNotEmpty) _scanBanner(lib),
            Expanded(
              child: shown.isEmpty
                  ? _empty(context, lib)
                  : RefreshIndicator(
                      onRefresh: () => lib.scan(fullScan: false),
                      child: GridView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 0.52,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: shown.length,
                        itemBuilder: (ctx, i) => _bookCard(context, lib, shown[i]),
                      ),
                    ),
            ),
          ],
        ),
        floatingActionButton: lib.selectionMode
            ? null
            : FloatingActionButton.extended(
                onPressed: _showImportSheet,
                icon: const Icon(Icons.add),
                label: const Text('添加书籍'),
              ),
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context, LibraryState lib, int count) {
    if (lib.selectionMode) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: lib.exitSelectionMode,
        ),
        title: Text('已选 ${lib.selectedIds.length} 本'),
        actions: [
          IconButton(icon: const Icon(Icons.select_all), onPressed: lib.selectAll, tooltip: '全选'),
          IconButton(
            icon: const Icon(Icons.push_pin_outlined),
            tooltip: '置顶',
            onPressed: () async {
              for (final id in lib.selectedIds) {
                final b = lib.books.firstWhere((e) => e.id == id);
                if (!b.pinned) await lib.togglePin(b);
              }
              lib.exitSelectionMode();
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除',
            onPressed: () async {
              final n = lib.selectedIds.length;
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('批量删除'),
                  content: Text('将从书架删除选中的 $n 本书？导入副本也会一并删除。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await lib.deleteByIds(lib.selectedIds.toList(), deleteFiles: true);
              }
            },
          ),
        ],
      );
    }
    if (_searching) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            setState(() {
              _searching = false;
              _searchController.clear();
              lib.setSearch('');
            });
          },
        ),
        title: TextField(
          controller: _searchController,
          autofocus: true,
          decoration: const InputDecoration(hintText: '搜索书名', border: InputBorder.none),
          onChanged: lib.setSearch,
        ),
      );
    }
    return AppBar(
      title: const Text('墨阅'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜索',
          onPressed: () => setState(() => _searching = true),
        ),
        PopupMenuButton<SortMode>(
          icon: const Icon(Icons.sort),
          tooltip: '排序',
          onSelected: lib.setSortMode,
          itemBuilder: (ctx) => const [
            PopupMenuItem(value: SortMode.lastRead, child: Text('按最近阅读')),
            PopupMenuItem(value: SortMode.addedTime, child: Text('按添加时间')),
            PopupMenuItem(value: SortMode.title, child: Text('按书名')),
          ],
        ),
      ],
    );
  }

  Widget _tagBar(LibraryState lib) {
    return FutureBuilder<Set<String>>(
      future: lib.allTags(),
      builder: (ctx, snap) {
        final tags = snap.data ?? {};
        if (tags.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('全部'),
                  selected: lib.activeTag == null,
                  onSelected: (_) => lib.setActiveTag(null),
                ),
              ),
              for (final t in tags)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(t),
                    selected: lib.activeTag == t,
                    onSelected: (_) => lib.setActiveTag(t),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _scanBanner(LibraryState lib) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          if (lib.scanning)
            const SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (lib.scanning) const SizedBox(width: 10),
          Expanded(
            child: Text(lib.scanHint.isEmpty ? '扫描中…' : lib.scanHint, style: const TextStyle(fontSize: 13)),
          ),
          if (!lib.scanning)
            GestureDetector(
              onTap: () => lib.scanHint = '',
              child: const Icon(Icons.close, size: 16),
            ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, LibraryState lib) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_stories_outlined, size: 72, color: Theme.of(context).hintColor),
          const SizedBox(height: 12),
          const Text('书架还是空的'),
          const SizedBox(height: 6),
          const Text('导入本地小说文件，或全盘扫描手机里的书',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _showImportSheet,
            icon: const Icon(Icons.add),
            label: const Text('添加书籍'),
          ),
        ],
      ),
    );
  }

  Widget _bookCard(BuildContext context, LibraryState lib, Book book) {
    final selected = lib.selectedIds.contains(book.id);
    final inSelection = lib.selectionMode;
    return GestureDetector(
      onTap: () {
        if (inSelection && book.id != null) {
          lib.toggleSelect(book.id!);
        } else {
          _openBook(book);
        }
      },
      onLongPress: () {
        if (book.id == null) return;
        if (inSelection) {
          _showDetail(book);
        } else {
          lib.enterSelectionMode(book.id!);
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _coverColors(book.format),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(8),
                  alignment: Alignment.topLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(book.title,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              height: 1.25,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Text(book.format.displayName,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85), fontSize: 10)),
                    ],
                  ),
                ),
                if (book.unread)
                  Positioned(
                    top: 6, right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.red.shade600,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text('未读',
                          style: TextStyle(color: Colors.white, fontSize: 9)),
                    ),
                  ),
                if (book.pinned)
                  const Positioned(
                    bottom: 6, right: 6,
                    child: Icon(Icons.push_pin, size: 14, color: Colors.amber),
                  ),
                if (inSelection)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: selected
                            ? Colors.teal.withValues(alpha: 0.35)
                            : Colors.black26,
                      ),
                      child: selected
                          ? const Icon(Icons.check_circle, color: Colors.white)
                          : null,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  book.lastReadAt == 0
                      ? formatTimeCN(book.addedAt)
                      : formatTimeCN(book.lastReadAt),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: Theme.of(context).hintColor),
                ),
              ),
              Text(
                book.finished ? '已读完' : '${book.percent.toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 10.5,
                    color: book.finished
                        ? Colors.green.shade600
                        : Theme.of(context).colorScheme.primary),
              ),
            ],
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: book.percent / 100,
              minHeight: 2.5,
              backgroundColor: Theme.of(context).dividerColor.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }

  static List<Color> _coverColors(BookFormat format) {
    switch (format) {
      case BookFormat.txt:
        return [Colors.teal.shade300, Colors.teal.shade700];
      case BookFormat.epub:
        return [Colors.indigo.shade300, Colors.indigo.shade700];
      case BookFormat.mobi:
        return [Colors.deepOrange.shade300, Colors.deepOrange.shade700];
      case BookFormat.fb2:
        return [Colors.purple.shade300, Colors.purple.shade700];
      case BookFormat.html:
        return [Colors.blueGrey.shade300, Colors.blueGrey.shade700];
      case BookFormat.unknown:
        return [Colors.grey.shade400, Colors.grey.shade700];
    }
  }
}
