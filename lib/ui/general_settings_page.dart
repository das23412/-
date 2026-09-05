import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../data/settings.dart';
import '../platform/install_channel.dart';
import '../services/update_service.dart';
import 'common.dart';

/// 通用设置页：联网开关、版本与更新。
class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

enum _UpdateState { idle, checking, none, available, downloading, done }

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  bool _allowNetwork = false;
  _UpdateState _updateState = _UpdateState.idle;
  UpdateInfo? _update;
  String? _error;
  int _received = 0;
  int _total = -1;
  String? _apkPath;

  @override
  void initState() {
    super.initState();
    _allowNetwork = AppSettings.instance.allowNetworkDownload;
  }

  Future<void> _toggleNetwork(bool v) async {
    setState(() => _allowNetwork = v);
    AppSettings.instance.allowNetworkDownload = v;
  }

  Future<void> _checkUpdate() async {
    setState(() {
      _updateState = _UpdateState.checking;
      _error = null;
    });
    try {
      final info = await UpdateService.checkLatest(AppInfo.version);
      setState(() {
        if (info == null) {
          _updateState = _UpdateState.none;
        } else {
          _update = info;
          _updateState = _UpdateState.available;
        }
      });
    } on UpdateException catch (e) {
      setState(() {
        _error = e.message;
        _updateState = _UpdateState.idle;
      });
    } catch (e) {
      setState(() {
        _error = '检查失败：$e';
        _updateState = _UpdateState.idle;
      });
    }
  }

  Future<void> _downloadUpdate() async {
    final info = _update;
    if (info == null) return;
    setState(() {
      _updateState = _UpdateState.downloading;
      _received = 0;
      _total = info.size;
      _error = null;
    });
    try {
      final path = await UpdateService.downloadApk(
        info.downloadUrl,
        info.version,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      setState(() {
        _apkPath = path;
        _updateState = _UpdateState.done;
      });
    } on UpdateException catch (e) {
      setState(() {
        _error = e.message;
        _updateState = _UpdateState.available;
      });
    } catch (e) {
      setState(() {
        _error = '下载失败：$e';
        _updateState = _UpdateState.available;
      });
    }
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) return;
    final err = await InstallChannel.installApk(path);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$err（若为首次安装更新，请在系统设置中允许墨阅“安装未知应用”）')));
    }
  }

  String _progressText() {
    if (_total >= 0) {
      return '${formatBytes(_received)} / ${formatBytes(_total)}';
    }
    return formatBytes(_received);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通用设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 联网
          Card(
            child: SwitchListTile(
              value: _allowNetwork,
              onChanged: (v) => _toggleNetwork(v),
              title: const Text('允许联网下载'),
              subtitle: const Text('用于「从链接导入」。默认关闭，关闭时应用不发起任何网络请求。'),
            ),
          ),
          const SizedBox(height: 16),
          // 版本与更新
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('版本与更新',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text('当前 v${AppInfo.version}（${AppInfo.build}）',
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_updateState == _UpdateState.checking)
                    const Row(
                      children: [
                        SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text('正在检查更新…'),
                      ],
                    ),
                  if (_updateState == _UpdateState.idle && _error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  if (_updateState == _UpdateState.none)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('✓ 已是最新版本'),
                    ),
                  if (_updateState == _UpdateState.available && _update != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '发现新版本 v${_update!.version}'
                            '${_update!.size >= 0 ? '（${formatBytes(_update!.size)}）' : ''}',
                            style: const TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.bold),
                          ),
                          if (_update!.releaseNotes?.isNotEmpty == true)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                _update!.releaseNotes!,
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).hintColor),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (_updateState == _UpdateState.downloading) ...[
                    Text(_progressText(), style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                        value: _total >= 0
                            ? (_received / _total).clamp(0.0, 1.0)
                            : null),
                    const SizedBox(height: 8),
                  ],
                  if (_updateState == _UpdateState.done)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('下载完成，点击下方按钮安装（签名一致，可直接覆盖升级）'),
                    ),
                  Row(
                    children: [
                      if (_updateState == _UpdateState.idle ||
                          _updateState == _UpdateState.none ||
                          _updateState == _UpdateState.checking)
                        FilledButton.icon(
                          onPressed:
                              _updateState == _UpdateState.checking
                                  ? null
                                  : _checkUpdate,
                          icon: const Icon(Icons.system_update_alt, size: 18),
                          label: const Text('检查更新'),
                        ),
                      if (_updateState == _UpdateState.available)
                        FilledButton.icon(
                          onPressed: _downloadUpdate,
                          icon: const Icon(Icons.download, size: 18),
                          label: const Text('下载更新'),
                        ),
                      if (_updateState == _UpdateState.done) ...[
                        FilledButton.icon(
                          onPressed: _install,
                          icon: const Icon(Icons.install_mobile, size: 18),
                          label: const Text('立即安装'),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton(
                          onPressed: _checkUpdate,
                          child: const Text('重新检查'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '更新通过 GitHub Releases 分发，国内网络偶有不稳定，失败可稍后重试。',
                    style: TextStyle(
                        fontSize: 11.5, color: Theme.of(context).hintColor),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
