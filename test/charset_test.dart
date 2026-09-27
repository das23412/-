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

  test('UTF-8 混入单个坏字节：容忍解码而非整本回退 GBK', () {
    // 长文本：单个坏字节的替换率才会低于阈值（短串会走 GBK 回退）
    final text = '这是正文第一段，情节正常推进。第二段继续叙事。' * 60;
    final bytes = utf8.encode(text);
    bytes[10] = 0xFF; // 单个非法字节（'文' 的中间字节被覆写，无法还原）
    final decoded = CharsetDecoder.decode(bytes);
    expect(decoded, contains('这是正'));
    expect(decoded, contains('情节正常推进'));
    expect(decoded, contains('第二段继续叙事'));
  });

  test('大面积损坏仍回退 GBK', () {
    // GBK: 测=B2E2 试=CAD4，混入 0xFF 后仍大量非法 → 容忍解码替换率过高 → GBK
    final bytes = [0xB2, 0xE2, 0xCA, 0xD4, 0xFF, 0xB5, 0xDA, 0xD2, 0xBB];
    final decoded = CharsetDecoder.decode(bytes);
    expect(decoded, contains('测'));
  });
}
