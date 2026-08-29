import 'package:flutter_test/flutter_test.dart';
import 'package:moyue/services/download_service.dart';

void main() {
  group('链接解析', () {
    test('补全协议', () {
      final u = DownloadService.tryParseUrl('example.com/book.txt');
      expect(u?.scheme, 'https');
      expect(u?.host, 'example.com');
    });

    test('保留 http 明文协议', () {
      final u = DownloadService.tryParseUrl('http://example.com/book.txt');
      expect(u?.scheme, 'http');
    });

    test('拒绝空与非法输入', () {
      expect(DownloadService.tryParseUrl(''), isNull);
      expect(DownloadService.tryParseUrl('ftp://a.com/f.txt'), isNull);
      expect(DownloadService.tryParseUrl('   '), isNull);
    });
  });

  group('文件名解析', () {
    test('Content-Disposition 普通引号形式', () {
      final name = DownloadService.extractFilename(
        headers: {
          'content-disposition': 'attachment; filename="我的小说.txt"',
        },
        uri: Uri.parse('https://a.com/download/123'),
      );
      expect(name, '我的小说.txt');
    });

    test('Content-Disposition RFC5987 UTF-8 编码', () {
      final name = DownloadService.extractFilename(
        headers: {
          'content-disposition':
              "attachment; filename*=UTF-8''%E6%96%97%E7%A0%B4.txt",
        },
        uri: Uri.parse('https://a.com/download/123'),
      );
      expect(name, '斗破.txt');
    });

    test('无头时从 URL 路径推断（含百分号编码）', () {
      final name = DownloadService.extractFilename(
        uri: Uri.parse('https://a.com/files/%E4%B8%80%E5%BF%B5%E6%B0%B8%E6%81%92.epub?token=1'),
      );
      expect(name, '一念永恒.epub');
    });

    test('URL 路径忽略查询参数', () {
      final name = DownloadService.extractFilename(
        uri: Uri.parse('https://a.com/get?file=book.txt'),
      );
      // 路径最后一段是 "get"，无扩展名 → 交由后续格式校验拒绝
      expect(name.contains('.txt'), isFalse);
    });

    test('非法字符清洗', () {
      final name = DownloadService.extractFilename(
        headers: {
          'content-disposition': 'attachment; filename="a:b*c?.txt"',
        },
        uri: Uri.parse('https://a.com/x'),
      );
      expect(name, 'a_b_c_.txt');
    });

    test('兜底文件名', () {
      final name = DownloadService.extractFilename(
        uri: Uri.parse('https://a.com/'),
      );
      expect(name, isNotEmpty);
    });
  });
}
