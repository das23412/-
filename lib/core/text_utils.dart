/// 文本清洗工具：HTML 去标签、段落规整等。
class TextUtils {
  /// 将 HTML/XHTML 片段转为纯文本。
  ///
  /// 移除 script/style/title，块级标签转换为换行，解引用常见 HTML 实体。
  static String stripHtml(String html) {
    var s = html;
    // 去掉注释
    s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
    // script / style / title 整段移除
    s = s.replaceAll(
        RegExp(r'<(script|style|title|head)[^>]*>.*?</\1>',
            dotAll: true, caseSensitive: false),
        '');
    // 块级标签结束换行，<br> 换行
    s = s.replaceAll(
        RegExp(
            r'</?(p|div|section|article|br|li|h[1-6]|tr|blockquote|body|html|header|footer|nav|aside|main|ul|ol|table|dl|dd|dt|figcaption|figure|pre|center)[^>]*/?>',
            caseSensitive: false),
        '\n');
    // 剩余标签全部去掉
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = decodeEntities(s);
    // 规整空白与空行
    final lines = s
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[ \t\r\f  ]+'), ' ').trim())
        .toList();
    final out = <String>[];
    for (final line in lines) {
      if (line.isEmpty && out.isNotEmpty && out.last.isEmpty) continue;
      out.add(line);
    }
    while (out.isNotEmpty && out.first.isEmpty) {
      out.removeAt(0);
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out.join('\n');
  }

  /// 解码常见 HTML 实体。
  static String decodeEntities(String s) {
    const named = {
      '&amp;': '&',
      '&lt;': '<',
      '&gt;': '>',
      '&quot;': '"',
      '&apos;': "'",
      '&nbsp;': ' ',
      '&mdash;': '—',
      '&hellip;': '…',
      '&ldquo;': '“',
      '&rdquo;': '”',
      '&lsquo;': '‘',
      '&rsquo;': '’',
      '&copy;': '©',
      '&reg;': '®',
      '&trade;': '™',
    };
    named.forEach((k, v) {
      s = s.replaceAll(k, v);
    });
    // 数字实体
    s = s.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1)!);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    return s;
  }

  /// 清理书名（通常来自文件名）：去掉扩展名、书站后缀、多余空白。
  static String cleanTitle(String raw) {
    var t = raw;
    t = t.replaceAll(RegExp(r'\.(txt|epub|mobi|azw3|azw|fb2|html?|umd)$',
        caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'[\(（\[【]\s*(精校|全本|完結|完结|全集|未删减|校对版|作者[：:]|作者)\s*[^)\]】）]*[\)）\]】]'), '');
    // 循环剥离尾部的宣传后缀（如 “-全本-TXT” “_精校版”）
    final suffix = RegExp(
        r'[-_—－\s]+(精校版?|全本|完本|完结版?|完結|校对版|无弹窗|无广告|txt|epub|umd|作者.*|笔趣阁.*|起点.*|晋江.*)$',
        caseSensitive: false);
    while (true) {
      final m = suffix.firstMatch(t);
      if (m == null) break;
      final stripped = t.substring(0, m.start).trim();
      if (stripped.isEmpty || stripped == t) break;
      t = stripped;
    }
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.isEmpty ? raw : t;
  }

  /// 估算字数（按非空白字符计）。
  static int countChars(String text) {
    var n = 0;
    for (final r in text.runes) {
      if (r != 0x20 && r != 0x09 && r != 0x0A && r != 0x0D && r != 0x3000) {
        n++;
      }
    }
    return n;
  }
}
