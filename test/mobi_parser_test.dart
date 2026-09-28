import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/parser/mobi_parser.dart';

const int _mobiHeaderLen = 0xF8; // 248

/// 构造最小合法 MOBI：PDB 头 + record0（PalmDOC头 + MOBI头）+ 文本记录。
/// [headerLength] 可指定 MOBI 头长度；[extraFlags] 按 2 字节写入
/// record0 偏移 16+0xF2（仅当 headerLength 覆盖该偏移时生效）。
Uint8List buildMobi(
  List<List<int>> textRecords, {
  int compression = 1,
  int headerLength = _mobiHeaderLen,
  int extraFlags = 0,
}) {
  final numRecords = 1 + textRecords.length;

  // record 0
  final b = BytesBuilder();
  b.add([(compression >> 8) & 0xFF, compression & 0xFF]); // compression
  b.add([0, 0]); // unused
  b.add([0, 0, 0, 0]); // text length（解析器不校验，占位）
  b.add([(textRecords.length >> 8) & 0xFF, textRecords.length & 0xFF]);
  b.add([0x10, 0x00]); // recordSize = 4096
  b.add([0, 0]); // encryption = 0
  b.add([0, 0]); // unknown
  b.add(_four('MOBI'));
  b.add([
    (headerLength >> 24) & 0xFF,
    (headerLength >> 16) & 0xFF,
    (headerLength >> 8) & 0xFF,
    headerLength & 0xFF,
  ]);
  b.add([0, 0, 0, 2]); // mobiType = 2
  b.add([0, 0, 0xFD, 0xE9]); // textEncoding = 65001
  b.add(List<int>.filled(4, 0)); // uniqueID
  b.add(List<int>.filled(4, 0)); // fileVersion
  final current = b.length;
  b.add(List<int>.filled(headerLength - (current - 16), 0));
  final record0 = b.toBytes();
  // extra data flags：2 字节大端 @ record0 绝对偏移 0xF2
  final flagsOffset = 0xF2;
  record0[flagsOffset] = (extraFlags >> 8) & 0xFF;
  record0[flagsOffset + 1] = extraFlags & 0xFF;
  // MOBI header version @ 绝对偏移 0x68（flags 存在条件之一是 version >= 5）
  record0[0x68] = 0;
  record0[0x69] = 0;
  record0[0x6A] = 0;
  record0[0x6B] = 6; // version 6

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

List<int> utf8(String s) => const Utf8Codec().encode(s);

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
  });

  group('尾部 extra data 裁剪（按规格反向变长整数）', () {
    test('无 flags 不裁剪', () {
      final body = [1, 2, 3, 4];
      expect(MobiParser.trimTrailingForTest(body, 0), body);
    });

    test('multibyte overlap（bit 0，位于 trailing entries 之前）', () {
      final body = utf8('正文内容');
      // flags=1 → multibyte：(倒数第 1 字节 & 0x3) + 1 = 3 字节
      final data = [...body, 0xAA, 0xBB, 0x02];
      expect(MobiParser.trimTrailingForTest(data, 1), body);
    });

    test('单字节反向变长整数（尾字节=低位：值 2 → 裁 2 字节）', () {
      final body = utf8('正文');
      // entry：文件序 [0xAA(payload), 0x82(终止字节, 低 7 位=2)]
      // 解码值 2 = 该 entry 总字节数（含变长整数本身）
      final data = [...body, 0xAA, 0x82];
      expect(MobiParser.trimTrailingForTest(data, 2), body);
    });

    test('双字节反向变长整数（值 130 → 裁 130 字节）', () {
      final body = utf8('正文');
      // 值 130：尾字节=低 7 位(2)，前一字节=高 7 位(1)|0x80 → 文件序 [0x81, 0x02]
      final payload = List<int>.filled(128, 0xAA);
      final data = [...body, ...payload, 0x81, 0x02];
      expect(MobiParser.trimTrailingForTest(data, 2), body);
    });

    test('畸形数据（无终止字节）放弃裁剪而非崩溃', () {
      final data = [0x0F, 0x0E, 0x0D];
      expect(MobiParser.trimTrailingForTest(data, 2), data);
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

    test('解析两章 MOBI（无压缩）', () {
      final rec1 = utf8('这是开篇介绍。\n');
      final rec2 = utf8('第1章 起点\n主角出场了。\n第2章 风波\n剧情推进了。');
      file.writeAsBytesSync(buildMobi([rec1, rec2]));
      final book = MobiParser.parse(file);
      expect(book.chapters.length, 3); // 开篇 + 2 章
      expect(book.chapters[0].title, '开篇');
      expect(book.chapters[1].title, '第1章 起点');
      expect(book.chapters[1].text, contains('主角出场了'));
      expect(book.chapters[2].title, '第2章 风波');
      expect(book.chapters[2].text, contains('剧情推进了'));
    });

    test('跨记录的汉字不被切碎（整流解码）', () {
      // 构造一条中文语句，在某个汉字的 UTF-8 字节中间切开成两条记录：
      // 逐记录解码会在边界产生替换符/乱码；整体解码必须完整还原。
      const sentence = '这是跨记录测试：汉字必须完整无缺，不能出现任何乱码。';
      final bytes = utf8(sentence);
      // 找到第一个"续字节"（10xxxxxx）作为切分点 → 记录边界切在汉字内部
      var cut = 2;
      while (cut < bytes.length && (bytes[cut] & 0xC0) != 0x80) {
        cut++;
      }
      expect((bytes[cut] & 0xC0) == 0x80, isTrue,
          reason: '切分点应位于多字节字符内部');
      final rec1 = bytes.sublist(0, cut);
      final rec2 = bytes.sublist(cut);
      file.writeAsBytesSync(buildMobi([rec1, rec2]));
      final book = MobiParser.parse(file);
      final all = book.chapters.map((c) => c.text).join('\n');
      expect(all, contains(sentence));
      expect(all.contains('\uFFFD'), isFalse);
    });

    test('extraFlags（2 字节 @0xF2）正确读取并裁剪尾部', () {
      // headerLength 默认 0xF8 覆盖 0xF2；flags bit1 → 记录尾部
      // [0xAA, 0x82]：反向变长整数（终止字节低 7 位=2）+ 1 字节 payload
      final rec = [...utf8('第1章 起点\n主角出场了。'), 0xAA, 0x82];
      file.writeAsBytesSync(
          buildMobi([rec], extraFlags: 2));
      final book = MobiParser.parse(file);
      expect(book.chapters, isNotEmpty);
      expect(book.chapters.last.text, isNot(contains('\uFFFD')));
      final joined = book.chapters.map((c) => c.text).join();
      expect(joined.contains('主角出场了'), isTrue);
    });

    test('HUFF/CDIC 压缩抛出友好错误', () {
      file.writeAsBytesSync(buildMobi([utf8('x' * 20)], compression: 17480));
      expect(() => MobiParser.parse(file),
          throwsA(isA<MobiUnsupportedException>()));
    });
  });
}
