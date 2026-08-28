import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/core/charset.dart';

void main() {
  test('UTF-8 无 BOM', () {
    final bytes = utf8.encode('第一章 测试内容 Hello 123');
    expect(CharsetDecoder.decode(bytes), '第一章 测试内容 Hello 123');
  });

  test('UTF-8 带 BOM', () {
    final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('正文内容ABC')];
    expect(CharsetDecoder.decode(bytes), '正文内容ABC');
  });

  test('GBK 简体中文（无 BOM，非法 UTF-8）', () {
    // GBK: 测=B2E2 试=CAD4
    final bytes = [0xB2, 0xE2, 0xCA, 0xD4];
    expect(CharsetDecoder.decode(bytes), '测试');
  });

  test('GBK 中英混排', () {
    // GBK: 你=C4E3 好=BAC3
    final bytes = [0xC4, 0xE3, 0xBA, 0xC3, 0x41, 0x42, 0x43];
    expect(CharsetDecoder.decode(bytes), '你好ABC');
  });

  test('GBK 常见章节标题字节', () {
    // GBK: 第=B5DA 一=D2BB 章=D5C2
    final bytes = [0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20, 0x31];
    expect(CharsetDecoder.decode(bytes), '第一章 1');
  });

  test('UTF-16LE BOM', () {
    const text = 'ABC你好';
    final bytes = <int>[0xFF, 0xFE];
    for (final cu in text.codeUnits) {
      bytes
        ..add(cu & 0xFF)
        ..add((cu >> 8) & 0xFF);
    }
    expect(CharsetDecoder.decode(bytes), text);
  });

  test('UTF-16BE BOM', () {
    const text = 'DE测试';
    final bytes = <int>[0xFE, 0xFF];
    for (final cu in text.codeUnits) {
      bytes
        ..add((cu >> 8) & 0xFF)
        ..add(cu & 0xFF);
    }
    expect(CharsetDecoder.decode(bytes), text);
  });

  test('空字节', () {
    expect(CharsetDecoder.decode(const []), '');
  });
}
