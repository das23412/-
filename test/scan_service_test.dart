import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/services/scan_service.dart';

void main() {
  group('目录跳过规则', () {
    test('存储根顶层的 android/data/obb 跳过', () {
      expect(ScanService.shouldSkipDirForTest('android', '/storage/emulated/0'), isTrue);
      expect(ScanService.shouldSkipDirForTest('Android', '/storage/emulated/0'), isTrue);
      expect(ScanService.shouldSkipDirForTest('data', '/storage/emulated/0/Android'), isTrue);
      expect(ScanService.shouldSkipDirForTest('obb', '/storage/emulated/0/Android'), isTrue);
      // U 盘（/storage/XXXX-YYYY）同样适用
      expect(ScanService.shouldSkipDirForTest('android', '/storage/0000-FFFF'), isTrue);
    });

    test('用户自建的同名目录不跳过', () {
      expect(ScanService.shouldSkipDirForTest('android', '/storage/emulated/0/我的书'), isFalse);
      expect(ScanService.shouldSkipDirForTest('data', '/storage/emulated/0/1122'), isFalse);
      expect(ScanService.shouldSkipDirForTest('obb', '/storage/0000-FFFF/自建'), isFalse);
      // 顶层 data/obb 之外的同名目录由 android 父目录规则兜底
      expect(ScanService.shouldSkipDirForTest('data', '/storage/emulated/0/data'), isFalse,
          reason: '根级 data 不是本策略的目标，避免误伤用户自建目录');
    });

    test('常规跳过与常规保留', () {
      expect(ScanService.shouldSkipDirForTest('.hidden', '/a'), isTrue);
      expect(ScanService.shouldSkipDirForTest('thumbnails', '/a'), isTrue);
      expect(ScanService.shouldSkipDirForTest('我的小说', '/a'), isFalse);
    });
  });

  group('目录扫描', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('moyue_scan_test_');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('命中书籍、跳过过小文件、用户自建 android 不漏扫', () async {
      final books = Directory('${root.path}/books');
      books.createSync(recursive: true);
      File('${books.path}/书A.txt').writeAsStringSync('x' * 600);
      Directory('${books.path}/android').createSync();
      File('${books.path}/android/书B.txt').writeAsStringSync('x' * 600);
      File('${root.path}/small.txt').writeAsStringSync('x' * 10);
      File('${root.path}/书C.epub').writeAsStringSync('x' * 600);

      final report = ScanService.scan([root.path]);
      final paths = report.found.map((f) => f.path).toSet();
      expect(paths, contains('${books.path}/书A.txt'));
      expect(paths, contains('${books.path}/android/书B.txt'),
          reason: '用户自建 android 目录不应整树漏扫');
      expect(paths, contains('${root.path}/书C.epub'));
      expect(paths.any((p) => p.endsWith('small.txt')), isFalse);
      expect(report.dirsWalked, greaterThan(0));
    });
  });
}
