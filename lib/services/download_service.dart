import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/book_format.dart';

/// 下载失败时的友好异常。
class DownloadException implements Exception {
  final String message;
  const DownloadException(this.message);
  @override
  String toString() => message;
}

/// 直链下载服务。
///
/// 设计约定：仅处理“打开就是文件本身”的直链；分享页/网盘页面链接不支持。
class DownloadService {
  static const userAgent =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  static const int maxBytes = 500 * 1024 * 1024; // 500MB 上限

  /// 解析用户输入为 Uri。无协议时默认补 https://；仅接受 http/https。
  static Uri? tryParseUrl(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return null;
    final withScheme = raw.contains('://') ? raw : 'https://$raw';
    final uri = Uri.tryParse(withScheme);
    if (uri == null) return null;
    if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
    if (uri.host.isEmpty) return null;
    return uri;
  }

  /// 从响应头 / URL 推断文件名（纯函数，可单测）。
  static String extractFilename({
    Map<String, String>? headers,
    required Uri uri,
  }) {
    final cd = headers?['content-disposition'] ?? headers?['Content-Disposition'];
    String? name;
    if (cd != null) {
      name = _fromContentDisposition(cd);
    }
    name ??= _fromUriPath(uri);
    if (name == null || name.isEmpty) name = 'download_${DateTime.now().millisecondsSinceEpoch}';
    return _sanitize(name);
  }

  /// 解析 Content-Disposition（含 RFC 5987 filename*= 与普通 filename=）。
  static String? _fromContentDisposition(String cd) {
    // filename*=UTF-8''%E6%96%87.txt
    final star = RegExp(
            r"filename\*\s*=\s*(?:([\w-]+)'')?([^;]+)",
            caseSensitive: false)
        .firstMatch(cd);
    if (star != null) {
      final charset = star.group(1)?.toUpperCase() ?? 'UTF-8';
      var value = star.group(2)!.trim().replaceAll('"', '');
      if (charset == 'UTF-8') {
        value = Uri.decodeComponent(value);
      }
      if (value.isNotEmpty) return value;
    }
    // filename="xxx.txt" / filename=xxx.txt
    final plain =
        RegExp(r'filename\s*=\s*"?([^";]+)"?', caseSensitive: false).firstMatch(cd);
    if (plain != null) {
      final value = plain.group(1)!.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static String? _fromUriPath(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final last = segments.last;
    try {
      return Uri.decodeComponent(last);
    } on ArgumentError {
      return last;
    }
  }

  /// 去掉文件名里的非法字符。
  static String _sanitize(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned;
  }

  /// 预检链接：只读响应头，返回文件名与大小（size 为 -1 表示未知）。
  static Future<(String filename, int size)> probe(String urlStr) async {
    final uri = _mustParse(urlStr);
    final client = HttpClient();
    try {
      client.userAgent = userAgent;
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode == 404) {
        throw const DownloadException('链接不存在（404），请确认是否失效');
      }
      if (resp.statusCode != 200) {
        throw DownloadException('服务器返回 ${resp.statusCode}，请确认这是文件直链而非网页');
      }
      final headers = <String, String>{};
      resp.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join('; '));
      final filename = extractFilename(headers: headers, uri: uri);
      final format = BookFormat.fromPath(filename);
      if (format == BookFormat.unknown) {
        throw const DownloadException('该链接不是支持的小说文件（需要 .txt/.epub/.mobi/.azw3/.fb2/.html 直链）');
      }
      final size = resp.contentLength;
      return (filename, size);
    } on TimeoutException {
      throw const DownloadException('连接超时，请检查链接或网络');
    } on SocketException {
      throw const DownloadException('网络连接失败，请检查网络或链接');
    } on HandshakeException {
      throw const DownloadException('HTTPS 证书异常，无法建立安全连接');
    } finally {
      client.close(force: true);
    }
  }

  /// 下载到 [destDir]，先写临时 .part 文件，成功后改名为最终文件。
  static Future<File> download(
    String urlStr,
    Directory destDir, {
    void Function(int received, int total)? onProgress,
  }) async {
    final uri = _mustParse(urlStr);
    if (!destDir.existsSync()) destDir.createSync(recursive: true);
    final client = HttpClient();
    File? tmp;
    try {
      client.userAgent = userAgent;
      final req = await client.getUrl(uri);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        throw DownloadException('服务器返回 ${resp.statusCode}，请确认这是文件直链而非网页');
      }
      final headers = <String, String>{};
      resp.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join('; '));
      final filename = extractFilename(headers: headers, uri: uri);
      if (BookFormat.fromPath(filename) == BookFormat.unknown) {
        throw const DownloadException('该链接不是支持的小说文件');
      }
      final total = resp.contentLength;
      if (total > maxBytes) {
        throw const DownloadException('文件超过 500MB 上限');
      }
      tmp = File(p.join(destDir.path, '$filename.part'));
      if (tmp.existsSync()) tmp.deleteSync();
      final sink = tmp.openWrite();
      int received = 0;
      try {
        await for (final chunk in resp) {
          received += chunk.length;
          if (received > maxBytes) {
            throw const DownloadException('文件超过 500MB 上限');
          }
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
      if (received == 0) {
        if (tmp.existsSync()) tmp.deleteSync();
        throw const DownloadException('服务器没有返回任何内容，请确认链接有效性');
      }
      // 避免覆盖已有文件
      var finalPath = p.join(destDir.path, filename);
      if (File(finalPath).existsSync()) {
        final ext = p.extension(filename);
        final base = p.basenameWithoutExtension(filename);
        finalPath = p.join(
            destDir.path,
            '${base}_${DateTime.now().millisecondsSinceEpoch}$ext');
      }
      tmp.renameSync(finalPath);
      tmp = null;
      return File(finalPath);
    } on TimeoutException {
      throw const DownloadException('连接超时，请检查链接或网络');
    } on SocketException {
      throw const DownloadException('网络连接失败，请检查网络或链接');
    } on HandshakeException {
      throw const DownloadException('HTTPS 证书异常，无法建立安全连接');
    } finally {
      client.close(force: true);
      if (tmp != null && tmp.existsSync()) tmp.deleteSync();
    }
  }

  static Uri _mustParse(String urlStr) {
    final uri = tryParseUrl(urlStr);
    if (uri == null) {
      throw const DownloadException('链接格式不正确');
    }
    return uri;
  }
}
