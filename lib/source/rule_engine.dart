import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'book_source.dart';

/// 规则执行时的节点：HTML 元素、JSON 值或纯文本。
class RuleNode {
  final Element? element;
  final dynamic json;
  const RuleNode.element(this.element) : json = null;
  const RuleNode.json(this.json) : element = null;

  /// 根节点便捷构造：HTML 与 JSON 二选一。
  factory RuleNode.root(Element? element, dynamic json) =>
      element != null ? RuleNode.element(element) : RuleNode.json(json);
  bool get isElement => element != null;
}

/// 书源规则引擎（Legado 常用规则子集）。
///
/// 支持：
/// - `@css:选择器@提取`（提取：text/html/all/ownText/textNodes/属性名）
/// - `@json:$.a.b[*].c`（JSONPath 子集：$. 取键、[N] 取下标、[*] 展开）
/// - Legado 默认链式规则：`class.box@tag.a.0@text`（class/id/tag/text 定位 +
///   末段提取，未识别的步骤按 CSS 选择器兜底）
/// - `||` 多规则兜底；`##正则##替换` 后处理
/// - 不支持：JS 执行、XPath、登录/验证码（抛 [SourceUnsupportedException]）
class RuleEngine {
  // ---------- 对外入口 ----------

  /// 执行规则取一个字符串（多结果用换行连接，属性类取第一个命中）。
  /// 优先级：先按 `||` 切分兜底分支；每个分支内可含 `&&`（各部分结果换行合并，
  /// 空部分跳过）；每个分支/部分独立处理 `##` 后处理。规则非法（坏选择器/
  /// 坏正则）视为空并继续兜底；全部分支都需要 JS/XPath 时抛
  /// [SourceUnsupportedException]。
  static String? evalString(
    String rule, {
    Element? root,
    dynamic json,
    String? baseUrl,
  }) {
    var sawUnsupported = false;
    for (final alt in rule.split('||')) {
      final joined = <String>[];
      var sawUnsupportedInAlt = false;
      for (final part in alt.split('&&')) {
        final p = _splitPostProcess(part);
        final a = p.base.trim();
        if (a.isEmpty) continue;
        String? r;
        try {
          r = _evalAlternative(a, root: root, json: json, baseUrl: baseUrl);
        } on SourceUnsupportedException {
          sawUnsupportedInAlt = true;
          continue; // 该部分需要 JS/XPath
        } on FormatException {
          continue; // 该部分规则非法（坏选择器/坏正则）：视为空
        }
        if (r != null && r.trim().isNotEmpty) {
          joined.add(_applyRegex(r.trim(), p.match, p.replace));
        }
      }
      if (joined.isNotEmpty) return joined.join('\n');
      if (sawUnsupportedInAlt) sawUnsupported = true;
    }
    if (sawUnsupported) {
      throw const SourceUnsupportedException('该规则需要执行 JS 或 XPath，暂不支持');
    }
    return null;
  }

  /// 执行列表规则（bookList / chapterList），返回元素或 JSON 值列表。
  /// `&&` 拼接各部分的列表；规则非法视为空；全部分支需要 JS/XPath 时抛
  /// [SourceUnsupportedException]。
  static List<RuleNode> evalList(String rule, {Element? root, dynamic json}) {
    var sawUnsupported = false;
    for (final alt in rule.split('||')) {
      final collected = <RuleNode>[];
      var sawUnsupportedInAlt = false;
      for (final part in alt.split('&&')) {
        final p = _splitPostProcess(part);
        final a = p.base.trim();
        if (a.isEmpty) continue;
        List<RuleNode> nodes;
        try {
          nodes = _evalListAlternative(a, root: root, json: json);
        } on SourceUnsupportedException {
          sawUnsupportedInAlt = true;
          continue;
        } on FormatException {
          continue;
        }
        collected.addAll(nodes);
      }
      if (collected.isNotEmpty) return collected;
      if (sawUnsupportedInAlt) sawUnsupported = true;
    }
    if (sawUnsupported) {
      throw const SourceUnsupportedException('该规则需要执行 JS 或 XPath，暂不支持');
    }
    return const [];
  }

  /// 应用内容净化规则（格式：##正则##替换，替换可省略=删除）。
  static String applyReplaceRegex(String text, String replaceRule) {
    final p = _splitPostProcess(replaceRule.trim());
    if (p.match.isEmpty) return text;
    return _applyRegex(text, p.match, p.replace);
  }

