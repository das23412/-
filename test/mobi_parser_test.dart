import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/parser/mobi_parser.dart';

const int _mobiHeaderLen = 0xF8; // 248，需 ≥ 0xF2+2 才会读取 extraFlags

/// 构造最小合法 MOBI：PDB 头 + record0（PalmDOC头 + MOBI头）+ 文本记录。
Uint8List buildMobi(List<List<int>> textRecords, {int compression = 1}) {
  final numRecords = 1 + textRecords.length;
  final textLen = textRecords.fold<int>(0, (a, b) => a + b.length - 3);

  // record 0
  final b = BytesBuilder();
  b.add([(compression >> 8) & 0xFF, compression & 0xFF]); // compression
  b.add([0, 0]); // unused
  b.add([
    (textLen >> 24) & 0xFF,
    (textLen >> 16) & 0xFF,
    (textLen >> 8) & 0xFF,
    textLen & 0xFF,
  ]);
  b.add([(textRecords.length >> 8) & 0xFF, textRecords.length & 0xFF]);
  b.add([0x10, 0x00]); // recordSize = 4096
  b.add([0, 0]); // encryption = 0
  b.add([0, 0]); // unknown
  b.add(_four('MOBI'));
  b.add([
    (_mobiHeaderLen >> 24) & 0xFF,
    (_mobiHeaderLen >> 16) & 0xFF,
    (_mobiHeaderLen >> 8) & 0xFF,
    _mobiHeaderLen & 0xFF,
  ]);
  b.add([0, 0, 0, 2]); // mobiType = 2
  b.add([0, 0, 0xFD, 0xE9]); // textEncoding = 65001
  b.add(List<int>.filled(4, 0)); // uniqueID
  b.add(List<int>.filled(4, 0)); // fileVersion
  final current = b.length;
  b.add(List<int>.filled(_mobiHeaderLen - (current - 16), 0));
  final record0 = b.toBytes();
  // extra data flags 位于 record0 偏移 16 + 0xF2 = 258，设为 1（multibyte overlap）
  final flagsOffset = 16 + 0xF2;
  record0[flagsOffset + 3] = 1;

  final records = <List<int>>[record0, ...textRecords];

  final offsets = <int>[];
  int offset = 78 + numRecords * 8 + 2;
  for (final r in records) {
    offsets.add(offset);
    offset += r.length;
  }

  final out = BytesBuilder();
  out.add(List<int>.filled(32, 0)); // name
  out.add([0, 0]); // attributes
  out.add([0, 2]); // version
  out.add(List<int>.filled(12, 0)); // dates
  out.add(List<int>.filled(4, 0)); // modnum
  out.add(List<int>.filled(4, 0)); // appInfoOffset
  out.add(List<int>.filled(4, 0)); // sortInfoOffset
  out.add(_four('BOOK')); // type
  out.add(_four('MOBI')); // creator
  out.add(List<int>.filled(4, 0)); // uniqueIDseed
  out.add(List<int>.filled(4, 0)); // nextRecordList
  out.add([(numRecords >> 8) & 0xFF, numRecords & 0xFF]);
  expect(out.length, 78);

  for (int i = 0; i < records.length; i++) {
    final o = offsets[i];
    out.add([
      (o >> 24) & 0xFF,
      (o >> 16) & 0xFF,
      (o >> 8) & 0xFF,
      o & 0xFF,
      0,
      (i >> 16) & 0xFF,
      (i >> 8) & 0xFF,
      i & 0xFF,
    ]);
  }
  out.add([0, 0]); // padding
  for (final r in records) {
    out.add(r);
  }
  return out.toBytes();
}

List<int> _four(String s) => s.codeUnits;

