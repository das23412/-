import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 检查更新失败时的友好异常。
class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

/// 一个可用的新版本。
class UpdateInfo {
  final String version;
  final String downloadUrl;
  final int size;
  final String? releaseNotes;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.size,
    this.releaseNotes,
  });
}

/// 通过 GitHub Releases 检查与下载新版本。
///
/// 发布链路：推送 v* 标签 → Actions 打包并自动创建 Release（APK 为公开附件）。
class UpdateService {
  static const latestReleaseUrl =
      'https://api.github.com/repos/das23412/-/releases/latest';
  static const int maxBytes = 500 * 1024 * 1024;

  /// 去掉标签前缀的 v/V。
  static String normalizeVersion(String tag) =>
      tag.trim().replaceFirst(RegExp(r'^[vV]\s*'), '');

  /// 语义化版本比较：a > b 返回 1，相等 0，a < b 返回 -1。
  static int compareVersions(String a, String b) {
    List<int> parse(String s) => s
        .split('.')
        .map((e) => int.tryParse(e.trim()) ?? 0)
        .toList();
    final pa = parse(a);
    final pb = parse(b);
    for (var i = 0; i < 3; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y ? 1 : -1;
    }
    return 0;
  }

  /// 检查最新版本。返回 null 表示已是最新；失败抛 [UpdateException]。
  static Future<UpdateInfo?> checkLatest(String currentVersion) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(latestReleaseUrl));
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode == 404) {
        throw const UpdateException('还没有发布过任何版本（仓库无 Release）');
      }
      if (resp.statusCode != 200) {
        throw UpdateException('检查失败：HTTP ${resp.statusCode}（网络可能不稳定，稍后再试）');
      }
      final body = await resp.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?) ?? '';
      final latest = normalizeVersion(tag);
      if (latest.isEmpty) {
        throw const UpdateException('最新 Release 缺少版本标签');
      }
      if (compareVersions(latest, currentVersion) <= 0) return null;
      final assets =
          (json['assets'] as List? ?? []).cast<Map<String, dynamic>>();
      Map<String, dynamic>? apk;
      for (final a in assets) {
        if ((a['name'] as String? ?? '').toLowerCase().endsWith('.apk')) {
          apk = a;
          break;
        }
      }
      if (apk == null) {
        throw const UpdateException('最新版本没有附带 APK 文件');
      }
      return UpdateInfo(
        version: latest,
        downloadUrl: apk['browser_download_url'] as String,
        size: (apk['size'] as num?)?.toInt() ?? -1,
        releaseNotes: (json['body'] as String?)?.trim(),
      );
    } on TimeoutException {
      throw const UpdateException('连接超时（GitHub 访问不稳定，稍后再试）');
    } on SocketException {
      throw const UpdateException('网络连接失败，请检查网络');
    } on FormatException {
      throw const UpdateException('返回数据异常，稍后再试');
    } finally {
      client.close(force: true);
    }
  }

  /// 下载新版 APK 到应用私有目录，返回文件路径。
  static Future<String> downloadApk(
    String url,
    String version, {
    void Function(int received, int total)? onProgress,
  }) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'updates'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final dest = p.join(dir.path, 'moyue_v$version.apk');

    final client = HttpClient();
    File? tmp;
    try {
      client.userAgent =
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36';
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw UpdateException('下载失败：HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      if (total > maxBytes) throw const UpdateException('安装包超过 500MB 上限');
      tmp = File('$dest.part');
      if (tmp.existsSync()) tmp.deleteSync();
      final sink = tmp.openWrite();
      int received = 0;
      try {
        await for (final chunk in resp) {
          received += chunk.length;
          if (received > maxBytes) throw const UpdateException('安装包超过 500MB 上限');
          sink.add(chunk);
          onProgress?.call(received, total);
        }
        await sink.flush();
        await sink.close();
      } catch (e) {
        try {
          await sink.close();
        } catch (_) {}
        if (tmp.existsSync()) tmp.deleteSync();
        rethrow;
      }
      if (received == 0) throw const UpdateException('服务器没有返回内容');
      if (File(dest).existsSync()) File(dest).deleteSync();
      tmp.renameSync(dest);
      tmp = null;
      return dest;
    } on TimeoutException {
      throw const UpdateException('下载超时（GitHub 访问不稳定，稍后再试）');
    } on SocketException {
      throw const UpdateException('网络连接失败，请检查网络');
    } finally {
      client.close(force: true);
      if (tmp != null && tmp.existsSync()) tmp.deleteSync();
    }
  }
}
