import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/book.dart';
import '../reader/paginate.dart';
import '../reader/turn_page/turn_page_view.dart';
import '../state/reader_config.dart';
import '../state/reader_state.dart';
import '../state/theme_state.dart';
import 'common.dart';

/// 阅读页。
///
/// 翻页采用“窗口式”结构：PageView 同时包含上一章、当前章、下一章的页面，
/// 滑动可以无缝跨越章节边界（与番茄/起点等主流阅读器一致）。
class ReaderPage extends StatefulWidget {
  final Book book;
  const ReaderPage({super.key, required this.book});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late final ReaderState rs;
  PageController? _pageController; // 覆盖/平移模式
  TurnPageController? _turnCtrl; // 仿真模式
  ScrollController? _scrollController;
  ChapterLayout? _layout; // 当前章布局
  ChapterLayout? _prevLayout; // 窗口内上一章布局
  ChapterLayout? _nextLayout; // 窗口内下一章布局
  int _windowChapter = -1;
  String _windowKey = '';
  int _winPrevCount = 0;
  int _winNextCount = 0;

  bool _menuVisible = false;
  bool _scrollAttached = false;
  int _restoredForChapter = -1;
  bool _pendingJumpEnd = false;
  int? _pendingCharOffset;
  EdgeInsets _pagePad = const EdgeInsets.fromLTRB(18, 40, 18, 28); // 页内文字边距
  int _lastPageMode = -1; // 检测翻页方式切换，重建控制器并回定位
  String _turnKey = ''; // 仿真翻页的重建钥匙（窗口 + 外观状态）
  String _prewarmedWindow = ''; // 已安排过空闲预排版的窗口钥匙
  double? _sliderPreview;
  String _sliderChapterLabel = '';
  int? _sliderChapter; // 在线书进度条拖动时的章号预览（1 基）

