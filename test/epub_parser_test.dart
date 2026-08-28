import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/parser/epub_parser.dart';

/// 构造一个最小 EPUB：container.xml + content.opf + toc.ncx + 两章 xhtml。
List<int> buildEpub() {
  const container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

  const opf = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>EPUB测试书</dc:title>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>''';

  const ncx = '''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>第一卷 序幕</text></navLabel>
      <content src="ch1.xhtml"/>
    </navPoint>
    <navPoint id="n2" playOrder="2">
      <navLabel><text>第二卷 危机</text></navLabel>
      <content src="ch2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';

  const ch1 = '''<html><head><title>c1</title></head><body>
<h1>第一卷 序幕</h1>
<p>故事从一个小镇开始。</p>
<p>雨下了一整夜。</p>
</body></html>''';

  const ch2 = '''<html><head><title>c2</title></head><body>
<h1>第二卷 危机</h1>
<p>第二天，信使带来了坏消息。</p>
</body></html>''';

  final archive = Archive();
  void addText(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  addText('mimetype', 'application/epub+zip');
  addText('META-INF/container.xml', container);
  addText('OEBPS/content.opf', opf);
  addText('OEBPS/toc.ncx', ncx);
  addText('OEBPS/ch1.xhtml', ch1);
  addText('OEBPS/ch2.xhtml', ch2);

  return ZipEncoder().encode(archive)!;
}

void main() {
  late File file;
  setUp(() {
    file = File(
        '${Directory.systemTemp.path}/moyue_test_${DateTime.now().millisecondsSinceEpoch}.epub');
    file.writeAsBytesSync(buildEpub());
  });
  tearDown(() {
    if (file.existsSync()) file.deleteSync();
  });

  test('EPUB 按 spine 顺序解析', () {
    final book = EpubParser.parse(file);
    expect(book.chapters.length, 2);
    expect(book.chapters[0].title, '第一卷 序幕');
    expect(book.chapters[0].text, contains('故事从一个小镇开始'));
    expect(book.chapters[1].title, '第二卷 危机');
    expect(book.chapters[1].text, contains('坏消息'));
  });

  test('EPUB 损坏时报友好错误', () {
    final bad = File('${Directory.systemTemp.path}/bad_${DateTime.now().millisecondsSinceEpoch}.epub');
    bad.writeAsBytesSync([1, 2, 3, 4, 5]);
    expect(() => EpubParser.parse(bad), throwsA(isA<FormatException>()));
    bad.deleteSync();
  });
}
