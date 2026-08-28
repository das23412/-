import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'data/db.dart';
import 'data/settings.dart';
import 'platform/intent_channel.dart';
import 'state/library_state.dart';
import 'state/reader_config.dart';
import 'state/theme_state.dart';
import 'ui/bookshelf_page.dart';
import 'ui/reader_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.init();
  runApp(const MoyueApp());
}

class MoyueApp extends StatelessWidget {
  const MoyueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeState()),
        ChangeNotifierProvider(create: (_) => LibraryState()),
        ChangeNotifierProvider(create: (_) => ReaderConfig()),
      ],
      child: Consumer<ThemeState>(
        builder: (ctx, theme, _) => MaterialApp(
          title: '墨阅',
          navigatorKey: navigatorKey,
          theme: ThemeData(
            colorScheme: .fromSeed(seedColor: const Color(0xFF00695C)),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: .fromSeed(
                seedColor: const Color(0xFF00695C), brightness: Brightness.dark),
            useMaterial3: true,
          ),
          themeMode: theme.mode,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const GatePage(),
        ),
      ),
    );
  }
}

/// 启动引导：权限说明 → 首次扫描 → 其他App打开的文件接管。
class GatePage extends StatefulWidget {
  const GatePage({super.key});

  @override
  State<GatePage> createState() => _GatePageState();
}

class _GatePageState extends State<GatePage> {
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    if (_booted) return;
    _booted = true;

    // 1. 其他 App 传来的文件（无需存储权限，原生层已拷贝到应用缓存）
    final intentPath = await IntentChannel.initialFilePath();
    IntentChannel.onNewFilePath((path) async {
      final ctx = navigatorKey.currentContext;
      if (ctx == null) return;
      final libState = ctx.read<LibraryState>();
      await libState.importFromIntent(path);
      await _openImported(path);
    });

    // 2. 存储权限（仅用于全盘扫描；拒绝也不影响手动导入）
    final settings = AppSettings.instance;
    final manage = await Permission.manageExternalStorage.status;
    if (!manage.isGranted) {
      final legacyGranted = await Permission.storage.request().then(
            (s) => s.isGranted,
            onError: (_) => false,
          );
      if (!legacyGranted && mounted) {
        await _explainPermission();
        await Permission.manageExternalStorage.request();
      }
    }

    // 3. 首次启动自动全盘扫描
    if (!settings.firstScanDone && mounted) {
      final doScan = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('开始扫描？'),
          content: const Text(
              '墨阅可以在本机存储中查找小说文件（TXT / EPUB / MOBI / AZW3 / FB2 / HTML）。\n\n扫描只在本机完成，墨阅不会连接网络，也不会上传任何数据。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后再说'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始扫描'),
            ),
          ],
        ),
      );
      if (doScan == true && mounted) {
        // ignore: use_build_context_synchronously
        context.read<LibraryState>().scan(fullScan: true);
      }
    }

    // 4. 启动即带文件打开
    if (intentPath != null && mounted) {
      await context.read<LibraryState>().reload();
      await _openImported(intentPath);
    }
  }

  Future<void> _openImported(String path) async {
    final book = await AppDb.instance.bookByPath(path);
    final ctx = navigatorKey.currentContext;
    if (book == null || !ctx!.mounted) return;
    Navigator.of(ctx).push(
      MaterialPageRoute(builder: (_) => ReaderPage(book: book)),
    );
  }

  Future<void> _explainPermission() {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要“所有文件访问”权限'),
        content: const Text(
            '全盘扫描手机里的小说需要授予“所有文件访问”权限。\n\n'
            '· 墨阅完全离线，绝不会联网上传你的任何数据\n'
            '· 只读取小说格式文件，不改写你的文件\n'
            '· 拒绝授权仍可使用“手动导入”功能'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('暂不授权'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const BookshelfPage();
  }
}
