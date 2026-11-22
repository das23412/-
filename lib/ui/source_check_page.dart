import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/settings.dart';
import '../source/book_source.dart';
import '../source/source_service.dart';
import '../state/source_state.dart';

enum _StepStatus { running, ok, fail, unsupported }

class _StepResult {
  final _StepStatus status;
  final int ms;
  final String sample;
  final String message;
  const _StepResult(this.status, this.ms, this.sample, this.message);
}

class _SourceCheck {
  final BookSource source;
  final List<_StepResult?> steps = [null, null, null]; // 搜索 / 目录 / 正文
  bool running = false;
  _SourceCheck(this.source);
}

/// 书源检测：对每个书源跑「搜索 → 目录 → 正文」三步流水线，
/// 显示每步成败、耗时与样本内容；支持一键批量检测全部启用的书源。
class SourceCheckPage extends StatefulWidget {
  const SourceCheckPage({super.key});

  @override
  State<SourceCheckPage> createState() => _SourceCheckPageState();
}

class _SourceCheckPageState extends State<SourceCheckPage> {
  final _keywordController = TextEditingController(text: '我的');
  List<_SourceCheck> _checks = [];
  bool _running = false;
  bool _cancelled = false;
  int _gen = 0; // 检测轮次：停止后立即放行新一轮，旧 worker 凭轮次号在间隙退出

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  void _start() {
    if (_running) return;
    if (!AppSettings.instance.allowSources) {
      _snack('请先打开「允许书源联网」开关（在书源管理页）');
      return;
    }
    final keyword = _keywordController.text.trim();
    if (keyword.isEmpty) {
      _snack('请输入检测关键词');
      return;
    }
    final sources = context.read<SourceState>().enabledSources;
    if (sources.isEmpty) {
      _snack('没有启用的书源');
      return;
    }
    _cancelled = false;
    _gen++;
    final gen = _gen;
    final checks = sources.map(_SourceCheck.new).toList();
    setState(() {
      _running = true;
      _checks = checks;
    });
    // 并发上限 3：几十个源同时开 socket 会瞬间打满连接池
    var index = 0;
    Future<void> worker() async {
      // 只认本轮的 checks 列表与轮次号：停止后立刻可开新一轮，旧 worker 在间隙退出
      while (gen == _gen && !_cancelled && index < checks.length) {
        final c = checks[index];
        index++;
        c.running = true;
        _refresh();
        await _runOne(c, keyword, gen);
        c.running = false;
        _refresh();
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < 3 && i < checks.length; i++) worker(),
    ];
    unawaited(Future.wait(workers).then((_) {
      // 只有当前轮次的收尾才能关 running：停止路径已在 _stop 里立即置过
      if (mounted && gen == _gen) setState(() => _running = false);
    }));
  }

  void _stop() {
    // 立即置 _running=false：PopScope 与按钮态马上放行；
    // _cancelled 保留给 worker 在步骤间隙退出，在途结果到达后按中止丢弃不写状态。
    setState(() {
      _running = false;
      _cancelled = true;
    });
    _snack('已停止检测');
  }

  /// 本轮是否已中止：点了停止，或本轮已被新一轮检测取代。
  bool _aborted(int gen) => _cancelled || gen != _gen;