  // ---------- 内部：规则预处理 ----------

  static ({String base, String match, String replace}) _splitPostProcess(
      String rule) {
    var base = rule.trim();
    var match = '';
    var replace = '';
    final p1 = base.indexOf('##');
    if (p1 >= 0) {
      final rest = base.substring(p1 + 2);
      base = base.substring(0, p1);
      final p2 = rest.indexOf('##');
      if (p2 >= 0) {
        match = rest.substring(0, p2);
        replace = rest.substring(p2 + 2);
      } else {
        match = rest;
      }
    }
    return (base: base, match: match, replace: replace);
  }

  static String _applyRegex(String text, String match, String replace) {
    if (match.isEmpty) return text;
    try {
      final re = RegExp(match);
      if (replace.isEmpty) return text.replaceAllMapped(re, (_) => '');
      return text.replaceAllMapped(re, (m) => _expandReplacement(replace, m));
    } on FormatException {
      return text; // 书源里的正则写错了：跳过净化而不是崩溃
    }
  }

  /// 展开替换串里的捕获组引用：$N / ${N} / $& / $` / $' / $$。
  /// （Dart 的 replaceAll 不解释替换串，需要手动展开。）
  static String _expandReplacement(String replace, Match m) {
    final buf = StringBuffer();
    for (int i = 0; i < replace.length; i++) {
      final c = replace[i];
      if (c != r'$' || i == replace.length - 1) {
        buf.write(c);
        continue;
      }
      final next = replace[i + 1];
      switch (next) {
        case r'$':
          buf.write(r'$');
          i++;
          break;
        case '&':
          buf.write(m.group(0) ?? '');
          i++;
          break;
        case '`':
          buf.write(m.input.substring(0, m.start));
          i++;
          break;
        case '\'':
          buf.write(m.input.substring(m.end));
          i++;
          break;
        case '{':
          final close = replace.indexOf('}', i);
          if (close > i + 1) {
            buf.write(_groupOf(m, int.tryParse(replace.substring(i + 2, close))));
            i = close;
          } else {
            buf.write(c);
          }
          break;
        default:
          // 扫出完整的数字串（支持 $12 这类两位以上组号）
          int j = i + 1;
          while (j < replace.length) {
            final cu = replace.codeUnitAt(j);
            if (cu < 0x30 || cu > 0x39) break;
            j++;
          }
          final idx = int.tryParse(replace.substring(i + 1, j));
          if (idx != null) {
            buf.write(_groupOf(m, idx));
            i = j - 1;
          } else {
            buf.write(c);
          }
      }
    }
    return buf.toString();
  }

  static String _groupOf(Match m, int? idx) {
    if (idx == null) return '';
    if (idx == 0) return m.group(0) ?? '';
    if (idx > m.groupCount) return '';
    return m.group(idx) ?? '';
  }

  // ---------- 内部：单条规则 ----------

  static String? _evalAlternative(
    String rule, {
    Element? root,
    dynamic json,
    String? baseUrl,
  }) {
    final lower = rule.toLowerCase();
    if (lower.startsWith('@css:')) {
      final body = rule.substring(5);
      final cut = body.lastIndexOf('@');
      final selector = cut >= 0 ? body.substring(0, cut) : body;
      final extract = cut >= 0 ? body.substring(cut + 1).trim() : 'text';
      if (root == null) return null;
      final elements = root.querySelectorAll(selector);
      return _extractJoined(elements, extract, baseUrl);
    }
    if (lower.startsWith('@json:')) {
      if (json == null) return null;
      final values = _walkJsonPath(json, rule.substring(6).trim());
      if (values.isEmpty) return null;
      final first = values.first;
      if (first is String) return first;
      if (first is num || first is bool) return first.toString();
      if (first != null) return jsonEncodeForRule(first);
      return null;
    }
    if (lower.startsWith('@xpath:') ||
        lower.startsWith('@js:') ||
        rule.startsWith('<js>')) {
      throw const SourceUnsupportedException('规则需要执行 JS 或 XPath，暂不支持');
    }
    // Legado 默认链式规则
    return _evalDefaultChain(rule, root: root, json: json, baseUrl: baseUrl);
  }