List<int> utf8(String s) {
  final out = <int>[];
  for (final cu in s.codeUnits) {
    if (cu < 0x80) {
      out.add(cu);
    } else if (cu < 0x800) {
      out
        ..add(0xC0 | (cu >> 6))
        ..add(0x80 | (cu & 0x3F));
    } else {
      out
        ..add(0xE0 | (cu >> 12))
        ..add(0x80 | ((cu >> 6) & 0x3F))
        ..add(0x80 | (cu & 0x3F));
    }
  }
  return out;
}

/// 追加 2 字节垃圾 + 1 字节计数(0x02)：multibyte 裁剪应去掉 3 字节。
List<int> withMultibyteTrailer(List<int> body) => [...body, 0xAA, 0xBB, 0x02];

void main() {
  group('PalmDOC 解压', () {
    test('字面量直通', () {
      final out = PalmDoc.decompress([0x41, 0x42, 0x43]);
      expect(out, [0x41, 0x42, 0x43]);
    });

    test('LZ77 回引', () {
      // "ABC" + LZ77 对（dist=3, len=6）→ ABCABCABC
      final pair = 0x8000 | (3 << 3) | (6 - 3);
      final data = [0x41, 0x42, 0x43, (pair >> 8) & 0xFF, pair & 0xFF];
      final out = PalmDoc.decompress(data);
      expect(String.fromCharCodes(out), 'ABCABCABC');
    });

    test('空格压缩 (0xC0+)', () {
      final out = PalmDoc.decompress([0xC0 | 0x41]);
      expect(String.fromCharCodes(out), ' A');
    });

    test('字面量计数 (1-8)', () {
      // 计数字节后跟恰好 count 个字面量
      final out = PalmDoc.decompress([0x02, 0x41, 0x42]);
      expect(String.fromCharCodes(out), 'AB');
    });
  });

  group('尾部 extra data 裁剪', () {
    test('multibyte overlap', () {
      final body = utf8('正文内容');
      final data = withMultibyteTrailer(body);
      final trimmed = MobiParser.trimTrailingForTest(data, 1);
      expect(trimmed, body);
    });

    test('无 flags 不裁剪', () {
      final body = [1, 2, 3, 4];
      expect(MobiParser.trimTrailingForTest(body, 0), body);
    });

    test('trailing entry（bit 2）', () {
      // bit2=4：尾部有 1 个 vwi 条目；条目大小 = 从尾往前连续低位字节个数
      // 中文 utf8 字节都带高位，可作扫描终止符
      final body = utf8('正文');
      final data = [...body, 0x05, 0x00];
      final trimmed = MobiParser.trimTrailingForTest(data, 4);
      expect(trimmed, body);
    });
  });

  group('MOBI 整体解析', () {
    late File file;
    setUp(() {
      file = File(
          '${Directory.systemTemp.path}/moyue_test_${DateTime.now().millisecondsSinceEpoch}.mobi');
    });
    tearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    test('解析两章 MOBI（无压缩 + multibyte 尾部）', () {
      // 记录是首尾相接的 HTML 流：开篇后换行，再出现两章
      final rec1 = withMultibyteTrailer(utf8('这是开篇介绍。\n'));
      final rec2 = withMultibyteTrailer(utf8('第1章 起点\n主角出场了。\n第2章 风波\n剧情推进了。'));
      file.writeAsBytesSync(buildMobi([rec1, rec2]));
      final book = MobiParser.parse(file);
      expect(book.chapters.length, 3); // 开篇 + 2 章
      expect(book.chapters[0].title, '开篇');
      expect(book.chapters[1].title, '第1章 起点');
      expect(book.chapters[1].text, contains('主角出场了'));
      expect(book.chapters[2].title, '第2章 风波');
      expect(book.chapters[2].text, contains('剧情推进了'));
    });

    test('HUFF/CDIC 压缩抛出友好错误', () {
      file.writeAsBytesSync(buildMobi([utf8('x' * 20)], compression: 17480));
      expect(() => MobiParser.parse(file),
          throwsA(isA<MobiUnsupportedException>()));
    });
  });
}