  Future<void> _runOne(_SourceCheck c, String keyword, int gen) async {
    final s = c.source;

    // 第 1 步：搜索
    var sw = Stopwatch()..start();
    List<SourceBook> books;
    try {
      books = await SourceService.search(s, keyword);
    } on SourceUnsupportedException catch (e) {
      if (!_aborted(gen)) {
        c.steps[0] = _StepResult(_StepStatus.unsupported, sw.elapsedMilliseconds, '', e.message);
        _refresh();
      }
      return;
    } catch (e) {
      if (!_aborted(gen)) {
        c.steps[0] = _StepResult(_StepStatus.fail, sw.elapsedMilliseconds, '', e.toString());
        _refresh();
      }
      return;
    }
    if (_aborted(gen)) return; // 停止后丢弃在途结果，不写状态
    c.steps[0] = _StepResult(
      _StepStatus.ok,
      sw.elapsedMilliseconds,
      '《${books.first.name}》等 ${books.length} 条结果',
      '',
    );
    _refresh();

    // 第 2 步：目录（详情页 → 目录页）
    sw.reset();
    List<SourceChapter> toc;
    try {
      final info = await SourceService.bookInfoIsolated(s, books.first);
      if (_aborted(gen)) return; // 详情回来已中止：不再发目录请求
      toc = await SourceService.loadToc(s, info.tocUrl);
    } on SourceUnsupportedException catch (e) {
      if (!_aborted(gen)) {
        c.steps[1] = _StepResult(_StepStatus.unsupported, sw.elapsedMilliseconds, '', e.message);
        _refresh();
      }
      return;
    } catch (e) {
      if (!_aborted(gen)) {
        c.steps[1] = _StepResult(_StepStatus.fail, sw.elapsedMilliseconds, '', e.toString());
        _refresh();
      }
      return;
    }
    if (_aborted(gen)) return; // 停止后丢弃在途结果，不写状态
    c.steps[1] = _StepResult(
      _StepStatus.ok,
      sw.elapsedMilliseconds,
      '共 ${toc.length} 章 · 首章：${toc.first.title}',
      '',
    );
    _refresh();

    // 第 3 步：正文（compute 隔离线程执行：书源正则不能跑 UI 线程；超时兜底防挂死）
    sw.reset();
    try {
      final content = await compute(loadContentInIsolate,
          {'raw': s.rawJson, 'url': toc.first.url}).timeout(
        const Duration(minutes: 2),
        onTimeout: () => throw SourceException('超时'),
      );
      if (_aborted(gen)) return; // 停止后丢弃在途结果，不写状态
      final sample = content.length > 60 ? content.substring(0, 60) : content;
      c.steps[2] = _StepResult(
        _StepStatus.ok,
        sw.elapsedMilliseconds,
        '${content.length} 字 · ${sample.replaceAll('\n', ' ')}…',
        '',
      );
      _refresh();
    } on SourceUnsupportedException catch (e) {
      if (!_aborted(gen)) {
        c.steps[2] = _StepResult(_StepStatus.unsupported, sw.elapsedMilliseconds, '', e.message);
        _refresh();
      }
    } catch (e) {
      if (!_aborted(gen)) {
        c.steps[2] = _StepResult(_StepStatus.fail, sw.elapsedMilliseconds, '', e.toString());
        _refresh();
      }
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      child: Scaffold(
        appBar: AppBar(title: const Text('书源检测')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _keywordController,
                      enabled: !_running,
                      decoration: const InputDecoration(
                        hintText: '检测关键词（用常见词更容易命中）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_running)
                    OutlinedButton.icon(
                      onPressed: _stop,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('停止'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _start,
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: const Text('批量检测'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _checks.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.fact_check_outlined,
                              size: 64, color: Theme.of(context).hintColor),
                          const SizedBox(height: 12),
                          const Text('对每个书源依次检测搜索、目录、正文三个环节，'),
                          const Text('全部通过的书源才能正常阅读。',
                              style: TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: _checks.length,
                      itemBuilder: (ctx, i) => _checkTile(_checks[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _checkTile(_SourceCheck c) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (c.running)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    _sourceIcon(c),
                    size: 18,
                    color: _sourceColor(c),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(c.source.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (int i = 0; i < c.steps.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  _stepChip(const ['搜索', '目录', '正文'][i], c.steps[i], theme),
                ],
              ],
            ),
            for (int i = 0; i < c.steps.length; i++)
              if (c.steps[i] != null &&
                  (c.steps[i]!.sample.isNotEmpty ||
                      c.steps[i]!.message.isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${['搜索', '目录', '正文'][i]}：'
                    '${c.steps[i]!.message.isNotEmpty ? c.steps[i]!.message : c.steps[i]!.sample}'
                    '（${c.steps[i]!.ms}ms）',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: c.steps[i]!.status == _StepStatus.fail ||
                                c.steps[i]!.status == _StepStatus.unsupported
                            ? theme.colorScheme.error
                            : theme.hintColor),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  IconData _sourceIcon(_SourceCheck c) {
    final allOk = c.steps.every((s) => s?.status == _StepStatus.ok);
    if (allOk) return Icons.check_circle;
    final anyFail =
        c.steps.any((s) => s != null && s.status != _StepStatus.ok);
    if (anyFail) return Icons.error_outline;
    return Icons.help_outline;
  }

  Color _sourceColor(_SourceCheck c) {
    final allOk = c.steps.every((s) => s?.status == _StepStatus.ok);
    if (allOk) return Colors.green.shade600;
    final anyFail =
        c.steps.any((s) => s != null && s.status != _StepStatus.ok);
    if (anyFail) return Theme.of(context).colorScheme.error;
    return Theme.of(context).hintColor;
  }

  Widget _stepChip(String label, _StepResult? r, ThemeData theme) {
    final color = switch (r?.status) {
      _StepStatus.ok => Colors.green.shade600,
      _StepStatus.fail => theme.colorScheme.error,
      _StepStatus.unsupported => Colors.orange.shade700,
      _StepStatus.running => theme.colorScheme.primary,
      _ => theme.disabledColor,
    };
    final bg = switch (r?.status) {
      _StepStatus.ok => Colors.green.shade50,
      _StepStatus.fail => theme.colorScheme.errorContainer,
      _StepStatus.unsupported => Colors.orange.shade50,
      _StepStatus.running => theme.colorScheme.primaryContainer,
      _ => theme.colorScheme.surfaceContainerHighest,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11.5, color: color,
              fontWeight: FontWeight.bold)),
    );
  }
}
