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

/// 一次扫描的完整报告，让“漏扫”看得见。
class ScanReport {
  final List<FoundBook> found;
  final List<String> roots; // 实际扫描的存储区
  final int dirsWalked; // 进入的目录数
  final int skippedDirs; // 按规则跳过的目录数
  final int unreadableDirs; // 因权限/IO 无法读取的目录数

  ScanReport({
    required this.found,
    required this.roots,
    required this.dirsWalked,
    required this.skippedDirs,
    required this.unreadableDirs,
  });
}

/// 文件扫描服务：在指定根目录下递归寻找小说文件。
///
/// 设计为可在 isolate 中运行：只做 IO 与过滤，不触碰数据库。
class ScanService {
  /// 无条件跳过的目录名（明确不会藏小说的系统/垃圾目录）。
  static const _skipDirs = {
    'android',
    'dalvik-cache',
    'lost.dir',
    'thumbnails',
    'moyue_import',
    'alarms',
    'ringtones',
    'notifications',
  };

  /// 是否应跳过 [name] 目录（[dirPath] 为其完整路径）。
  ///
  /// 注意：`data`/`obb`/`cache` 这类通用名字只在 Android/ 下才跳过，
  /// 不再误伤用户自建的同名目录（如 /storage/emulated/0/1122/data）。
  static bool _shouldSkipDir(String name, String dirPath) {
    if (name.startsWith('.')) return true;
    final lower = name.toLowerCase();
    if (_skipDirs.contains(lower)) return true;
    final parent = dirPath.toLowerCase();
    final inAndroidDir = parent.endsWith('/android') || parent.contains('/android/');
    if (inAndroidDir && (lower == 'data' || lower == 'obb')) {
      return true;
    }
    return false;
  }

  /// 枚举所有可用存储卷：内置存储 + SD 卡 + U 盘。
  static List<String> defaultRoots() {
    final roots = <String>['/storage/emulated/0'];
    try {
      for (final e in Directory('/storage').listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (name.startsWith('.') || name == 'emulated' || name == 'self') {
          continue;
        }
        roots.add(e.path);
      }
    } catch (_) {
      // /storage 不可枚举时至少保留主存储
    }
    return roots;
  }

  /// 扫描 [roots] 下的所有小说文件，返回带统计的报告。
  static ScanReport scan(List<String> roots) {
    final found = <FoundBook>[];
    final visited = <String>{};
    final stack = <Directory>[for (final r in roots) Directory(r)];
    int dirsWalked = 0;
    int skippedDirs = 0;
    int unreadableDirs = 0;

    while (stack.isNotEmpty) {
      final dir = stack.removeLast();
      final dirPath = dir.path;
      if (visited.contains(dirPath)) continue;
      visited.add(dirPath);
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        unreadableDirs++; // 无权限或目录消失：计入报告而不是静默吞掉
        continue;
      }
      dirsWalked++;
      for (final e in entries) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is Directory) {
          if (_shouldSkipDir(name, dirPath)) {
            skippedDirs++;
            continue;
          }
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
    return ScanReport(
      found: found,
      roots: roots,
      dirsWalked: dirsWalked,
      skippedDirs: skippedDirs,
      unreadableDirs: unreadableDirs,
    );
  }

  /// 全盘扫描主根（保留常量供外部引用）。
  static String get primaryRoot => '/storage/emulated/0';
}
