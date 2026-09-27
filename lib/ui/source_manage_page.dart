import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/settings.dart';
import '../state/source_state.dart';
import 'source_check_page.dart';
import 'source_search_page.dart';

/// 书源管理：列表、导入、启用/禁用、删除、入口到搜索与检测。
class SourceManagePage extends StatefulWidget {
  const SourceManagePage({super.key});

  @override
  State<SourceManagePage> createState() => _SourceManagePageState();
}

class _SourceManagePageState extends State<SourceManagePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<SourceState>().reload();
    });
  }

  Future<void> _toggleNetwork(bool v) async {
    AppSettings.instance.allowSources = v;
    setState(() {});
  }

  Future<void> _importFromText() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入书源'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '粘贴 Legado（阅读 3.0）书源 JSON\n支持数组 / 单个对象 / 逐行合并格式',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: const Text('导入')),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (ok != true || !mounted) return;
    if (text.isEmpty) return;
    final msg = await context.read<SourceState>().importText(text);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _importFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    try {
      final text = await File(path).readAsString();
      if (!mounted) return;
      final msg = await context.read<SourceState>().importText(text);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取文件失败：$e')));
      }
    }
  }

  void _showImportSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('粘贴书源 JSON 导入'),
              subtitle: const Text('支持 Legado（阅读 3.0）书源格式'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('从文件导入书源'),
              subtitle: const Text('选择 .json / .txt 书源文件'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromFile();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SourceState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.travel_explore),
            tooltip: '书源检测',
            onPressed: state.sources.isEmpty
                ? null
                : () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SourceCheckPage())),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '书源搜索',
            onPressed: state.enabledSources.isEmpty
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const SourceSearchPage())),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'import') _showImportSheet();
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'import', child: Text('导入书源')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showImportSheet,
        icon: const Icon(Icons.add),
        label: const Text('导入书源'),
      ),
      body: Column(
        children: [
          // 联网开关
          Container(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SwitchListTile(
              value: AppSettings.instance.allowSources,
              onChanged: _toggleNetwork,
              title: const Text('允许书源联网'),
              subtitle: const Text('默认关闭。搜索、目录、正文请求都需要此开关。'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                state.importSummary.isEmpty
                    ? '共 ${state.sources.length} 个书源'
                    : state.importSummary,
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).hintColor),
              ),
            ),
          ),
          Expanded(
            child: state.sources.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.source_outlined,
                            size: 64, color: Theme.of(context).hintColor),
                        const SizedBox(height: 12),
                        const Text('还没有书源'),
                        const SizedBox(height: 6),
                        const Text('导入 Legado（阅读 3.0）格式的书源 JSON 开始使用',
                            style:
                                TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: state.sources.length,
                    itemBuilder: (ctx, i) {
                      final s = state.sources[i];
                      return ListTile(
                        leading: Icon(
                          s.enabled
                              ? Icons.check_circle
                              : Icons.check_circle_outline,
                          color: s.enabled
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).disabledColor,
                        ),
                        title: Text(s.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          s.group.isEmpty ? s.id : '${s.group} · ${s.id}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'toggle') {
                              await state.setEnabled(s, !s.enabled);
                            } else if (v == 'delete') {
                              await state.delete(s);
                            }
                          },
                          itemBuilder: (ctx) => [
                            PopupMenuItem(
                              value: 'toggle',
                              child: Text(s.enabled ? '禁用' : '启用'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                        onTap: () async {
                          await state.setEnabled(s, !s.enabled);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
