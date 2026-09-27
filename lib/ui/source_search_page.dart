import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/settings.dart';
import '../source/source_service.dart';
import '../state/library_state.dart';
import '../state/source_state.dart';
import 'reader_page.dart';

/// 聚合后的搜索结果：同名同作者的多个来源归为一组。
class _AggregatedBook {
  final String name;
  final String author;
  final List<SourceBook> matches = [];

  _AggregatedBook(SourceBook first)
      : name = first.name,
        author = first.author {
    matches.add(first);
  }

  String get intro {
    for (final m in matches) {
      if (m.intro.isNotEmpty) return m.intro;
    }
    return '';
  }

  String get lastChapter {
    for (final m in matches) {
      if (m.lastChapter.isNotEmpty) return m.lastChapter;
    }
    return '';
  }
}

/// 多源搜索：并发搜索全部启用书源，按书名+作者聚合。
class SourceSearchPage extends StatefulWidget {
  const SourceSearchPage({super.key});

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  final _keywordController = TextEditingController(text: '我的');
  bool _searching = false;
  List<_AggregatedBook> _results = [];
  int _failedCount = 0;
  String _statusText = '';

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  Future<void> _toggleNetwork(bool v) async {
    AppSettings.instance.allowSources = v;
    setState(() {});
  }

  Future<void> _search() async {
    if (_searching) return;
    final keyword = _keywordController.text.trim();
    if (keyword.isEmpty) {
      _snack('请输入书名或作者');
      return;
    }
    final sources = context.read<SourceState>().enabledSources;
    if (sources.isEmpty) {
      _snack('还没有启用任何书源，请先在书源管理中导入并启用');
      return;
    }
    setState(() {
      _searching = true;
      _results = [];
      _failedCount = 0;
      _statusText = '正在搜索 ${sources.length} 个书源…';
    });
    try {
      final (books, errors) = await SourceService.searchAll(sources, keyword);
      final grouped = <String, _AggregatedBook>{};
      for (final b in books) {
        final key = b.groupKey;
        grouped.putIfAbsent(key, () => _AggregatedBook(b)).matches.add(b);
      }
      final list = grouped.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() {
        _results = list;
        _failedCount = errors.length;
        _statusText = list.isEmpty
            ? '没有找到相关书籍'
            : '找到 ${list.length} 本（${_failedCount == 0 ? '全部书源成功' : '$_failedCount 个源失败或不支持'}）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusText = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 选中某个具体来源：加入书架并打开阅读。
  Future<void> _openSource(SourceBook sb) async {
    final lib = context.read<LibraryState>();
    _snack('正在获取书籍信息…');
    final book = await lib.addOnlineBook(sb);
    if (!mounted) return;
    if (book == null) {
      _snack('加入书架失败，请稍后重试');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderPage(book: book)),
    );
  }

  void _showSourcePicker(_AggregatedBook agg) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('《${agg.name}》· ${agg.matches.length} 个来源',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            for (final m in agg.matches)
              ListTile(
                title: Text(m.sourceName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  m.lastChapter.isEmpty ? m.sourceId : '最新：${m.lastChapter}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  _openSource(m);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_searching,
      child: Scaffold(
        appBar: AppBar(title: const Text('书源搜索')),
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
                onChanged: _searching ? null : _toggleNetwork,
                title: const Text('允许书源联网'),
                subtitle: const Text('默认关闭。关闭时不发起任何网络请求。'),
              ),
            ),
            // 搜索框
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _keywordController,
                      enabled: !_searching,
                      onSubmitted: (_) => _search(),
                      decoration: const InputDecoration(
                        hintText: '输入书名或作者',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed:
                        (!AppSettings.instance.allowSources || _searching)
                            ? null
                            : _search,
                    icon: _searching
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search, size: 18),
                    label: const Text('搜索'),
                  ),
                ],
              ),
            ),
            if (_statusText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(_statusText,
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).hintColor)),
                ),
              ),
            Expanded(
              child: _results.isEmpty
                  ? const SizedBox.shrink()
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 4, bottom: 24),
                      itemCount: _results.length,
                      itemBuilder: (ctx, i) {
                        final agg = _results[i];
                        return ListTile(
                          title: Text(agg.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (agg.author.isNotEmpty)
                                Text('作者：${agg.author}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12)),
                              if (agg.intro.isNotEmpty)
                                Text(agg.intro,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12)),
                              Text(
                                '${agg.matches.length} 个来源'
                                '${agg.lastChapter.isEmpty ? '' : ' · 最新：${agg.lastChapter}'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(context).colorScheme.primary),
                              ),
                            ],
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _showSourcePicker(agg),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
