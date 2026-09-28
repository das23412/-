import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/charset.dart';

/// 书源 HTTP 响应。
class SourceHttpResponse {
  final String body;
  final String finalUrl; // 重定向后的最终地址（相对路径解析基准）
  final bool isJson;

  const SourceHttpResponse(this.body, this.finalUrl, this.isJson);
}

/// 书源网络层：GET/POST、自定义头、编码识别（GBK 站点常见）。
/// 使用进程级共享 HttpClient（连接复用），不要 close 它。
class SourceHttp {
  static const defaultUa =
      'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  static const maxBytes = 8 * 1024 * 1024; // 单次响应 8MB 上限

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  static Future<SourceHttpResponse> request(
    String url, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
    String? charset,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      throw const HttpException('书源 URL 格式不正确');
    }
    final client = _client;
    try {
      final HttpClientRequest req;
      if (method.toUpperCase() == 'POST') {
        req = await client.postUrl(uri);
      } else {
        req = await client.getUrl(uri);
      }
      // UA 按请求设置在请求头上：共享 client 的 client.userAgent 是全局的，
      // 并发时自定义 UA 会串到其他源的在途请求
      final ua = headers['User-Agent'] ?? headers['user-agent'] ?? defaultUa;
      req.headers.set('User-Agent', ua);
      headers.forEach((k, v) {
        if (k.toLowerCase() != 'user-agent') req.headers.set(k, v);
      });
      if (body != null && method.toUpperCase() == 'POST') {
        req.write(body);
      }
      final resp = await req.close().timeout(timeout);
      // 404/反爬拦截页不应被宽泛的书源规则解析成"章节列表"
      if (resp.statusCode >= 400) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      // BytesBuilder 增量累积（旧写法 bytes.addAll 是 O(n²) 拷贝）；
      // stream.timeout 让响应体的每个间隔也受超时约束，慢速站点不会挂死阅读页
      final builder = BytesBuilder(copy: false);
      try {
        await for (final chunk in resp.timeout(timeout)) {
          builder.add(chunk);
          if (builder.length > maxBytes) {
            // 抛出前主动断开连接，避免超限连接回到空闲池被复用
            resp.detachSocket();
            throw const HttpException('响应超过 8MB 上限');
          }
        }
      } on TimeoutException {
        resp.detachSocket();
        throw const HttpException('书源响应超时');
      }
      final bytes = builder.takeBytes();
      final contentType = resp.headers.value('content-type') ?? '';
      var effectiveCharset = charset ?? _charsetFromContentType(contentType);
      var text = _decode(bytes, effectiveCharset);
      // 无 charset 头时嗅探 HTML meta 标签（GBK 站点常见只写 meta 不写头）：
      // 声明了 GBK 就用声明编码重解（meta 之前的字节解码错位可接受）
      if (effectiveCharset == null && !contentType.contains('json')) {
        final head = text.length > 2048 ? text.substring(0, 2048) : text;
        final m = RegExp(
                r"<meta[^>]+charset=[\"']?\s*([\w-]+)",
                caseSensitive: false)
            .firstMatch(head);
        if (m != null) {
          final declared = m.group(1)!.toLowerCase();
          if (declared.contains('gb')) {
            text = _decode(bytes, declared);
          }
        }
      }
      final isJson = contentType.contains('json') ||
          text.trimLeft().startsWith('{') ||
          text.trimLeft().startsWith('[');
      final finalUrl = resp.redirects.isNotEmpty
          ? resp.redirects.last.location.toString()
          : url;
      return SourceHttpResponse(text, finalUrl, isJson);
    } on TimeoutException {
      throw const HttpException('书源请求超时');
    } on SocketException {
      throw const HttpException('网络连接失败');
    }
  }

  static String? _charsetFromContentType(String contentType) {
    // 值可能带引号：charset="gbk"
    final m = RegExp(
            r'charset=\s*"?([\w-]+)"?',
            caseSensitive: false)
        .firstMatch(contentType);
    return m?.group(1);
  }

  static String _decode(List<int> bytes, String? charset) {
    final cs = (charset ?? '').trim().toLowerCase();
    if (cs.isEmpty || cs == 'utf-8' || cs == 'utf8') {
      return CharsetDecoder.decode(bytes);
    }
    if (cs.contains('gb')) return CharsetDecoder.decodeGbk(bytes);
    if (cs == 'utf-16' || cs == 'utf16') {
      return CharsetDecoder.decode(bytes); // BOM 探测覆盖 UTF-16
    }
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return CharsetDecoder.decode(bytes);
    }
  }
}