  @override
  void initState() {
    super.initState();
    rs = ReaderState(widget.book);
    rs.addListener(_rsChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_menuVisible) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    });
    final cfg = context.read<ReaderConfig>();
    cfg.loadFont().then((_) {
      if (mounted) {
        rs.invalidateLayouts(cfg.layoutKey);
        setState(() {});
      }
    });
    rs.load();
  }

  @override
  void dispose() {
    // rs.dispose() 内部会 saveNow，这里不必重复保存
    rs.dispose();
    _pageController?.dispose();
    _scrollController?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _rsChanged() {
    if (!mounted) return;
    // 纯翻页（页码变化）且菜单未打开时无需整页重建：页面内容由
    // PageView/TurnPageView 自行驱动，rs.currentPage 只影响菜单显示
    if (rs.lastChangePageOnly && !_menuVisible) return;
    setState(() {});
  }

  void _toggleMenu() {
    setState(() {
      _menuVisible = !_menuVisible;
      _sliderChapterLabel = '';
      _sliderPreview = null;
      _sliderChapter = null;
    });
    SystemChrome.setEnabledSystemUIMode(
      _menuVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  // ---------- 翻页 ----------

  void _handleTapUp(TapUpDetails d, BoxConstraints box) {
    final w = box.maxWidth;
    final dx = d.localPosition.dx;
    if (dx < w * 0.3) {
      _prev();
    } else if (dx > w * 0.7) {
      _next();
    } else {
      _toggleMenu();
    }
  }

  void _next() {
    final layout = _layout;
    if (layout == null) return;
    final mode = context.read<ReaderConfig>().settings.pageMode;
    if (mode == 3) {
      _scrollToNextPage(layout);
      return;
    }
    if (mode == 0) {
      final ctrl = _turnCtrl;
      if (ctrl == null) return;
      if (ctrl.currentIndex < _windowTotal - 1) {
        ctrl.nextPage();
        _syncProgressAt(ctrl.currentIndex);
      } else if (rs.currentChapter < rs.chapters.length - 1) {
        _goChapter(rs.currentChapter + 1);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已经是最后一页了'), duration: Duration(milliseconds: 600)));
      }
      return;
    }
    final pc = _pageController;
    if (pc == null || !pc.hasClients) return;
    final cur = pc.page?.round() ?? 0;
    final total = _winPrevCount + layout.pageCount + _winNextCount;
    if (cur < total - 1) {
      pc.animateToPage(cur + 1,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    } else if (rs.currentChapter < rs.chapters.length - 1) {
      _goChapter(rs.currentChapter + 1);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已经是最后一页了'), duration: Duration(milliseconds: 600)));
    }
  }

  void _prev() {
    final layout = _layout;
    if (layout == null) return;
    final mode = context.read<ReaderConfig>().settings.pageMode;
    if (mode == 3) {
      _scrollToPrevPage(layout);
      return;
    }
    if (mode == 0) {
      final ctrl = _turnCtrl;
      if (ctrl == null) return;
      if (ctrl.currentIndex > 0) {
        ctrl.previousPage();
        _syncProgressAt(ctrl.currentIndex);
      } else if (rs.currentChapter > 0) {
        _pendingJumpEnd = true;
        _goChapter(rs.currentChapter - 1);
      }
      return;
    }
    final pc = _pageController;
    if (pc == null || !pc.hasClients) return;
    final cur = pc.page?.round() ?? 0;
    if (cur > 0) {
      pc.animateToPage(cur - 1,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    } else if (rs.currentChapter > 0) {
      _pendingJumpEnd = true;
      _goChapter(rs.currentChapter - 1);
    }
  }

  void _scrollToNextPage(ChapterLayout layout) {
    final sc = _scrollController;
    if (sc == null || !sc.hasClients) return;
    final target = (sc.offset + layout.lineHeight * layout.linesPerPage)
        .clamp(0.0, sc.position.maxScrollExtent);
    sc.animateTo(target,
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  void _scrollToPrevPage(ChapterLayout layout) {
    final sc = _scrollController;
    if (sc == null || !sc.hasClients) return;
    final target = (sc.offset - layout.lineHeight * layout.linesPerPage)
        .clamp(0.0, sc.position.maxScrollExtent);
    sc.animateTo(target,
        duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
  }

  void _goChapter(int idx, {int? charOffset}) {
    // 同章内按字符偏移跳转：直接翻到对应页，无需重载章节
    if (idx == rs.currentChapter &&
        charOffset != null &&
        _layout != null &&
        rs.chapters.isNotEmpty) {
      final layout = _layout!;
      final line = layout.lineIndexOfChar(charOffset);
      final pageInChapter = layout.pageOfLine(line);
      final windowIndex = _winPrevCount + pageInChapter;
      if (context.read<ReaderConfig>().settings.pageMode == 3) {
        final sc = _scrollController;
        if (sc != null && sc.hasClients) {
          sc.jumpTo((pageInChapter * layout.linesPerPage * layout.lineHeight)
              .clamp(0.0, sc.position.maxScrollExtent));
        }
      } else if (context.read<ReaderConfig>().settings.pageMode == 0) {
        _turnCtrl?.jumpToPage(windowIndex.clamp(0, _windowTotal - 1));
      } else if (_pageController?.hasClients ?? false) {
        _pageController!.jumpToPage(windowIndex.clamp(0, _windowTotal - 1));
      }
      rs.onPageChanged(idx, pageInChapter, charOffset);
      return;
    }
    _pendingCharOffset = charOffset;
    _pendingJumpEnd = charOffset == null && _pendingJumpEnd;
    rs.goToChapter(idx, charOffset: charOffset ?? 0);
  }

  int get _windowTotal =>
      _winPrevCount + (_layout?.pageCount ?? 0) + _winNextCount;

  // ---------- 构建 ----------

  TextStyle _style(ReaderConfig cfg, ReaderPalette palette) => TextStyle(
        fontSize: cfg.settings.fontSize,
        height: cfg.settings.lineHeight,
        color: palette.text,
        fontFamily: cfg.fontReady ? 'MoyueCustom' : null,
      );

  /// 页面背景装饰：色卡或自定义图片（全屏不透明页面必须自带背景）。
  /// 文件存在性只查一次并缓存：每个页 itemBuilder 都 existsSync 是纯浪费。
  File? _bgFileCached;
  String? _bgCheckedPath;

  File? _resolveBackgroundFile(String bgPath) {
    if (_bgCheckedPath != bgPath) {
      _bgCheckedPath = bgPath;
      final f = File(bgPath);
      _bgFileCached = f.existsSync() ? f : null;
    }
    return _bgFileCached;
  }

  Decoration _pageDecoration(ReaderConfig cfg, ReaderPalette palette) {
    final bgPath = cfg.settings.customBgPath;
    if (cfg.settings.bgIndex == -1 && bgPath.isNotEmpty) {
      final f = _resolveBackgroundFile(bgPath);
      if (f != null) {
        return BoxDecoration(
          image: DecorationImage(image: FileImage(f), fit: BoxFit.cover),
        );
      }
    }
    return BoxDecoration(color: palette.background);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<ReaderConfig>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final palette = _effectivePalette(cfg, isDark);

    return Scaffold(
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        color: palette.background,
        child: SafeArea(
          top: false,
          child: Stack(
            children: [
              if (rs.loading)
                const Center(child: CircularProgressIndicator())
              else if (rs.error != null)
                _errorView()
              else
                LayoutBuilder(
                  builder: (ctx, box) => _content(ctx, box, cfg, palette),
                ),
              if (rs.chapterLoading)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (_menuVisible) _menuOverlay(cfg, palette, isDark),
            ],
          ),
        ),
      ),
    );
  }

  ReaderPalette _effectivePalette(ReaderConfig cfg, bool isDark) {
    if (isDark && cfg.settings.darkBgInNight) return readerPalettes[4];
    final idx = cfg.settings.bgIndex;
    if (idx >= 0 && idx < readerPalettes.length) return readerPalettes[idx];
    return readerPalettes[1];
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(rs.error ?? '未知错误', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回书架'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => rs.load(),
                  child: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(
      BuildContext ctx, BoxConstraints box, ReaderConfig cfg, ReaderPalette palette) {
    // 页面全屏铺满（翻页效果覆盖整屏），文字边距画在页面内部
    _pagePad = EdgeInsets.fromLTRB(
        18, MediaQuery.of(ctx).padding.top + 36, 18, 28);
    // 翻页方式切换：重建各翻页控制器，并把落点重定位到当前进度
    if (_lastPageMode != cfg.settings.pageMode) {
      _lastPageMode = cfg.settings.pageMode;
      final oldPage = _pageController;
      final oldScroll = _scrollController;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 旧组件当帧仍引用旧控制器，延后一帧释放，避免 detach 中途 dispose
        oldPage?.dispose();
        oldScroll?.dispose();
      });
      _pageController = null;
      _scrollController = null;
      _scrollAttached = false;
      // 旧 TurnPageView 卸载时会自行 dispose 旧控制器，这里只脱离引用
      _turnCtrl = null;
      _restoredForChapter = -1;
      _pendingCharOffset = rs.charOffsetInChapter;
    }
    final textWidth = box.maxWidth - _pagePad.horizontal;
    final textHeight = box.maxHeight - _pagePad.vertical;
    final style = _style(cfg, palette);
    final layout = rs.layoutFor(
        rs.currentChapter, style, textWidth, textHeight, cfg.settings.indent);
    _layout = layout;

    // 窗口计算：把上一章/下一章的页面拼进同一个 PageView。
    // 键包含相邻章节正文长度：在线书正文按需到达时窗口要重建，
    // 否则残留"空正文"布局，跨章边界出现空白页。
    final windowKey = '${cfg.layoutKey}_${textWidth}x$textHeight'
        '_${rs.currentChapter}'
        '_${rs.chapterTextLength(rs.currentChapter - 1)}'
        '_${rs.chapterTextLength(rs.currentChapter)}'
        '_${rs.chapterTextLength(rs.currentChapter + 1)}';
    if (_windowChapter != rs.currentChapter || _windowKey != windowKey) {
      final sameChapter = _windowChapter == rs.currentChapter;
      final oldPrevCount = _winPrevCount;
      _windowKey = windowKey;
      _windowChapter = rs.currentChapter;
      _prevLayout = rs.currentChapter > 0
          ? rs.layoutFor(rs.currentChapter - 1, style, textWidth, textHeight,
              cfg.settings.indent)
          : null;
      _nextLayout = rs.currentChapter < rs.chapters.length - 1
          ? rs.layoutFor(rs.currentChapter + 1, style, textWidth, textHeight,
              cfg.settings.indent)
          : null;
      _winPrevCount = _prevLayout?.pageCount ?? 0;
      _winNextCount = _nextLayout?.pageCount ?? 0;
      _turnCtrl = null; // 窗口变化后重建仿真翻页控制器
      // 同一章内相邻正文到达导致前窗页数变化：把当前页对齐回同一视觉页，
      // 否则用户正在看的页会突然错位。
      if (sameChapter && _winPrevCount != oldPrevCount) {
        final delta = _winPrevCount - oldPrevCount;
        final pc = _pageController;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || pc == null || !pc.hasClients) return;
          final cur = pc.page?.round() ?? 0;
          pc.jumpToPage(
              (cur + delta).clamp(0, math.max(0, _windowTotal - 1)));
        });
      }
    }

    // 外观（背景/文字颜色/翻页方式）变化时重建仿真翻页，
    // 否则页面列表不刷新，会出现“背景换不了”的问题。
    // 钥匙变化必须连锁重建控制器（旧控制器已被旧组件释放）。
    final turnKey = 'turn${cfg.settings.pageMode}_'
        '${palette.background.toARGB32()}_${palette.text.toARGB32()}_'
        '${cfg.settings.bgIndex}_${cfg.settings.customBgPath}_$_windowKey';
    if (_turnKey != turnKey) {
      _turnKey = turnKey;
      _turnCtrl = null;
    }

    // 空闲时预排版前后的第 2 章（相邻章节已随当前窗口排好），
    // 翻到下一章的那一帧就不必再同步排版新章节
    _prewarmNeighbors(cfg, style, textWidth, textHeight);

    // 进度恢复 / 跳章 / 跨章滑动后的落点
    if (_restoredForChapter != rs.currentChapter ||
        _pendingCharOffset != null) {
      _restoredForChapter = rs.currentChapter;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        int pageInChapter;
        if (_pendingCharOffset != null) {
          final line = layout.lineIndexOfChar(_pendingCharOffset!);
          pageInChapter = layout.pageOfLine(line);
          _pendingCharOffset = null;
        } else if (_pendingJumpEnd) {
          pageInChapter = layout.pageCount - 1;
          _pendingJumpEnd = false;
        } else {
          pageInChapter = rs.restorePage(layout);
        }
        final target = ((_winPrevCount + pageInChapter)
                .clamp(0, math.max(0, _windowTotal - 1)))
            .toInt();
      if (cfg.settings.pageMode == 3) {
        final sc = _scrollController;
        if (sc != null && sc.hasClients) {
          sc.jumpTo((pageInChapter * layout.linesPerPage * layout.lineHeight)
              .clamp(0.0, sc.position.maxScrollExtent));
        }
      } else if (cfg.settings.pageMode == 0) {
          // 仿真模式：_pageController 不存在，必须驱动 TurnPageController，
          // 否则进度恢复完全失效且会反向覆盖真实进度
          _turnCtrl?.jumpToPage(target);
        } else if (_pageController?.hasClients ?? false) {
          _pageController!.jumpToPage(target);
        }
        rs.currentPage = pageInChapter;
      });
    }

    Widget body;
    switch (cfg.settings.pageMode) {
      case 0:
        body = _turnBody(palette, cfg);
      case 3:
        body = Padding(padding: _pagePad, child: _scrollBody(layout, palette, cfg));
      default:
        body = _pageBody(layout, palette, cfg);
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (d) => _handleTapUp(d, box),
      child: Stack(
        children: [
          Positioned.fill(child: _background(cfg, isDark: false)),
          Positioned.fill(child: body),
        ],
      ),
    );
  }

  /// 空闲时预热前后第 2 章：本地书预排版，在线书预取正文，
  /// 让翻章帧不必同步做重活。窗口（章节/尺寸/参数）已变化时任务放弃。
  void _prewarmNeighbors(
      ReaderConfig cfg, TextStyle style, double width, double height) {
    if (_prewarmedWindow == _windowKey) return;
    _prewarmedWindow = _windowKey;
    final chapter = rs.currentChapter;
    final windowKey = _windowKey;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      void warm(int idx) {
        SchedulerBinding.instance.scheduleTask(() {
          if (!mounted || _windowKey != windowKey) return;
          if (rs.isOnlineBook) {
            rs.preloadChapter(idx);
            return;
          }
          rs.layoutFor(idx, style, width, height, cfg.settings.indent);
        }, Priority.idle);
      }

      if (chapter + 2 < rs.chapters.length) warm(chapter + 2);
      if (chapter - 2 >= 0) warm(chapter - 2);
    });
  }

  Widget _background(ReaderConfig cfg, {required bool isDark}) {
    final bgPath = cfg.settings.customBgPath;
    if (cfg.settings.bgIndex == -1 && bgPath.isNotEmpty) {
      final file = _resolveBackgroundFile(bgPath);
      if (file != null) {
        return Stack(
          fit: StackFit.expand,
          children: [
            Image.file(file, fit: BoxFit.cover),
            if (isDark)
              Container(color: Colors.black.withValues(alpha: 0.55)),
          ],
        );
      }
    }
    return const SizedBox.shrink();
  }

  // ---------- 翻页模式（仿真 / 平移 / 覆盖） ----------

  /// 窗口索引 → 该页使用的布局、章内页码、章节序号。
  (ChapterLayout, int, int) _mapWindowIndex(int v) {
    final curCount = _layout?.pageCount ?? 0;
    if (v < _winPrevCount && _prevLayout != null) {
      return (_prevLayout!, v, rs.currentChapter - 1);
    }
    if (v < _winPrevCount + curCount || _nextLayout == null) {
      return (_layout!, v - _winPrevCount, rs.currentChapter);
    }
    return (
      _nextLayout!,
      v - _winPrevCount - curCount,
      rs.currentChapter + 1
    );
  }

  /// 把窗口索引 v 处的页面同步为当前阅读进度（跨章时自动切换章节）。
  void _syncProgressAt(int v) {
    final mapped = _mapWindowIndex(v);
    final lay = mapped.$1;
    final pageInChapter = mapped.$2;
    final chapterIdx = mapped.$3;
    final charOffset = lay.charOffsetOfLine(pageInChapter * lay.linesPerPage);
    if (chapterIdx == rs.currentChapter) {
      rs.onPageChanged(rs.currentChapter, pageInChapter, charOffset);
      return;
    }
    // 跨章滑动：切换章节，用 charOffset 在新窗口中精确定位落点页
    rs.goToChapter(chapterIdx, charOffset: charOffset);
    rs.onPageChanged(chapterIdx, pageInChapter, charOffset);
    _pendingCharOffset = charOffset;
  }

  /// 仿真模式：turn_page_transition 的 TurnPageView + 窗口式页面。
  /// （效果移植自开源库 turn_page_transition，MIT License，© Shoryu-Y）
  Widget _turnBody(ReaderPalette palette, ReaderConfig cfg) {
    _turnCtrl ??= TurnPageController(
        initialPage: (_winPrevCount + rs.currentPage)
            .clamp(0, math.max(0, _windowTotal - 1)));
    final style = _style(cfg, palette);
    // key 含外观状态：切换背景/主题时强制重建 TurnPageView 刷新页面外观
    return TurnPageView.builder(
      key: ValueKey(_turnKey),
      controller: _turnCtrl,
      itemCount: _windowTotal,
      useOnTap: false, // 点击分区（翻页/呼出菜单）由外层手势处理
      onSwipe: (_) => _syncProgressAt(_turnCtrl!.currentIndex),
      overleafColorBuilder: (_) => palette.background, // 卷起页背面与纸色一致
      overleafBorderColorBuilder: (_) =>
          palette.secondary.withValues(alpha: 0.4),
      overleafBorderWidthBuilder: (_) => 0.8,
      itemBuilder: (ctx, v) {
        final mapped = _mapWindowIndex(v);
        // 页面必须不透明且全屏铺满：卷起/覆盖时新页要能真正“盖住”旧页
        return Container(
          decoration: _pageDecoration(cfg, palette),
          padding: _pagePad,
          alignment: Alignment.topLeft,
          child: Text(
            mapped.$1.pageText(mapped.$2),
            style: style,
          ),
        );
      },
    );
  }

  /// 覆盖 / 平移模式：PageView + 窗口式页面。
  Widget _pageBody(ChapterLayout layout, ReaderPalette palette, ReaderConfig cfg) {
    final style = _style(cfg, palette);
    final mode = cfg.settings.pageMode; // 1 平移 / 2 覆盖
    _pageController ??= PageController();
    final pc = _pageController!;
    return PageView.builder(
      controller: pc,
      itemCount: _windowTotal,
      onPageChanged: _syncProgressAt,
      itemBuilder: (ctx, v) {
        final mapped = _mapWindowIndex(v);
        // 页面必须不透明且全屏铺满：覆盖模式中新页要能真正“盖住”旧页
        final content = Container(
          decoration: _pageDecoration(cfg, palette),
          padding: _pagePad,
          alignment: Alignment.topLeft,
          child: Text(
            mapped.$1.pageText(mapped.$2),
            style: style,
          ),
        );
        if (mode == 1) return content;
        return AnimatedBuilder(
          animation: pc,
          builder: (ctx, _) {
            double value = v.toDouble();
            if (pc.hasClients && pc.position.haveDimensions && pc.page != null) {
              value = pc.page!;
            }
            final d = value - v; // >0 当前页(在锚点左侧)，<0 即将盖入的页
            if (d.abs() < 0.001) return content;
            return _coverPage(content, d);
          },
        );
      },
    );
  }

  /// 覆盖模式：当前页钉住不动，新页不透明地从右侧滑入盖在上面，左缘带落影。
  Widget _coverPage(Widget content, double d) {
    if (d > 0) {
      return LayoutBuilder(builder: (ctx, box) {
        return Transform.translate(
          offset: Offset(d * box.maxWidth, 0),
          child: content,
        );
      });
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        Positioned(
          left: 0, top: 0, bottom: 0, width: 26,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.32),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 滚动模式 ----------

  Widget _scrollBody(
      ChapterLayout layout, ReaderPalette palette, ReaderConfig cfg) {
    final style = _style(cfg, palette);
    _scrollController ??= ScrollController();
    final sc = _scrollController!;
    if (!_scrollAttached) {
      _scrollAttached = true;
      sc.addListener(() {
        if (!sc.hasClients || _layout == null) return;
        final layout = _layout!;
        final line = (sc.offset / layout.lineHeight).floor().clamp(
            0, layout.lines.length - 1);
        final charOffset = layout.charOffsetOfLine(line);
        if ((charOffset - rs.charOffsetInChapter).abs() > 100) {
          rs.onPageChanged(
              rs.currentChapter, line ~/ layout.linesPerPage, charOffset);
        }
      });
    }
    // 按已分好的页懒加载：整章塞进一个 Text 会在长章节时卡顿；
    // itemExtent 固定为页高，滚动进度换算与翻页模式完全一致，
    // 页内文本来自 pageText，段落缩进也与翻页模式一致。
    return ListView.builder(
      controller: sc,
      itemCount: layout.pageCount,
      itemExtent: layout.lineHeight * layout.linesPerPage,
      itemBuilder: (ctx, page) => Align(
        alignment: Alignment.topLeft,
        child: Text(layout.pageText(page), style: style),
      ),
    );
  }

  // ---------- 菜单 ----------

  /// 在线书进度条：按章节跳转（未加载的章节没有字符偏移信息）。
  Widget _onlineSlider() {
    final max = math.max(1.0, rs.chapters.length.toDouble());
    return Slider(
      value: (_menuDragging && _sliderChapter != null
              ? _sliderChapter!.toDouble()
              : (rs.currentChapter + 1).toDouble())
          .clamp(1.0, max),
      max: max,
      divisions: rs.chapters.length > 1 ? rs.chapters.length : null,
      onChangeStart: (v) {
        _menuDragging = true;
        _sliderChapter = v.round();
        _sliderChapterLabel = _onlineChapterLabel(v.round());
      },
      onChanged: (v) {
        setState(() {
          _sliderChapter = v.round();
          _sliderChapterLabel = _onlineChapterLabel(v.round());
        });
      },
      onChangeEnd: (v) {
        _menuDragging = false;
        _sliderChapter = null;
        _sliderChapterLabel = '';
        _goChapter(v.round() - 1);
      },
    );
  }

  String _onlineChapterLabel(int chapter1based) {
    if (rs.chapters.isEmpty) return '';
    final idx = (chapter1based - 1).clamp(0, rs.chapters.length - 1);
    final title = rs.chapters[idx].title;
    final short = title.length > 10 ? '${title.substring(0, 10)}…' : title;
    final pct = (idx + 1) / rs.chapters.length * 100;
    return '第$chapter1based章 $short（${pct.toStringAsFixed(0)}%）';
  }

  /// 拖动进度条时的实时章节提示。
  String _chapterLabelFor(int charOffset) {    if (rs.chapterStartChars.isEmpty || rs.totalChars == 0) return '';
    int idx = 0;
    for (int i = 0; i < rs.chapterStartChars.length; i++) {
      if (rs.chapterStartChars[i] <= charOffset) idx = i;
    }
    final title = rs.chapters[idx].title;
    final short = title.length > 10 ? '${title.substring(0, 10)}…' : title;
    final pct = (charOffset / rs.totalChars * 100).clamp(0.0, 100.0)
        .toStringAsFixed(0);
    return '第${idx + 1}章 $short（$pct%）';
  }

  Widget _menuOverlay(ReaderConfig cfg, ReaderPalette palette, bool isDark) {
    final themeState = context.read<ThemeState>();
    final total = rs.totalChars == 0 ? 1 : rs.totalChars;
    final done = (rs.chapterStartChars.isEmpty
            ? 0
            : rs.chapterStartChars[rs.currentChapter]) +
        rs.charOffsetInChapter;
    return Positioned.fill(
      child: Column(
        children: [
          // 顶栏
          Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(widget.book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(
                          rs.chapters.isEmpty
                              ? ''
                              : rs.chapters[rs.currentChapter].title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).hintColor),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
                    tooltip: '切换日间/夜间',
                    onPressed: () => themeState.setMode(
                        isDark ? ThemeMode.light : ThemeMode.dark),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          // 底栏
          Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 拖动时的实时章节提示
                  if (_menuDragging && _sliderChapterLabel.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(_sliderChapterLabel,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        Text('${rs.percent.toStringAsFixed(1)}%',
                            style: const TextStyle(fontSize: 12)),
                        Expanded(
                          child: rs.isOnlineBook
                              ? _onlineSlider()
                              : Slider(
                                  value: (_menuDragging && _sliderPreview != null
                                          ? _sliderPreview!
                                          : done.clamp(0, total).toDouble())
                                      .clamp(0.0, total.toDouble()),
                                  max: total.toDouble(),
                                  onChangeStart: (v) {
                                    _menuDragging = true;
                                    _sliderPreview = v;
                                    _sliderChapterLabel =
                                        _chapterLabelFor(v.round());
                                  },
                                  onChangeEnd: (v) {
                                    _menuDragging = false;
                                    _sliderPreview = null;
                                    _sliderChapterLabel = '';
                                    _jumpToGlobalOffset(v.round());
                                  },
                                  onChanged: (v) => setState(() {
                                    _sliderPreview = v;
                                    _sliderChapterLabel =
                                        _chapterLabelFor(v.round());
                                  }),
                                ),
                        ),
                        Text('第${rs.currentChapter + 1}/${rs.chapters.length}章',
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  // 第一行：章节导航 + 目录 + 书签列表
                  Row(
                    children: [
                      _barButton(
                        icon: Icons.skip_previous,
                        label: '上一章',
                        onTap: rs.currentChapter > 0
                            ? () => _goChapter(rs.currentChapter - 1)
                            : null,
                      ),
                      _barButton(
                        icon: Icons.menu_book_outlined,
                        label: '目录',
                        onTap: _showToc,
                      ),
                      _barButton(
                        icon: Icons.bookmarks_outlined,
                        label: rs.bookmarks.isEmpty
                            ? '书签'
                            : '书签 ${rs.bookmarks.length}',
                        onTap: rs.bookmarks.isEmpty ? null : _showBookmarks,
                      ),
                      _barButton(
                        icon: Icons.skip_next,
                        label: '下一章',
                        onTap: rs.currentChapter < rs.chapters.length - 1
                            ? () => _goChapter(rs.currentChapter + 1)
                            : null,
                      ),
                    ],
                  ),
                  // 第二行：书签增删 + 设置
                  Row(
                    children: [
                      _barButton(
                        icon: _hasBookmarkHere()
                            ? Icons.bookmark
                            : Icons.bookmark_border,
                        label: _hasBookmarkHere() ? '删书签' : '加书签',
                        onTap: _toggleBookmark,
                      ),
                      _barButton(
                        icon: Icons.settings_outlined,
                        label: '设置',
                        onTap: _showSettings,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _barButton(
      {required IconData icon, required String label, VoidCallback? onTap}) {
    final enabled = onTap != null;
    final color = enabled
        ? Theme.of(context).colorScheme.onSurface
        : Theme.of(context).disabledColor;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 21, color: color),
              const SizedBox(height: 2),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  bool _menuDragging = false;

  bool _hasBookmarkHere() {
    final layout = _layout;
    if (layout == null) return false;
    final offset = layout.charOffsetOfLine(
        rs.currentPage * layout.linesPerPage);
    return rs.hasBookmarkAt(offset);
  }

  void _jumpToGlobalOffset(int charOffset) {
    int ch = 0;
    for (int i = 0; i < rs.chapterStartChars.length; i++) {
      if (rs.chapterStartChars[i] <= charOffset) ch = i;
    }
    final inChapter = charOffset - rs.chapterStartChars[ch];
    _goChapter(ch, charOffset: inChapter);
  }

  void _showToc() {
    _toggleMenu();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx, controller) {
          // 目录定位到当前章（几千章的书不必从头翻）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (controller.hasClients && rs.currentChapter > 0) {
              controller.jumpTo(
                  (rs.currentChapter * 48.0)
                      .clamp(0.0, controller.position.maxScrollExtent));
            }
          });
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('目录 · 共${rs.chapters.length}章',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: rs.chapters.length,
                  itemExtent: 48,
                  itemBuilder: (ctx, i) {
                  final current = i == rs.currentChapter;
                  return ListTile(
                    dense: true,
                    selected: current,
                    title: Text(
                      rs.chapters[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: current
                          ? TextStyle(
                              color: Theme.of(ctx).colorScheme.primary,
                              fontWeight: FontWeight.bold)
                          : null,
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _goChapter(i);
                    },
                  );
                },
              ),
            ),
          ],
        );
        },
      ),
    );
  }

  /// 书签列表：显示各书签所在章节与原文预览，点击跳转，可删除。
  void _showBookmarks() {
    _toggleMenu();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('书签 · 共${rs.bookmarks.length}条',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: rs.bookmarks.isEmpty
                  ? const Center(
                      child: Text('还没有书签，阅读时点「加书签」即可保存位置',
                          style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      controller: controller,
                      itemCount: rs.bookmarks.length,
                      itemBuilder: (ctx, i) {
                        final bm = rs.bookmarks[i];
                        return ListTile(
                          leading: const Icon(Icons.bookmark,
                              color: Colors.deepOrange),
                          title: Text(
                            bm.chapterTitle.isEmpty
                                ? '第${bm.chapterIndex + 1}章'
                                : bm.chapterTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            bm.preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Text(formatTimeCN(bm.createdAt),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(ctx).hintColor)),
                          onTap: () {
                            Navigator.pop(ctx);
                            _goChapter(bm.chapterIndex,
                                charOffset: bm.charOffset);
                          },
                          onLongPress: () async {
                            await rs.removeBookmark(bm.id!);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleBookmark() async {
    final layout = _layout;
    if (layout == null) return;
    // 在线书正文可能尚未加载（pageCount 0），此时无法定位书签偏移
    if (layout.pageCount == 0 || layout.lines.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('本章尚未加载完成，请稍候再试')));
      return;
    }
    final offset =
        layout.charOffsetOfLine(rs.currentPage * layout.linesPerPage);
    final existing = rs.bookmarks.where((b) =>
        b.chapterIndex == rs.currentChapter &&
        (b.charOffset - offset).abs() <= 200);
    if (existing.isNotEmpty) {
      await rs.removeBookmark(existing.first.id!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已删除书签'), duration: Duration(milliseconds: 600)));
      }
    } else {
      final ch = rs.chapters[rs.currentChapter];
      final start = offset.clamp(0, ch.text.length - 1);
      final preview = ch.text
          .substring(start)
          .replaceAll('\n', ' ');
      await rs.addBookmark(
          preview.substring(0, preview.length > 40 ? 40 : preview.length));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已添加书签'), duration: Duration(milliseconds: 600)));
      }
    }
  }

  void _showSettings() {
    _toggleMenu();
    final cfg = context.read<ReaderConfig>();
    final lib = context.read<ThemeState>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => AnimatedBuilder(
        animation: cfg,
        builder: (ctx, _) => StatefulBuilder(
          builder: (ctx, setSheet) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 字号
                Row(
                  children: [
                    const Text('字号', style: TextStyle(fontWeight: FontWeight.bold)),
                    Expanded(
                      child: Slider(
                        value: cfg.settings.fontSize,
                        min: 12,
                        max: 32,
                        divisions: 20,
                        label: cfg.settings.fontSize.round().toString(),
                        onChanged: (v) => cfg.setFontSize(v),
                        // 拖动过程中不清空排版缓存（每 tick 全部重排会卡顿），松手才重排
                        onChangeEnd: (v) =>
                            rs.invalidateLayouts(cfg.layoutKey),
                      ),
                    ),
                  ],
                ),
                // 行距
                Row(
                  children: [
                    const Text('行距', style: TextStyle(fontWeight: FontWeight.bold)),
                    Expanded(
                      child: Slider(
                        value: cfg.settings.lineHeight,
                        min: 1.2,
                        max: 2.6,
                        divisions: 14,
                        label: cfg.settings.lineHeight.toStringAsFixed(1),
                        onChanged: (v) => cfg.setLineHeight(v),
                        onChangeEnd: (v) =>
                            rs.invalidateLayouts(cfg.layoutKey),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('段落首行缩进'),
                  value: cfg.settings.indent,
                  onChanged: (v) {
                    cfg.setIndent(v);
                    rs.invalidateLayouts(cfg.layoutKey);
                  },
                ),
                const SizedBox(height: 4),
                const Text('翻页模式', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final e in const {0: '仿真', 1: '平移', 2: '覆盖', 3: '滚动'}.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: cfg.settings.pageMode == e.key,
                        onSelected: (_) => cfg.setPageMode(e.key),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('阅读背景', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    for (final entry in readerPalettes.indexed)
                      GestureDetector(
                        onTap: () => cfg.setBgIndex(entry.$1),
                        child: Container(
                          margin: const EdgeInsets.only(right: 10),
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: entry.$2.background,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: cfg.settings.bgIndex == entry.$1
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Theme.of(ctx).dividerColor,
                              width: cfg.settings.bgIndex == entry.$1 ? 2.5 : 1,
                            ),
                          ),
                          child: Center(
                            child: Text('文',
                                style: TextStyle(
                                    fontSize: 12, color: entry.$2.text)),
                          ),
                        ),
                      ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () async {
                        final err = await cfg.pickCustomBackground();
                        if (ctx.mounted && err != null) {
                          ScaffoldMessenger.of(ctx)
                              .showSnackBar(SnackBar(content: Text(err)));
                        }
                      },
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: const Text('自定义图片'),
                    ),
                    if (cfg.settings.bgIndex == -1)
                      TextButton(
                        onPressed: () => cfg.clearCustomBackground(),
                        child: const Text('清除'),
                      ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('夜间模式使用深色背景'),
                  value: cfg.settings.darkBgInNight,
                  onChanged: (v) => cfg.setDarkFollowNight(v),
                ),
                const Divider(),
                Row(
                  children: [
                    const Text('字体', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: () async {
                        final err = await cfg.pickCustomFont();
                        if (ctx.mounted && err != null) {
                          ScaffoldMessenger.of(ctx)
                              .showSnackBar(SnackBar(content: Text(err)));
                        } else {
                          rs.invalidateLayouts(cfg.layoutKey);
                        }
                      },
                      child: const Text('导入 .ttf 字体'),
                    ),
                    if (cfg.settings.customFontPath.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          cfg.clearCustomFont();
                          rs.invalidateLayouts(cfg.layoutKey);
                        },
                        child: const Text('恢复默认'),
                      ),
                  ],
                ),
                Text(
                  cfg.fontReady ? '当前使用自定义字体' : '当前使用系统默认字体',
                  style: TextStyle(fontSize: 12, color: Theme.of(ctx).hintColor),
                ),
                const Divider(),
                // 全局主题
                Row(
                  children: [
                    const Text('应用主题', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    for (final e in const {
                      ThemeMode.system: '跟随系统',
                      ThemeMode.light: '浅色',
                      ThemeMode.dark: '深色',
                    }.entries)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: ChoiceChip(
                          label: Text(e.value),
                          selected: lib.mode == e.key,
                          onSelected: (_) => lib.setMode(e.key),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
