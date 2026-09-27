import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/db.dart';
import '../data/settings.dart';
import '../source/book_source.dart';

/// 书源状态：书源列表、导入、启用/禁用、删除。
class SourceState extends ChangeNotifier {
  final AppDb _db = AppDb.instance;
  final AppSettings settings = AppSettings.instance;

  List<BookSource> sources = [];
  bool loading = false;

  /// 最近一次导入的摘要（供界面展示）。
  String importSummary = '';

  List<BookSource> get enabledSources =>
      sources.where((s) => s.enabled).toList(growable: false);

  BookSource? byId(String id) {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> reload() async {
    loading = true;
    notifyListeners();
    try {
      final rows = await _db.allSourceRows();
      final list = <BookSource>[];
      for (final r in rows) {
        try {
          final raw = r['raw'] as String? ?? '';
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            final s = BookSource.fromLegadoJson(decoded);
            if (s != null) {
              s.enabled = (r['enabled'] as int? ?? 1) == 1;
              list.add(s);
            }
          }
        } catch (_) {
          // 单条损坏不影响其他书源
        }
      }
      sources = list;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 导入一段书源文本，返回摘要信息。单条写入失败不影响其余。
  Future<String> importText(String text) async {
    final errors = <String>[];
    List<BookSource> parsed;
    try {
      parsed = BookSource.parseMany(text, errors: errors);
    } catch (e) {
      importSummary = '书源解析失败：$e';
      notifyListeners();
      return importSummary;
    }
    if (parsed.isEmpty) {
      importSummary = errors.isEmpty
          ? '没有解析到任何书源，请检查格式'
          : '${errors.length} 条无法解析（缺 bookSourceUrl 或 searchUrl）';
      notifyListeners();
      return importSummary;
    }
    // Set 查重：已存在的书源保留启用状态（覆盖更新规则内容）
    final existingEnabled = <String, bool>{
      for (final s in sources) s.id: s.enabled,
    };
    final now = DateTime.now().millisecondsSinceEpoch;
    var failed = 0;
    for (final s in parsed) {
      try {
        await _db.upsertSource(
          id: s.id,
          name: s.name,
          group: s.group,
          enabled: existingEnabled[s.id] ?? true,
          raw: s.rawJson,
          addedAt: now,
        );
      } catch (_) {
        failed++;
      }
    }
    await reload();
    importSummary = '成功导入 ${parsed.length} 个书源'
        '${errors.isEmpty ? '' : '，${errors.length} 条无法解析'}'
        '${failed == 0 ? '' : '，$failed 条写入失败'}';
    notifyListeners();
    return importSummary;
  }

  Future<void> setEnabled(BookSource s, bool v) async {
    s.enabled = v;
    await _db.setSourceEnabled(s.id, v);
    notifyListeners();
  }

  Future<void> delete(BookSource s) async {
    await _db.deleteSource(s.id);
    sources.removeWhere((e) => e.id == s.id);
    notifyListeners();
  }
}
