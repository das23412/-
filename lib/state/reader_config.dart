import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/settings.dart';

/// 阅读器配置状态：字号、行距、翻页模式、背景、自定义字体。
class ReaderConfig extends ChangeNotifier {
  final AppSettings settings = AppSettings.instance;
  bool fontReady = false;

  /// 自定义字体指纹（路径 + 文件大小）：换字体后 key 变化，
  /// invalidateLayouts 才能真正清掉按旧字体排出的版式。
  String get fontKey {
    final path = settings.customFontPath;
    if (path.isEmpty) return '';
    int size = 0;
    try {
      size = File(path).lengthSync();
    } catch (_) {
      // 字体文件可能已被移动或删除：退化为 0，仅靠路径参与 key
    }
    return '$path|$size';
  }

  String get layoutKey =>
      '${settings.fontSize}_${settings.lineHeight}_${settings.indent}_$fontReady'
      '_${fontKey.hashCode}';

  void setFontSize(double v) {
    settings.fontSize = v;
    notifyListeners();
  }

  void setLineHeight(double v) {
    settings.lineHeight = v;
    notifyListeners();
  }

  void setIndent(bool v) {
    settings.indent = v;
    notifyListeners();
  }

  void setPageMode(int v) {
    settings.pageMode = v;
    notifyListeners();
  }

  void setBgIndex(int v) {
    settings.bgIndex = v;
    notifyListeners();
  }

  void setDarkFollowNight(bool v) {
    settings.darkBgInNight = v;
    notifyListeners();
  }

  /// 启动时加载自定义字体。
  Future<void> loadFont() async {
    final path = settings.customFontPath;
    if (path.isEmpty || !File(path).existsSync()) {
      fontReady = false;
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      final loader = FontLoader('MoyueCustom')
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      fontReady = true;
    } catch (_) {
      fontReady = false;
    }
    notifyListeners();
  }

  /// 选择并导入 .ttf/.otf 字体。返回 null 表示成功，否则为错误信息。
  Future<String?> pickCustomFont() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ttf', 'otf'],
    );
    final path = picked?.files.single.path;
    if (path == null) return null;
    final src = File(path);
    if (!src.existsSync()) return '文件不存在';
    try {
      final doc = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(doc.path, 'fonts'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final dest =
          p.join(dir.path, 'custom_font${p.extension(path).toLowerCase()}');
      await src.copy(dest);
      settings.customFontPath = dest;
      await loadFont();
      return null;
    } catch (e) {
      return '导入失败：$e';
    }
  }

  Future<void> clearCustomFont() async {
    // 旧字体文件只在应用文档目录内才删；用户外部原文件一律不动
    await _deleteIfInAppDocs(settings.customFontPath);
    settings.customFontPath = '';
    fontReady = false;
    notifyListeners();
  }

  /// 删除应用文档目录内的残留文件；目录外路径（用户自选的原文件）不动。
  Future<void> _deleteIfInAppDocs(String path) async {
    if (path.isEmpty) return;
    try {
      final root = p.normalize((await getApplicationDocumentsDirectory()).path);
      final target = p.normalize(path);
      if (!target.startsWith('$root$p.separator')) return;
      final f = File(target);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // 清理失败不影响主流程
    }
  }

  /// 选择自定义背景图。返回 null 表示成功。
  Future<String?> pickCustomBackground() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
    );
    final path = picked?.files.single.path;
    if (path == null) return null;
    try {
      final doc = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(doc.path, 'backgrounds'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      // 文件名带时间戳：二次导入同格式图片时路径变化，
      // 否则 FileImage 按路径相等性命中旧缓存，界面一直显示旧背景
      final dest = p.join(dir.path,
          'custom_bg_${DateTime.now().millisecondsSinceEpoch}${p.extension(path).toLowerCase()}');
      await File(path).copy(dest);
      // 旧的固定名背景文件清理（历史版本写入的）
      final legacy = File(p.join(dir.path, 'custom_bg.jpg'));
      if (legacy.existsSync()) legacy.deleteSync();
      // 上一张自定义背景（应用文档目录内的）一并删除，多次导入不残留旧文件
      final oldBg = settings.customBgPath;
      if (oldBg.isNotEmpty && oldBg != dest) {
        await _deleteIfInAppDocs(oldBg);
      }
      settings.customBgPath = dest;
      settings.bgIndex = -1;
      notifyListeners();
      return null;
    } catch (e) {
      return '设置失败：$e';
    }
  }

  Future<void> clearCustomBackground() async {
    settings.customBgPath = '';
    if (settings.bgIndex == -1) settings.bgIndex = 1;
    notifyListeners();
  }
}
