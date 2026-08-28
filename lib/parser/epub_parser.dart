import 'dart:io';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../core/charset.dart';
import '../core/text_utils.dart';
import 'parser.dart';

/// EPUB 解析：解压 → container.xml → OPF → spine 顺序读取 XHTML。
class EpubParser {
  static ParsedBook parse(File file) {
    late final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    } catch (_) {
      throw const FormatException('EPUB 文件损坏，无法解压');
    }

    ArchiveFile? find(String path) {
      final p = path.replaceAll('\\', '/');
      for (final f in archive.files) {
        if (f.name == p || f.name == p.replaceFirst('/', '')) return f;
      }
      // 大小写不敏感兜底
      for (final f in archive.files) {
        if (f.name.toLowerCase() == p.toLowerCase()) return f;
      }
      return null;
    }

    String readText(String path) {
      final f = find(path);
      if (f == null) return '';
      return CharsetDecoder.decode(f.content as List<int>);
    }

    // 1. container.xml 找 OPF
    final container = readText('META-INF/container.xml');
    String opfPath = '';
    if (container.isNotEmpty) {
      try {
        final doc = XmlDocument.parse(container);
        opfPath = doc.findAllElements('rootfile',
                namespace: 'urn:oasis:names:tc:opendocument:xmlns:container')
            .map((e) => e.getAttribute('full-path') ?? '')
            .firstWhere((s) => s.isNotEmpty, orElse: () => '');
        if (opfPath.isEmpty) {
          opfPath = doc.findAllElements('rootfile').isEmpty
              ? ''
              : doc.findAllElements('rootfile').first
                  .getAttribute('full-path') ??
              '';
        }
      } catch (_) {}
    }
    if (opfPath.isEmpty) {
      // 兜底：直接找 .opf
      for (final f in archive.files) {
        if (f.name.toLowerCase().endsWith('.opf')) {
          opfPath = f.name;
          break;
        }
      }
    }
    if (opfPath.isEmpty) throw const FormatException('EPUB 缺少 OPF 元数据');

    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';

    // 2. 解析 OPF：manifest + spine
    final opfXml = readText(opfPath);
    if (opfXml.isEmpty) throw const FormatException('EPUB OPF 文件为空');
    late XmlDocument opf;
    try {
      opf = XmlDocument.parse(opfXml);
    } catch (_) {
      throw const FormatException('EPUB OPF 文件损坏');
    }

    final manifest = <String, String>{}; // id -> href
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) manifest[id] = href;
    }
    final spineIds = <String>[];
    for (final ref in opf.findAllElements('itemref')) {
      final idref = ref.getAttribute('idref');
      if (idref != null && manifest.containsKey(idref)) spineIds.add(idref);
    }
    if (spineIds.isEmpty) throw const FormatException('EPUB 没有正文内容');

    // 3. 目录标题：优先 toc.ncx，其次 nav.xhtml
    final tocTitles = <String, String>{}; // href(相对opf) -> title
    final ncxId = opf.findAllElements('item').cast<XmlElement?>().firstWhere(
          (e) =>
              (e!.getAttribute('media-type') ?? '') == 'application/x-dtbncx+xml',
          orElse: () => null,
        )?.getAttribute('id');
    if (ncxId != null && manifest[ncxId] != null) {
      final ncxXml = readText('$opfDir${manifest[ncxId]!}');
      try {
        final ncx = XmlDocument.parse(ncxXml);
        for (final nav in ncx.findAllElements('navPoint')) {
          final label = nav.findElements('navLabel').isNotEmpty
              ? nav.findElements('navLabel').first.innerText.trim()
              : '';
          final src = nav.findElements('content').isNotEmpty
              ? nav.findElements('content').first.getAttribute('src') ?? ''
              : '';
          if (src.isNotEmpty && label.isNotEmpty) {
            tocTitles[_normalizeSrc(src)] = label;
          }
        }
      } catch (_) {}
    }
    // EPUB3 nav 文档
    for (final item in opf.findAllElements('item')) {
      if ((item.getAttribute('properties') ?? '').contains('nav')) {
        final href = item.getAttribute('href');
        if (href != null) {
          final navXml = readText('$opfDir$href');
          try {
            final nav = XmlDocument.parse(navXml);
            for (final a in nav.findAllElements('a')) {
              final href2 = a.getAttribute('href');
              final text = a.innerText.trim();
              if (href2 != null && text.isNotEmpty) {
                tocTitles[_normalizeSrc(href2)] = text;
              }
            }
          } catch (_) {}
        }
      }
    }

    // 4. 按 spine 顺序读取正文
    final chapters = <ParsedChapter>[];
    int seq = 0;
    for (final id in spineIds) {
      final href = manifest[id]!;
      final xml = readText('$opfDir$href');
      if (xml.trim().isEmpty) continue;
      final text = TextUtils.stripHtml(xml);
      if (text.trim().isEmpty) continue;
      final key = _normalizeSrc(href);
      final tocTitle = _findTocTitle(tocTitles, key);
      final title = tocTitle ?? _firstHeading(xml) ?? '第${seq + 1}章';
      chapters.add(ParsedChapter(title, text));
      seq++;
    }
    if (chapters.isEmpty) throw const FormatException('EPUB 没有可读的正文');
    return ParsedBook(chapters);
  }

  static String _normalizeSrc(String src) {
    var s = src.replaceAll('\\', '/').split('#').first;
    if (s.startsWith('./')) s = s.substring(2);
    return s;
  }

  static String? _findTocTitle(Map<String, String> toc, String key) {
    if (toc.containsKey(key)) return toc[key];
    // 匹配同名不同片段
    for (final e in toc.entries) {
      if (e.key.split('#').first == key.split('#').first) return e.value;
    }
    return null;
  }

  static String? _firstHeading(String xml) {
    final m = RegExp(r'<h[1-6][^>]*>(.*?)</h[1-6]>', dotAll: true,
            caseSensitive: false)
        .firstMatch(xml);
    if (m == null) return null;
    final t = TextUtils.decodeEntities(m.group(1)!)
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim();
    return t.isEmpty ? null : t;
  }
}
