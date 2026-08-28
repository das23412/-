import 'dart:io';

import '../core/book_format.dart';
import '../core/text_utils.dart';

/// 扫描到的候选书。
class FoundBook {
  final String path;
  final String title;
  final BookFormat format;
  final int size;

  FoundBook(this.path, this.title, this.format, this.size);

  Map<String, Object?> toMap() =>
      {'path': path, 'title': title, 'format': format.name, 'size': size};
}

/// 文件扫描服务：在指定根目录下递归寻找小说文件。
///
/// 设计为可在 isolate 中运行：只做 IO 与过滤，不触碰数据库。
class ScanService {
  /// 需要跳过的目录名。
  static const _skipDirs = {
    'android',
    'data',
    'obb',
    'dalvik-cache',
    'cache',
    'thumbnails',
    '.trash',
    'lost.dir',
    'alarms',
    'ringtones',
    'notifications',
    'podcasts',
    'moyue_import', // 应用自己的导入缓存
  };

  static bool _isHidden(String name) => name.startsWith('.');

  /// [roots] 为要扫描的根目录列表。
  static List<FoundBook> scan(List<String> roots) {
    final found = <FoundBook>[];
    final visited = <String>{};
    final stack = <Directory>[for (final r in roots) Directory(r)];

    while (stack.isNotEmpty) {
      final dir = stack.removeLast();
      final dirPath = dir.path;
      if (visited.contains(dirPath)) continue;
      visited.add(dirPath);
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        continue; // 无权限或目录消失
      }
      for (final e in entries) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is Directory) {
          final lower = name.toLowerCase();
          if (_isHidden(name) || _skipDirs.contains(lower)) continue;
          stack.add(e);
        } else if (e is File) {
          final format = BookFormat.fromPath(name);
          if (format == BookFormat.unknown) continue;
          final stat = e.statSync();
          if (stat.size < 512) continue; // 过小的碎片文件
          found.add(FoundBook(
            e.path,
            TextUtils.cleanTitle(name),
            format,
            stat.size,
          ));
        }
      }
    }
    return found;
  }

  /// 全盘扫描根（用户存储根目录）。
  static String get primaryRoot => '/storage/emulated/0';
}
