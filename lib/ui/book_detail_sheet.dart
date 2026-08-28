import 'package:flutter/material.dart';

import '../data/book.dart';
import '../state/library_state.dart';
import 'common.dart';

/// 书籍详情：信息 + 重命名 / 标签 / 置顶 / 删除。
class BookDetailSheet extends StatefulWidget {
  final Book book;
  final LibraryState library;
  const BookDetailSheet({super.key, required this.book, required this.library});

  @override
  State<BookDetailSheet> createState() => _BookDetailSheetState();
}

class _BookDetailSheetState extends State<BookDetailSheet> {
  Future<void> _rename() async {
    final controller = TextEditingController(text: widget.book.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新的书名'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok == true && controller.text.trim().isNotEmpty) {
      await widget.library.rename(widget.book, controller.text);
    }
  }

  Future<void> _editTags() async {
    final all = (await widget.library.allTags()).toList()..sort();
    final selected = widget.book.tagList.toSet();
    if (!mounted) return;
    final customController = TextEditingController();
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
              left: 16, right: 16, top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('标签管理', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final t in all)
                    FilterChip(
                      label: Text(t),
                      selected: selected.contains(t),
                      onSelected: (v) => setSheet(() {
                        v ? selected.add(t) : selected.remove(t);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: customController,
                      decoration: const InputDecoration(
                          hintText: '新建标签', isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      final t = customController.text.trim();
                      if (t.isEmpty) return;
                      setSheet(() {
                        selected.add(t);
                        if (!all.contains(t)) all.add(t);
                      });
                    },
                    child: const Text('添加'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, selected.toList()),
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) {
      await widget.library.setTags(widget.book, result);
    }
  }

  Future<void> _delete() async {
    if (widget.book.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text(widget.book.imported
            ? '将从书架删除《${widget.book.title}》及其导入副本，无法恢复。'
            : '将从书架移除《${widget.book.title}》，原文件仍保留在手机里。'),
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
      await widget.library.deleteByIds([widget.book.id!],
          deleteFiles: widget.book.imported);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.book;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56, height: 76,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Colors.teal.shade300, Colors.teal.shade600],
                  ),
                ),
                child: Text(b.format.displayName,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(b.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text('阅读进度 ${b.percent.toStringAsFixed(1)}%',
                        style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _row('格式', '${b.format.displayName} · ${formatBytes(b.sizeBytes)}'),
          _row('章节', b.chapterCount > 0 ? '${b.chapterCount} 章' : '未解析'),
          _row('字数', b.wordCount > 0 ? '${_fmtNum(b.wordCount)} 字' : '未解析'),
          _row('添加时间', formatTimeCN(b.addedAt)),
          _row('最近阅读', formatTimeCN(b.lastReadAt)),
          if (b.tags.isNotEmpty) _row('标签', b.tagList.join('、')),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _action(Icons.edit_outlined, '重命名', _rename),
              _action(Icons.label_outline, '标签', _editTags),
              _action(Icons.push_pin_outlined, b.pinned ? '取消置顶' : '置顶',
                  () => widget.library.togglePin(b)),
              _action(Icons.delete_outline, '删除', _delete, danger: true),
            ],
          ),
        ],
      ),
    );
  }

  String _fmtNum(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    return '$n';
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 72, child: Text(label, style: TextStyle(color: Theme.of(context).hintColor))),
            Expanded(child: Text(value)),
          ],
        ),
      );

  Widget _action(IconData icon, String label, VoidCallback onTap,
      {bool danger = false}) {
    final color = danger ? Colors.red : null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ],
        ),
      ),
    );
  }
}