  static List<RuleNode> _evalListAlternative(
    String rule, {
    Element? root,
    dynamic json,
  }) {
    final lower = rule.toLowerCase();
    if (lower.startsWith('@css:')) {
      final body = rule.substring(5);
      final cut = body.lastIndexOf('@');
      // 列表规则末段若是提取关键字则去掉（列表要的是元素本身）
      final last = cut >= 0 ? body.substring(cut + 1).trim() : '';
      final selector =
          _isExtractor(last) || last.startsWith('attr.') ? body.substring(0, cut) : body;
      if (root == null) return const [];
      return root
          .querySelectorAll(selector)
          .map(RuleNode.element)
          .toList(growable: false);
    }
    if (lower.startsWith('@json:')) {
      if (json == null) return const [];
      final values = _walkJsonPath(json, rule.substring(6).trim());
      return values.map(RuleNode.json).toList(growable: false);
    }
    if (lower.startsWith('@xpath:') ||
        lower.startsWith('@js:') ||
        rule.startsWith('<js>')) {
      throw const SourceUnsupportedException('规则需要执行 JS 或 XPath，暂不支持');
    }
    return _evalDefaultChainList(rule, root: root, json: json);
  }

  // ---------- 内部：默认链式规则 ----------

  static const _extractors = {
    'text', 'textnodes', 'owntext', 'html', 'all', 'content', 'value',
    'href', 'src', 'alt', 'title', 'textlen',
  };

  static bool _isExtractor(String step) {
    final s = step.toLowerCase();
    return _extractors.contains(s) || s.startsWith('attr.');
  }

