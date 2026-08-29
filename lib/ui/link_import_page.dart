import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/settings.dart';
import '../services/download_service.dart';
import '../state/library_state.dart';
import 'common.dart';

/// 从链接导入：粘贴文件直链 → 确认 → 下载 → 入书架。
class LinkImportPage extends StatefulWidget {
  const LinkImportPage({super.key});

  @override
  State<LinkImportPage> createState() => _LinkImportPageState();
}

enum _Phase { idle, downloading }

class _LinkImportPageState extends State<LinkImportPage> {
  final _urlController = TextEditingController();
  bool _allowNetwork = false;
  bool _busy = false; // 探测或下载中
  int _received = 0;
  int _total = -1; // -1 = 未知大小

  @override
  void initState() {
    super.initState();
    _allowNetwork = AppSettings.instance.allowNetworkDownload;
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _toggleNetwork(bool v) async {
    setState(() => _allowNetwork = v);
    AppSettings.instance.allowNetworkDownload = v;
  }

  Future<void> _paste() async {
    final text = await Clipboard.getData('text/plain');
    if (text?.text != null && text!.text!.trim().isNotEmpty) {
      _urlController.text = text.text!.trim();
      setState(() {});
    }
  }

  Future<void> _startImport() async {
    if (_busy) return;
    final lib = context.read<LibraryState>();
    final url = _urlController.text.trim();

    if (!_allowNetwork) {
      _snack('请先打开「允许联网下载」开关');
      return;
    }
    if (DownloadService.tryParseUrl(url) == null) {
      _snack('请输入有效的文件直链');
      return;
    }

    // 1. 预检：拿文件名与大小
    setState(() => _busy = true);
    String filename;
    int size;
    try {
      (filename, size) = await DownloadService.probe(url);
    } on DownloadException catch (e) {
      setState(() => _busy = false);
      _snack(e.message);
      return;
    } catch (e) {
      setState(() => _busy = false);
      _snack('链接探测失败：$e');
      return;
    }
    setState(() => _busy = false);

    // 2. 确认框
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认下载'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件：$filename'),
            const SizedBox(height: 6),
            Text(size >= 0 ? '大小：${formatBytes(size)}' : '大小：未知'),
            const SizedBox(height: 6),
            Text(
              '若正在使用移动流量，将消耗相应流量。',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(ctx).hintColor),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始下载')),
        ],
      ),
    );
    if (confirmed != true) return;

    // 3. 下载
    setState(() {
      _busy = true;
      _phase = _Phase.downloading;
      _received = 0;
      _total = size;
    });
    try {
      final dir = await lib.importDirectory();
      final file = await DownloadService.download(
        url,
        dir,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      final book = await lib.registerDownloadedFile(file.path);
      if (!mounted) return;
      _snack('已加入书架：《${book.title}》');
      Navigator.pop(context);
    } on DownloadException catch (e) {
      setState(() => _busy = false);
      _snack(e.message);
    } catch (e) {
      setState(() => _busy = false);
      _snack('下载失败：$e');
    }
  }

  _Phase _phase = _Phase.idle;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  String _progressText() {
    if (_total >= 0) {
      return '${formatBytes(_received)} / ${formatBytes(_total)}';
    }
    return formatBytes(_received);
  }

  @override
  Widget build(BuildContext context) {
    final double? progress =
        _phase == _Phase.downloading && _total >= 0 && _total > 0
            ? (_received / _total).clamp(0.0, 1.0)
            : null;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('从链接导入')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 联网开关
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SwitchListTile(
                value: _allowNetwork,
                onChanged: _busy ? null : (v) => _toggleNetwork(v),
                title: const Text('允许联网下载'),
                subtitle: const Text('默认关闭。关闭时墨阅不发起任何网络请求；'
                    '打开后也只在你点击下载时访问该链接。'),
              ),
            ),
            const SizedBox(height: 16),
            // 链接输入
            TextField(
              controller: _urlController,
              enabled: !_busy,
              maxLines: 2,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: '文件直链',
                hintText: 'https://…/小说名.txt',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste),
                  tooltip: '粘贴',
                  onPressed: _busy ? null : _paste,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '什么是直链：把链接发给浏览器打开就会直接开始下载（或显示文件内容），'
              '这样的才是直链。网盘的分享页面链接（需要点按钮、输提取码的）暂不支持。',
              style: TextStyle(
                  fontSize: 12, color: Theme.of(context).hintColor, height: 1.5),
            ),
            const SizedBox(height: 20),
            // 进度
            if (_phase == _Phase.downloading) ...[
              Text(_progressText(), style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              const Text('下载中，请保持应用在前台…',
                  style: TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
            ],
            // 按钮
            FilledButton.icon(
              onPressed: _busy ? null : _startImport,
              icon: const Icon(Icons.download),
              label: Text(_phase == _Phase.downloading ? '下载中…' : '开始下载'),
            ),
            const SizedBox(height: 24),
            const Divider(),
            // 使用说明
            const Text('如何获得直链？', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            const Text(
              '1. 把小说文件上传到能生成“直接下载地址”的网盘或你自己的空间\n'
              '2. 复制文件的直接下载地址（而不是网页分享页）\n'
              '3. 把链接发给朋友，或自己粘贴到这里导入\n\n'
              '分享者也可随时在网盘里删除/改名文件来收回分享。',
              style: TextStyle(fontSize: 13, height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
