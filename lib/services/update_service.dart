import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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

  /// 官方发布资产的 sha256（GitHub Release 自带），用于下载后校验；
  /// 为空表示无法校验（直接跳过而不是拒绝更新）。
  final String sha256;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.size,
    this.releaseNotes,
    this.sha256 = '',
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

  /// 语义化版本比较：a > b 返回 1，相等 0，a < b -1。
  /// 忽略 pre-release 后缀（1.2.1-beta 按 1.2.1 参与比较）与构建号；
  /// pre-release 不推送给正式用户，beta 用户升级正式版视为升级。
  static int compareVersions(String a, String b) {
    List<int> parse(String s) => s
        .split('-')[0]
        .split('+')[0]
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

  /// GitHub 资产 digest（"sha256:xxx"）归一化为十六进制串。
  static String normalizeDigest(String raw) =>
      raw.startsWith('sha256:') ? raw.substring(7) : raw;

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
      final downloadUrl = (apk['browser_download_url'] as String?) ?? '';
      if (downloadUrl.isEmpty) {
        throw const UpdateException('Release 数据异常（缺少下载地址）');
      }
      // 只允许官方 Release 附件地址，防止 Release 数据被篡改后指向外部
      if (!downloadUrl.startsWith('https://github.com/') &&
          !downloadUrl.startsWith('https://objects.githubusercontent.com/')) {
        throw const UpdateException('下载地址非官方来源，已阻止');
      }
      return UpdateInfo(
        version: latest,
        downloadUrl: downloadUrl,
        size: (apk['size'] as num?)?.toInt() ?? -1,
        releaseNotes: (json['body'] as String?)?.trim(),
        sha256: normalizeDigest((apk['digest'] as String?) ?? ''),
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
  /// 提供 [expectedSha256] 时（GitHub Release 资产的 digest）下载完成后校验，
  /// 不匹配则删除临时文件并抛出异常，避免安装被篡改的包。
  static Future<String> downloadApk(
    String url,
    String version, {
    void Function(int received, int total)? onProgress,
    String? expectedSha256,
  }) async {
    // 版本号可能来自 tag（理论可含 / 等非法字符），净化出安全文件名
    final safeVersion = version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'updates'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final dest = p.join(dir.path, 'moyue_v$safeVersion.apk');
    // 清理历史版本的安装包与中断残留（每个 APK 数十 MB，不清理会永久占空间）
    for (final old in dir.listSync()) {
      if (old.path == dest) continue;
      try {
        old.deleteSync();
      } catch (_) {}
    }

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
        // 响应体逐块超时：服务器中途停滞不会永久挂起
        await for (final chunk in resp.timeout(const Duration(seconds: 30))) {
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
      if (expectedSha256 != null && expectedSha256.isNotEmpty) {
        final actual = await sha256.bind(tmp.openRead()).first;
        if (actual.toString() != expectedSha256.toLowerCase()) {
          throw const UpdateException('安装包校验失败，与官方发布不一致，请稍后重试');
        }
      }
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
