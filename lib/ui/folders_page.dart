import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/settings.dart';
import '../state/library_state.dart';

/// 扫描文件夹管理页。
class FoldersPage extends StatefulWidget {
  final LibraryState library;
  const FoldersPage({super.key, required this.library});

  @override
  State<FoldersPage> createState() => _FoldersPageState();
}

class _FoldersPageState extends State<FoldersPage> {
  Future<void> _addFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: '选择要扫描的文件夹');
    if (dir == null) return;
    final settings = AppSettings.instance;
    // 归一化尾部分隔符再查重，避免 '/a/b' 与 '/a/b/' 重复添加
    final normalized = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
    final list = settings.scanFolders;
    if (!list.contains(normalized)) {
      list.add(normalized);
      await settings.setScanFolders(list);
    }
    if (mounted) setState(() {});
  }

  Future<void> _removeFolder(String path) async {
    final settings = AppSettings.instance;
    // getter 返回的是缓存列表的引用：先复制再改，避免持久化失败时内存已脏
    final list = List<String>.from(settings.scanFolders)..remove(path);
    await settings.setScanFolders(list);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final folders = AppSettings.instance.scanFolders;
    return Scaffold(
      appBar: AppBar(title: const Text('扫描文件夹')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.folder_special_outlined,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('全盘扫描始终会执行，这里添加的文件夹会在每次扫描时额外检查。'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ...folders.map((f) => Card(
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(f, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _removeFolder(f),
                  ),
                ),
              )),
          if (folders.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('还没有添加文件夹', style: TextStyle(color: Colors.grey))),
            ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _addFolder,
            icon: const Icon(Icons.add),
            label: const Text('添加文件夹'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: widget.library.scanning
                ? null
                : () {
                    // 先返回书架再扫描：扫描进度横幅就在书架顶部，无需在本页干等
                    Navigator.pop(context);
                    widget.library.scan(fullScan: false);
                  },
            icon: const Icon(Icons.manage_search),
            label: const Text('立即扫描这些文件夹'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: widget.library.scanning
                ? null
                : () {
                    Navigator.pop(context);
                    widget.library.scan(fullScan: true);
                  },
            icon: const Icon(Icons.travel_explore),
            label: const Text('全盘重新扫描（含 SD 卡/U 盘）'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final n = await widget.library.resetIgnoredPaths();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(n == 0 ? '没有忽略中的文件' : '已重置 $n 个被忽略的文件，下次扫描会重新提示')));
              }
              setState(() {});
            },
            icon: const Icon(Icons.restart_alt),
            label: Text(widget.library.ignoredCount > 0
                ? '重置忽略列表（${widget.library.ignoredCount} 个文件）'
                : '重置忽略列表'),
          ),
        ],
      ),
    );
  }
}
