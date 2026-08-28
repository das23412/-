import 'dart:io';

import 'package:xml/xml.dart';

import '../core/charset.dart';
import 'parser.dart';

/// FB2（FictionBook 2）解析。
class Fb2Parser {
  static ParsedBook parse(File file) {
    final xml = CharsetDecoder.decode(file.readAsBytesSync());
    late XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } catch (_) {
      throw const FormatException('FB2 文件损坏，不是有效的 XML');
    }

    final chapters = <ParsedChapter>[];
    // 可能存在多个 body（正文 / notes），只取无名的主 body
    final bodies = doc.findAllElements('body').toList();
    for (final body in bodies) {
      if (body.getAttribute('name') != null) continue;
      final sections = body.findElements('section').toList();
      if (sections.isEmpty) {
        // 没有分节：整段作为一章
        final text = _paragraphsText(body);
        if (text.trim().isNotEmpty) {
          chapters.add(ParsedChapter('正文', text));
        }
        continue;
      }
      int seq = 0;
      for (final section in sections) {
        final text = _paragraphsText(section);
        if (text.trim().isEmpty) continue;
        final title = _sectionTitle(section) ?? '第${seq + 1}章';
        chapters.add(ParsedChapter(title, text));
        seq++;
      }
    }
    if (chapters.isEmpty) throw const FormatException('FB2 没有可读的正文');
    return ParsedBook(chapters);
  }

  static String? _sectionTitle(XmlElement section) {
    final titles = section.findElements('title');
    if (titles.isEmpty) return null;
    final t = titles.first;
    final ps = t.findElements('p').toList();
    if (ps.isEmpty) {
      final inner = t.innerText.trim();
      return inner.isEmpty ? null : inner;
    }
    final line = ps.map((e) => e.innerText.trim()).where((s) => s.isNotEmpty).join(' ');
    return line.isEmpty ? null : line;
  }

  /// 收集节点下所有 `<p>` / `<v>` 文本，段落间以换行分隔。
  static String _paragraphsText(XmlElement root) {
    final buf = StringBuffer();
    void walk(XmlElement el) {
      for (final child in el.childElements) {
        final name = child.name.local.toLowerCase();
        if (name == 'p' || name == 'v') {
          final t = child.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (t.isNotEmpty) buf.writeln(t);
        } else if (name == 'title' || name == 'epigraph' || name == 'annotation') {
          continue; // 标题单独处理，注释/题记不进正文
        } else if (name == 'image' || name == 'binary') {
          continue;
        } else {
          walk(child);
        }
      }
    }

    walk(root);
    return buf.toString().trim();
  }
}
