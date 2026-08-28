import 'dart:io';

import '../core/book_format.dart';
import 'epub_parser.dart';
import 'fb2_parser.dart';
import 'html_parser.dart';
import 'mobi_parser.dart';
import 'txt_parser.dart';

/// 解析出的一章内容。
class ParsedChapter {
  final String title;
  final String text;
  ParsedChapter(this.title, this.text);
}

/// 解析出的整本书。
class ParsedBook {
  final List<ParsedChapter> chapters;
  ParsedBook(this.chapters);
}

/// 统一的文件解析入口。
class BookParser {
  /// 解析本地文件。
  ///
  /// 抛出 [MobiUnsupportedException] 等带友好信息的异常，上层应捕获并提示。
  static Future<ParsedBook> parseFile(String path, BookFormat format) async {
    final file = File(path);
    switch (format) {
      case BookFormat.txt:
        return TxtParser.parse(file);
      case BookFormat.epub:
        return EpubParser.parse(file);
      case BookFormat.mobi:
        return MobiParser.parse(file);
      case BookFormat.fb2:
        return Fb2Parser.parse(file);
      case BookFormat.html:
        return HtmlParser.parse(file);
      case BookFormat.unknown:
        throw const FormatException('不支持的文件格式');
    }
  }
}