  static String? _evalDefaultChain(
    String rule, {
    Element? root,
    dynamic json,
    String? baseUrl,
  }) {
    if (json != null && root == null) {
      return _evalJsonChain(rule, json, baseUrl);
    }
    if (root == null) return null;
    final steps = rule.split('@').map((s) => s.trim()).toList();
    var current = <Element>[root];
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final isLast = i == steps.length - 1;
      if (isLast && _isExtractor(step)) {
        return _extractJoined(current, step, baseUrl);
      }
      current = _navigate(current, step);
      if (current.isEmpty) return null;
      if (isLast) {
        // 最后一步是定位而非提取：取定位结果的文本
        return _extractJoined(current, 'text', baseUrl);
      }
    }
    return null;
  }

  static List<RuleNode> _evalDefaultChainList(
    String rule, {
    Element? root,
    dynamic json,
  }) {
    if (json != null && root == null) {
      final v = _evalJsonChainValue(rule, json);
      if (v is List) return v.map(RuleNode.json).toList(growable: false);
      if (v != null) return [RuleNode.json(v)];
      return const [];
    }
    if (root == null) return const [];
    final steps = rule.split('@').map((s) => s.trim()).toList();
    var current = <Element>[root];
    for (final step in steps) {
      if (_isExtractor(step)) continue; // 列表规则里末段提取无意义，跳过
      current = _navigate(current, step);
      if (current.isEmpty) return const [];
    }
    return current.map(RuleNode.element).toList(growable: false);
  }

  /// 在元素列表上执行一步定位。
  static List<Element> _navigate(List<Element> current, String step) {
    final parts = step.split('.');
    final head = parts[0].toLowerCase();
    final out = <Element>[];
    // 定位步骤：class.X / id.X / tag.X / text.X（可带 .N 下标）
    if (parts.length >= 2 && {'class', 'id', 'tag', 'text'}.contains(head)) {
      final token = parts[1];
      final index =
          parts.length >= 3 ? int.tryParse(parts[2]) : null;
      for (final el in current) {
        List<Element> found;
        switch (head) {
          case 'class':
            found = el.getElementsByClassName(token).toList();
            break;
          case 'id':
            final byId = el.querySelector('#${_cssEscapeId(token)}');
            found = byId == null ? <Element>[] : [byId];
            break;
          case 'tag':
            found = el.getElementsByTagName(token).toList();
            break;
          case 'text':
            found = _findByText(el, token);
            break;
          default:
            found = <Element>[];
        }
        if (index != null) {
          if (index >= 0 && index < found.length) {
            found = [found[index]];
          } else if (index < 0 && found.length >= -index) {
            found = [found[found.length + index]];
          } else {
            found = <Element>[];
          }
        }
        out.addAll(found);
      }
      return out;
    }
    // 未识别的步骤按 CSS 选择器兜底
    for (final el in current) {
      try {
        out.addAll(el.querySelectorAll(step));
      } catch (_) {}
    }
    return out;
  }

  static String _cssEscapeId(String id) {
    return id.replaceAllMapped(RegExp(r'([^a-zA-Z0-9_-])'), (m) {
      final c = m.group(1)!;
      final code = c.codeUnitAt(0).toRadixString(16).padLeft(6, '0');
      return '\\$code ';
    });
  }

  static List<Element> _findByText(Element root, String keyword) {
    final out = <Element>[];
    void walk(Element el) {
      for (final child in el.children) {
        if (child.text.contains(keyword)) out.add(child);
        walk(child);
      }
    }

    walk(root);
    return out;
  }

  // ---------- 内部：JSON 规则 ----------

  /// JSON 上下文下的简单键链（如 `title` 或 `a.b`），也兼容以 $ 开头的路径。
  /// 注意：这里不做 URL 解析——文本字段（书名等）会被误改写；
  /// URL 字段由服务层显式解析。
  static String? _evalJsonChain(String rule, dynamic json, String? baseUrl) {
    final v = _evalJsonChainValue(rule, json);
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return jsonEncodeForRule(v);
  }

  static dynamic _evalJsonChainValue(String rule, dynamic json) {
    var r = rule.trim();
    if (r.startsWith('@json:')) r = r.substring(6).trim();
    if (r.startsWith('\$')) {
      final values = _walkJsonPath(json, r);
      return values.isEmpty ? null : values.first;
    }
    // 纯键链：a.b.c
    dynamic cur = json;
    for (final key in r.split('.')) {
      if (key.isEmpty) continue;
      if (cur is Map && cur.containsKey(key)) {
        cur = cur[key];
      } else if (cur is List) {
        final idx = int.tryParse(key);
        if (idx == null || idx < 0 || idx >= cur.length) return null;
        cur = cur[idx];
      } else {
        return null;
      }
    }
    return cur;
  }

  /// JSONPath 子集：`$.a.b`、`[N]`、`[*]`、`$..key`（递归下降）。
  /// 返回命中的所有值。
  static List<dynamic> _walkJsonPath(dynamic root, String path) {
    var p = path.trim();
    if (p.startsWith('\$')) p = p.substring(1);
    final tokens = <_JsonToken>[];
    int i = 0;
    while (i < p.length) {
      final c = p[i];
      if (c == '.') {
        // '..key' = 递归下降
        if (i + 1 < p.length && p[i + 1] == '.') {
          var j = i + 2;
          while (j < p.length && p[j] != '.' && p[j] != '[') {
            j++;
          }
          final key = p.substring(i + 2, j);
          if (key.isNotEmpty) tokens.add(_JsonToken.recursive(key));
          i = j;
          continue;
        }
        var j = i + 1;
        while (j < p.length && p[j] != '.' && p[j] != '[') {
          j++;
        }
        final key = p.substring(i + 1, j);
        if (key.isNotEmpty) tokens.add(_JsonToken.key(key));
        i = j;
      } else if (c == '[') {
        final close = p.indexOf(']', i);
        if (close < 0) break;
        final inner = p.substring(i + 1, close).trim();
        if (inner == '*') {
          tokens.add(_JsonToken.all());
        } else {
          final idx = int.tryParse(inner);
          if (idx != null) tokens.add(_JsonToken.index(idx));
        }
        i = close + 1;
      } else {
        i++;
      }
    }
    return _walkJson(root, tokens, 0);
  }

  static List<dynamic> _walkJson(dynamic value, List<_JsonToken> tokens, int i) {
    if (i == tokens.length) return [value];
    final t = tokens[i];
    final out = <dynamic>[];
    if (t.recursiveKey != null) {
      void collect(dynamic v) {
        if (v is Map) {
          v.forEach((k, val) {
            if (k == t.recursiveKey) {
              out.addAll(_walkJson(val, tokens, i + 1));
            }
            collect(val);
          });
        } else if (v is List) {
          for (final item in v) {
            collect(item);
          }
        }
      }

      collect(value);
    } else if (t.isAll) {
      if (value is List) {
        for (final v in value) {
          out.addAll(_walkJson(v, tokens, i + 1));
        }
      } else if (value is Map) {
        for (final v in value.values) {
          out.addAll(_walkJson(v, tokens, i + 1));
        }
      }
    } else if (t.index != null) {
      var idx = t.index!;
      if (value is List) {
        if (idx < 0) idx += value.length;
        if (idx >= 0 && idx < value.length) {
          out.addAll(_walkJson(value[idx], tokens, i + 1));
        }
      }
    } else {
      if (value is Map && value.containsKey(t.key)) {
        out.addAll(_walkJson(value[t.key], tokens, i + 1));
      }
    }
    return out;
  }

  // ---------- 内部：元素内容提取 ----------

  static String? _extractJoined(
      List<Element> elements, String extract, String? baseUrl) {
    final e = extract.trim();
    final lower = e.toLowerCase();
    final attrName = lower.startsWith('attr.') ? e.substring(5).trim() : null;
    // 文本类提取：所有命中按换行拼接；属性类提取：只取第一个命中
    final isText = attrName == null &&
        const {'text', 'textnodes', 'owntext', 'html', 'all'}.contains(lower);
    // 属性类结果可能是相对地址（href/src/data-src 等），以页面地址解析
    String? resolve(String? raw) {
      if (raw == null || isText || baseUrl == null) return raw;
      return _resolveUrl(raw, baseUrl);
    }

    final parts = <String>[];
    for (final el in elements) {
      String? v;
      if (attrName != null) {
        v = resolve(
            el.attributes[attrName] ?? el.attributes[attrName.toLowerCase()]);
      } else {
        switch (lower) {
          case 'text':
            v = _domToText(el).trim();
            break;
          case 'textlen':
            v = el.text.length.toString();
            break;
          case 'textnodes':
          case 'owntext':
            v = el.text.trim();
            break;
          case 'html':
            v = el.innerHtml;
            break;
          case 'all':
            v = el.outerHtml;
            break;
          case 'href':
          case 'src':
          case 'content':
          case 'value':
          case 'alt':
          case 'title':
            v = resolve(el.attributes[lower] ?? el.attributes[e]);
            break;
          default:
            v = resolve(el.attributes[e] ?? el.attributes[lower]);
        }
      }
      if (v != null && v.trim().isNotEmpty) {
        parts.add(v.trim());
        if (!isText) break; // 属性类只取第一个命中
      }
    }
    if (parts.isEmpty) return null;
    return parts.join('\n');
  }

  static String _resolveUrl(String raw, String baseUrl) {
    final url = raw.trim();
    if (url.isEmpty) return url;
    try {
      final base = Uri.parse(baseUrl);
      if (base.hasScheme) return base.resolve(url).toString();
    } catch (_) {}
    return url;
  }

  /// 把 DOM 转成保留换行的文本：<br> 与块级标签边界输出换行，跳过 script/style。
  static String _domToText(Node node) {
    const blockTags = {
      'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'tr',
      'blockquote', 'section', 'article', 'pre', 'center', 'dd', 'dt',
      'figcaption', 'figure', 'ul', 'ol', 'table', 'header', 'footer',
      'nav', 'aside', 'main',
    };
    final buf = StringBuffer();
    void walk(Node n) {
      if (n is Text) {
        buf.write(n.text);
        return;
      }
      if (n is Element) {
        final tag = (n.localName ?? '').toLowerCase();
        if (tag == 'br') {
          buf.write('\n');
          return;
        }
        if (tag == 'script' || tag == 'style') return;
        final isBlock = blockTags.contains(tag);
        if (isBlock && buf.isNotEmpty && !buf.toString().endsWith('\n')) {
          buf.write('\n');
        }
        for (final child in n.nodes) {
          walk(child);
        }
        if (isBlock && buf.isNotEmpty && !buf.toString().endsWith('\n')) {
          buf.write('\n');
        }
      }
    }

    walk(node);
    return buf
        .toString()
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n');
  }

  /// 解析 HTML 文档（供调用方在拿到响应体后构建根节点）。
  static Document parseHtml(String body) => html_parser.parse(body);
}

class _JsonToken {
  final String? key;
  final int? index;
  final bool isAll;
  const _JsonToken.key(this.key)
      : index = null,
        isAll = false,
        recursiveKey = null;
  const _JsonToken.index(this.index)
      : key = null,
        isAll = false,
        recursiveKey = null;
  const _JsonToken.all()
      : key = null,
        index = null,
        isAll = true,
        recursiveKey = null;
  const _JsonToken.recursive(this.recursiveKey)
      : key = null,
        index = null,
        isAll = false;
}

/// 规则结果的 JSON 值转字符串（Map/List 序列化为 JSON 文本）。
String jsonEncodeForRule(dynamic v) {
  try {
    return jsonEncode(v);
  } catch (_) {
    return v.toString();
  }
}
