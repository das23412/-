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

  String get layoutKey =>
      '${settings.fontSize}_${settings.lineHeight}_${settings.indent}_$fontReady';

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
    final picked = await FilePicker.pickFiles(
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
    settings.customFontPath = '';
    fontReady = false;
    notifyListeners();
  }

  /// 选择自定义背景图。返回 null 表示成功。
  Future<String?> pickCustomBackground() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
    );
    final path = picked?.files.single.path;
    if (path == null) return null;
    try {
      final doc = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(doc.path, 'backgrounds'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final dest =
          p.join(dir.path, 'custom_bg${p.extension(path).toLowerCase()}');
      await File(path).copy(dest);
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
