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

/// href 形态 / 缺章用例共用的 container.xml（与 buildEpub 相同）。
const containerXml = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''';

/// 按 [manifestHrefs]（id→href）与 [files]（ZIP 条目→内容）构造 EPUB，
/// 用于 href 形态与缺章用例：manifest 可以引用不存在、带 ./ ../
/// 相对路径的条目。
List<int> buildEpubCustom({
  required Map<String, String> manifestHrefs,
  required Map<String, String> files,
}) {
  final manifest = StringBuffer();
  final spine = StringBuffer();
  manifestHrefs.forEach((id, href) {
    manifest.write(
        '    <item id="$id" href="$href" media-type="application/xhtml+xml"/>\n');
    spine.write('    <itemref idref="$id"/>\n');
  });
  final opf = '''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <manifest>
${manifest.toString()}  </manifest>
  <spine>
${spine.toString()}  </spine>
</package>''';

  final archive = Archive();
  void addText(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  addText('mimetype', 'application/epub+zip');
  addText('META-INF/container.xml', containerXml);
  addText('OEBPS/content.opf', opf);
  files.forEach(addText);
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

  test('EPUB href 形态：./ 与 ../ 相对路径能正常找到', () {
    // 旧实现直接拿「opfDir+href」做精确 key，./ ../ 形态静默丢章；
    // 规范化后 ./ch1.xhtml → OEBPS/ch1.xhtml，../x.xhtml → x.xhtml
    file.writeAsBytesSync(buildEpubCustom(
      manifestHrefs: {
        'ch1': './ch1.xhtml',
        'ch2': '../x.xhtml',
      },
      files: {
        'OEBPS/ch1.xhtml':
            '<html><head><title>c1</title></head><body><h1>第一章 形态</h1><p>相对路径第一课。</p></body></html>',
        'x.xhtml':
            '<html><head><title>c2</title></head><body><h1>第二章 上层</h1><p>回到根目录的内容。</p></body></html>',
      },
    ));
    final book = EpubParser.parse(file);
    expect(book.chapters.length, 2);
    expect(book.chapters[0].title, '第一章 形态');
    expect(book.chapters[0].text, contains('相对路径第一课'));
    expect(book.chapters[1].title, '第二章 上层');
    expect(book.chapters[1].text, contains('回到根目录'));
  });

  test('EPUB 部分章节文件缺失时跳过该章继续', () {
    file.writeAsBytesSync(buildEpubCustom(
      manifestHrefs: {
        'ch1': 'ch1.xhtml',
        'ch2': 'missing.xhtml',
      },
      files: {
        'OEBPS/ch1.xhtml':
            '<html><body><h1>第一章 完好</h1><p>这一章存在。</p></body></html>',
      },
    ));
    final book = EpubParser.parse(file);
    expect(book.chapters.length, 1);
    expect(book.chapters[0].title, '第一章 完好');
    expect(book.chapters[0].text, contains('这一章存在'));
  });

  test('EPUB spine 文件全部缺失时报指名错误', () {
    // readText 不再静默返回空串：spine 逐个 catch 并统计丢失，
    // chapters 为空时错误信息带上丢失文件列表
    file.writeAsBytesSync(buildEpubCustom(
      manifestHrefs: {
        'ch1': 'missing1.xhtml',
        'ch2': 'missing2.xhtml',
      },
      files: {},
    ));
    Object? err;
    try {
      EpubParser.parse(file);
    } catch (e) {
      err = e;
    }
    expect(err, isA<FormatException>());
    expect(err.toString(), contains('丢失 2 个章节文件'));
    expect(err.toString(), contains('missing1.xhtml'));
    expect(err.toString(), contains('missing2.xhtml'));
  });
}
