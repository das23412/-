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

    // 文件名 → 条目 索引（原文名 + 小写兜底 + 解码名兜底）。旧实现每次查找都
    // 线性扫描全部条目，长 spine 的 EPUB 会退化成 O(条目数 × 章节数)。
    final byName = <String, ArchiveFile>{};
    String safeDecode(String s) {
      try {
        return Uri.decodeComponent(s);
      } catch (_) {
        return s;
      }
    }

    for (final f in archive.files) {
      byName.putIfAbsent(f.name, () => f);
      byName.putIfAbsent(f.name.toLowerCase(), () => f);
      final decoded = safeDecode(f.name);
      if (decoded != f.name) {
        byName.putIfAbsent(decoded, () => f);
        byName.putIfAbsent(decoded.toLowerCase(), () => f);
      }
    }

    // ZIP 内路径规范化：反斜杠转 /、去 #fragment、解析 . / .. 段
    //（.. 相对 ZIP 根逐级回退，越界忽略）、去前导 /、空白段丢弃。
    String normalizePath(String path) {
      var p = path.replaceAll('\\', '/');
      final hash = p.indexOf('#');
      if (hash >= 0) p = p.substring(0, hash);
      final segs = <String>[];
      for (final seg in p.split('/')) {
        if (seg.isEmpty || seg == '.') continue; // 空段（含前导 /）与当前目录段
        if (seg == '..') {
          if (segs.isNotEmpty) segs.removeLast();
          continue;
        }
        segs.add(seg);
      }
      return segs.join('/');
    }

    ArchiveFile? find(String path) {
      // 规范化后的多个候选 key：原形 / 小写 / 百分号解码 / 解码后小写，
      // 以及"先解码再规范化"的变形（%2F 会产生新路径段）。
      // OPF href 常见百分号编码（chapter%20one.xhtml），ZIP 条目名一般是
      // 解码后的明文；个别打包器反向保留编码名，两个方向都试。
      final resolved = normalizePath(path);
      final candidates = <String>{resolved, resolved.toLowerCase()};
      final decoded = safeDecode(resolved);
      if (decoded != resolved) {
        candidates..add(decoded)..add(decoded.toLowerCase());
      }
      final decodedFirst = normalizePath(safeDecode(path));
      if (decodedFirst != resolved) {
        candidates..add(decodedFirst)..add(decodedFirst.toLowerCase());
      }
      for (final c in candidates) {
        final f = byName[c];
        if (f != null) return f;
      }
      return null;
    }

    /// 读取 ZIP 内文件为文本；找不到时抛带文件名的 FormatException，
    /// 不再静默返回空串（旧实现会让整类合法文件静默丢章）。
    String readText(String path) {
      final f = find(path);
      if (f == null) {
        throw FormatException('EPUB 缺少文件：$path');
      }
      return CharsetDecoder.decode(f.content as List<int>);
    }

    /// 可选元数据（container/ncx/nav）读取：缺失返回空串，由调用方走兜底。
    String tryReadText(String path) {
      try {
        return readText(path);
      } on FormatException {
        return '';
      }
    }

    // 1. container.xml 找 OPF
    final container = tryReadText('META-INF/container.xml');
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

    /// opfDir + 相对 href 拼接；href 以 / 开头时相对 ZIP 根（不以 opfDir 为基）。
    String joinHref(String href) {
      final h = href.replaceAll('\\', '/').split('#').first;
      if (h.startsWith('/')) return h.substring(1);
      return '$opfDir$h';
    }

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
      final ncxXml = tryReadText(joinHref(manifest[ncxId]!));
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
          final navXml = tryReadText(joinHref(href));
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
    final missing = <String>[]; // 找不到的章节文件（用于最终错误提示）
    int seq = 0;
    for (final id in spineIds) {
      final href = manifest[id]!;
      final String xml;
      try {
        xml = readText(joinHref(href));
      } on FormatException {
        // 单个章节文件缺失：计入丢失列表继续解析，不让整本读不出
        missing.add(href);
        continue;
      }
      if (xml.trim().isEmpty) continue;
      final text = TextUtils.stripHtml(xml);
      if (text.trim().isEmpty) continue;
      final key = _normalizeSrc(href);
      final tocTitle = _findTocTitle(tocTitles, key);
      final title = tocTitle ?? _firstHeading(xml) ?? '第${seq + 1}章';
      chapters.add(ParsedChapter(title, text));
      seq++;
    }
    if (chapters.isEmpty) {
      if (missing.isNotEmpty) {
        throw FormatException(
            'EPUB 正文读取失败，丢失 ${missing.length} 个章节文件：'
            '${missing.join('、')}');
      }
      throw const FormatException('EPUB 没有可读的正文');
    }
    return ParsedBook(chapters);
  }

  static String _normalizeSrc(String src) {
    var s = src.replaceAll('\\', '/').split('#').first;
    if (s.startsWith('./')) s = s.substring(2);
    // OPF 里的 href 可能带百分号编码（chapter%20one.xhtml），ZIP 条目名是解码后的
    try {
      final decoded = Uri.decodeComponent(s);
      if (decoded != s) s = decoded;
    } catch (_) {}
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
