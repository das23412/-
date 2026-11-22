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
      final topSections = body.findElements('section').toList();
      if (topSections.isEmpty) {
        // 没有分节：整段作为一章
        final text = _paragraphsText(body);
        if (text.trim().isNotEmpty) {
          chapters.add(ParsedChapter('正文', text));
        }
        continue;
      }
      int seq = 0;
      // 递归展开 section 树：嵌套 section（卷>章）的每层独立成章，
      // 旧实现只取 body 直接子级，内层章标题全丢、整卷并成一章。
      void collect(XmlElement parent) {
        for (final el in parent.childElements) {
          if (el.name.local.toLowerCase() != 'section') continue;
          if (el.findElements('section').isNotEmpty) {
            // 容器节：自身段落（卷首语）先成章，再递归子节；
            // 自身无正文则不产出空章，只展开子节
            final direct = _directText(el);
            if (direct.isNotEmpty) {
              final title = _sectionTitle(el) ?? '第${seq + 1}章';
              chapters.add(ParsedChapter(title, direct));
              seq++;
            }
            collect(el);
          } else {
            // 叶子节：整节一章
            final text = _paragraphsText(el);
            if (text.trim().isEmpty) continue;
            final title = _sectionTitle(el) ?? '第${seq + 1}章';
            chapters.add(ParsedChapter(title, text));
            seq++;
          }
        }
      }

      collect(body);
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
  /// 不下钻嵌套 section：容器节的子节内容由递归收集另行成章，
  /// 避免整卷文本与子章重复计入。
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
        } else if (name == 'section') {
          continue; // 嵌套小节由 collect 递归处理
        } else {
          walk(child);
        }
      }
    }

    walk(root);
    return buf.toString().trim();
  }

  /// 收集容器节自身的直接 `<p>` / `<v>` 文本（不下钻嵌套 section，
  /// 避免卷首语与子节内容重复计入）。
  static String _directText(XmlElement root) {
    final buf = StringBuffer();
    for (final child in root.childElements) {
      final name = child.name.local.toLowerCase();
      if (name == 'p' || name == 'v') {
        final t = child.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (t.isNotEmpty) buf.writeln(t);
      }
    }
    return buf.toString().trim();
  }
}
