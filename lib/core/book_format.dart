/// 支持的小说文件格式。
enum BookFormat {
  txt,
  epub,
  mobi, // 含 .mobi / .azw / .azw3
  fb2,
  html,
  unknown;

  static BookFormat fromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.txt')) return BookFormat.txt;
    if (lower.endsWith('.epub')) return BookFormat.epub;
    if (lower.endsWith('.mobi') ||
        lower.endsWith('.azw3') ||
        lower.endsWith('.azw')) {
      return BookFormat.mobi;
    }
    if (lower.endsWith('.fb2')) return BookFormat.fb2;
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      return BookFormat.html;
    }
    return BookFormat.unknown;
  }

  /// 用于展示的格式名。
  String get displayName {
    switch (this) {
      case BookFormat.txt:
        return 'TXT';
      case BookFormat.epub:
        return 'EPUB';
      case BookFormat.mobi:
        return 'MOBI';
      case BookFormat.fb2:
        return 'FB2';
      case BookFormat.html:
        return 'HTML';
      case BookFormat.unknown:
        return '未知';
    }
  }

  /// 推荐的 MIME 类型（供系统“用其他应用打开”匹配）。
  String? get mimeType {
    switch (this) {
      case BookFormat.txt:
        return 'text/plain';
      case BookFormat.epub:
        return 'application/epub+zip';
      case BookFormat.mobi:
        return 'application/x-mobipocket-ebook';
      case BookFormat.fb2:
        return 'application/xml';
      case BookFormat.html:
        return 'text/html';
      default:
        return null;
    }
  }
}

/// 扫描 / 导入时接受的扩展名。
const List<String> supportedExtensions = [
  '.txt',
  '.epub',
  '.mobi',
  '.azw3',
  '.azw',
  '.fb2',
  '.html',
  '.htm',
];
