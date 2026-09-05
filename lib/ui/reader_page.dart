import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:turn_page_transition/turn_page_transition.dart';

import '../data/book.dart';
import '../reader/paginate.dart';
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
  double? _sliderPreview;
  String _sliderChapterLabel = '';

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
    rs.saveNow();
    rs.dispose();
    _pageController?.dispose();
    _scrollController?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _rsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _toggleMenu() {
    setState(() {
      _menuVisible = !_menuVisible;
      _sliderChapterLabel = '';
      _sliderPreview = null;
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
        _scrollController?.jumpTo((pageInChapter *
                layout.linesPerPage *
                layout.lineHeight)
            .clamp(0.0, double.infinity));
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
    final pad = const EdgeInsets.fromLTRB(18, 40, 18, 24);
    final textWidth = box.maxWidth - pad.horizontal;
    final textHeight = box.maxHeight - pad.vertical;
    final style = _style(cfg, palette);
    final layout = rs.layoutFor(
        rs.currentChapter, style, textWidth, textHeight, cfg.settings.indent);
    _layout = layout;

    // 窗口计算：把上一章/下一章的页面拼进同一个 PageView
    final windowKey =
        '${cfg.layoutKey}_${rs.currentChapter}_${textWidth}x$textHeight';
    if (_windowChapter != rs.currentChapter || _windowKey != windowKey) {
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
    }

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
          _scrollController?.jumpTo(
              (pageInChapter * layout.linesPerPage * layout.lineHeight)
                  .clamp(0.0, double.infinity));
        } else {
          if (_pageController?.hasClients ?? false) {
            _pageController!.jumpToPage(target);
          }
        }
        rs.currentPage = pageInChapter;
      });
    }

    Widget body;
    switch (cfg.settings.pageMode) {
      case 0:
        body = _turnBody(palette, cfg);
      case 3:
        body = _scrollBody(layout, palette, cfg);
      default:
        body = _pageBody(layout, palette, cfg);
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (d) => _handleTapUp(d, box),
      child: Stack(
        children: [
          Positioned.fill(child: _background(cfg, isDark: false)),
          Padding(
            padding: pad,
            child: body,
          ),
        ],
      ),
    );
  }

  Widget _background(ReaderConfig cfg, {required bool isDark}) {
    final bgPath = cfg.settings.customBgPath;
    if (cfg.settings.bgIndex == -1 && bgPath.isNotEmpty) {
      final file = File(bgPath);
      if (file.existsSync()) {
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
    return TurnPageView.builder(
      key: ValueKey(_windowKey),
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
        // 页面必须不透明：卷起/覆盖时新页要能真正“盖住”旧页
        return Container(
          color: palette.background,
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
        // 页面必须不透明：覆盖模式中新页要能真正“盖住”旧页
        final content = Container(
          color: palette.background,
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
    final chapter = rs.chapters[rs.currentChapter];
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
    return SingleChildScrollView(
      controller: sc,
      child: Text(chapter.text, style: style),
    );
  }

  // ---------- 菜单 ----------

  /// 拖动进度条时的实时章节提示。
  String _chapterLabelFor(int charOffset) {
    if (rs.chapterStartChars.isEmpty || rs.totalChars == 0) return '';
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
                          child: Slider(
                            value: (_menuDragging && _sliderPreview != null
                                    ? _sliderPreview!
                                    : done.clamp(0, total).toDouble())
                                .clamp(0.0, total.toDouble()),
                            max: total.toDouble(),
                            onChangeStart: (v) {
                              _menuDragging = true;
                              _sliderPreview = v;
                              _sliderChapterLabel = _chapterLabelFor(v.round());
                            },
                            onChangeEnd: (v) {
                              _menuDragging = false;
                              _sliderPreview = null;
                              _sliderChapterLabel = '';
                              _jumpToGlobalOffset(v.round());
                            },
                            onChanged: (v) => setState(() {
                              _sliderPreview = v;
                              _sliderChapterLabel = _chapterLabelFor(v.round());
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
        builder: (ctx, controller) => Column(
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
        ),
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
                        onChanged: (v) {
                          cfg.setFontSize(v);
                          rs.invalidateLayouts(cfg.layoutKey);
                        },
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
                        onChanged: (v) {
                          cfg.setLineHeight(v);
                          rs.invalidateLayouts(cfg.layoutKey);
                        },
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
