import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/book.dart';
import '../reader/paginate.dart';
import '../state/reader_config.dart';
import '../state/reader_state.dart';
import '../state/theme_state.dart';
import 'common.dart';

/// 阅读页。
class ReaderPage extends StatefulWidget {
  final Book book;
  const ReaderPage({super.key, required this.book});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late final ReaderState rs;
  PageController? _pageController;
  ScrollController? _scrollController;
  ChapterLayout? _layout;
  bool _menuVisible = false;
  bool _scrollAttached = false;
  int _restoredForChapter = -1;
  bool _pendingJumpEnd = false;
  int? _pendingCharOffset;
  double? _sliderPreview;
  String _sliderChapterLabel = '';
  bool _dragForward = true; // 仿真翻页的方向感知

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
    final pc = _pageController;
    if (pc == null || !pc.hasClients) return;
    final cur = pc.page?.round() ?? 0;
    if (cur < layout.pageCount - 1) {
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
      final page = layout.pageOfLine(line);
      if (context.read<ReaderConfig>().settings.pageMode == 3) {
        _scrollController?.jumpTo((page * layout.linesPerPage * layout.lineHeight)
            .clamp(0.0, double.infinity));
      } else if (_pageController?.hasClients ?? false) {
        _pageController!.jumpToPage(page);
      }
      rs.onPageChanged(idx, page, charOffset);
      return;
    }
    _pendingCharOffset = charOffset;
    _pendingJumpEnd = charOffset == null && _pendingJumpEnd;
    rs.goToChapter(idx, charOffset: charOffset ?? 0);
  }

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

    // 恢复进度 / 章节跳转，只对每章执行一次
    if (_restoredForChapter != rs.currentChapter) {
      _restoredForChapter = rs.currentChapter;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        int targetPage;
        if (_pendingCharOffset != null) {
          final line = layout.lineIndexOfChar(_pendingCharOffset!);
          targetPage = layout.pageOfLine(line);
          _pendingCharOffset = null;
        } else if (_pendingJumpEnd) {
          targetPage = layout.pageCount - 1;
          _pendingJumpEnd = false;
        } else {
          targetPage = rs.restorePage(layout);
        }
        if (cfg.settings.pageMode == 3) {
          _scrollController?.jumpTo(
              (targetPage * layout.linesPerPage * layout.lineHeight)
                  .clamp(0.0, double.infinity));
        } else {
          if (_pageController?.hasClients ?? false) {
            _pageController?.jumpToPage(targetPage);
          }
        }
        rs.currentPage = targetPage;
      });
    }

    final body = cfg.settings.pageMode == 3
        ? _scrollBody(layout, palette, cfg)
        : _pageBody(layout, palette, cfg);

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

  Widget _pageBody(ChapterLayout layout, ReaderPalette palette, ReaderConfig cfg) {
    final style = _style(cfg, palette);
    final mode = cfg.settings.pageMode; // 0 仿真 / 1 平移 / 2 覆盖
    _pageController ??= PageController();
    final pc = _pageController!;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollUpdateNotification && n.scrollDelta != null) {
          if (n.scrollDelta! < 0) {
            _dragForward = true;
          } else if (n.scrollDelta! > 0) {
            _dragForward = false;
          }
        }
        return false;
      },
      child: PageView.builder(
        controller: pc,
        itemCount: layout.pageCount,
        onPageChanged: (page) {
          final charOffset =
              layout.charOffsetOfLine(page * layout.linesPerPage);
          rs.onPageChanged(rs.currentChapter, page, charOffset);
        },
        itemBuilder: (ctx, page) {
          final content = SizedBox.expand(
            child: Text(layout.pageText(page), style: style),
          );
          if (mode == 1) return content;
          return AnimatedBuilder(
            animation: pc,
            builder: (ctx, _) {
              double value = page.toDouble();
              if (pc.hasClients && pc.position.haveDimensions && pc.page != null) {
                value = pc.page!;
              }
              final d = value - page; // >0 当前页(在锚点左侧)，<0 即将盖入的页
              if (d.abs() < 0.001) return content;
              return mode == 2
                  ? _coverPage(content, d)
                  : _curlPage(content, d);
            },
          );
        },
      ),
    );
  }

  /// 覆盖模式：即将显示的页保持静止从右侧“盖”到当前页上，当前页钉住并逐渐变暗。
  Widget _coverPage(Widget content, double d) {
    return LayoutBuilder(builder: (ctx, box) {
      final w = box.maxWidth;
      if (d > 0) {
        // 当前页：钉住 + 按进度压暗
        return Transform.translate(
          offset: Offset(d * w, 0),
          child: Stack(
            fit: StackFit.expand,
            children: [
              content,
              Container(color: Colors.black.withValues(alpha: (d * 0.45).clamp(0.0, 0.45))),
            ],
          ),
        );
      }
      // 盖入页：正常滑动（位于上层），左缘加落影增强“盖上去”的感觉
      return Stack(
        fit: StackFit.expand,
        children: [
          content,
          Positioned(
            left: 0, top: 0, bottom: 0, width: 16,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.black.withValues(alpha: 0.28),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }

  /// 仿真模式：两页都钉住，用“卷页揭示”取代平移——
  /// 前翻时新页以弧形折痕从右缘逐渐展开；后翻时当前页自然右移、左缘带折痕阴影。
  Widget _curlPage(Widget content, double d) {
    return LayoutBuilder(builder: (ctx, box) {
      final w = box.maxWidth;
      final h = box.maxHeight;
      if (d > 0) {
        // 底下的页：钉住，折痕处画投影
        final edgeX = _dragForward ? w * (1 - d) : w * d;
        return Transform.translate(
          offset: Offset(d * w, 0),
          child: Stack(
            fit: StackFit.expand,
            children: [
              content,
              if (d < 0.999)
                CustomPaint(
                  painter: _FoldShadowPainter(edgeX: edgeX, onTop: false),
                  size: Size(w, h),
                ),
            ],
          ),
        );
      }
      final r = -d; // 0 → 1
      if (_dragForward) {
        // 前翻：卷入的页钉住，弧形裁剪从右缘逐渐展开
        final edgeX = w * (1 - r);
        return Transform.translate(
          offset: Offset(d * w, 0),
          child: ClipPath(
            clipper: _CurlClipper(edgeX: edgeX, height: h),
            child: Stack(
              fit: StackFit.expand,
              children: [
                content,
                CustomPaint(
                  painter: _FoldShadowPainter(edgeX: edgeX, onTop: true),
                  size: Size(w, h),
                ),
              ],
            ),
          ),
        );
      }
      // 后翻：当前页自然右移离场，左缘绘制折痕
      return Stack(
        fit: StackFit.expand,
        children: [
          content,
          CustomPaint(
            painter: _FoldShadowPainter(edgeX: 0, onTop: true),
            size: Size(w, h),
          ),
        ],
      );
    });
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

/// 仿真翻页：卷页折痕处的阴影绘制。
class _FoldShadowPainter extends CustomPainter {
  final double edgeX;
  final bool onTop; // true = 画在卷入页边缘（内侧亮/外侧暗），false = 投影到下面的页
  _FoldShadowPainter({required this.edgeX, required this.onTop});

  @override
  void paint(Canvas canvas, Size size) {
    if (edgeX <= 0 || edgeX >= size.width) return;
    if (onTop) {
      // 卷入页自身：边缘内侧先一条亮棱（纸页厚度），再渐变阴影
      final hiRect = Rect.fromLTWH(edgeX, 0, 5, size.height);
      canvas.drawRect(hiRect,
          Paint()..color = Colors.white.withValues(alpha: 0.35));
      final shadowRect = Rect.fromLTWH(edgeX + 5, 0, 26, size.height);
      canvas.drawRect(
          shadowRect,
          Paint()
            ..shader = LinearGradient(
              colors: [
                Colors.black.withValues(alpha: 0.18),
                Colors.transparent,
              ],
            ).createShader(shadowRect));
    } else {
      // 下面的页：折痕左侧的投影
      final shadowRect = Rect.fromLTWH(edgeX - 42, 0, 42, size.height);
      canvas.drawRect(
          shadowRect,
          Paint()
            ..shader = LinearGradient(
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.30),
              ],
            ).createShader(shadowRect));
    }
  }

  @override
  bool shouldRepaint(_FoldShadowPainter old) =>
      old.edgeX != edgeX || old.onTop != onTop;
}

/// 仿真翻页：卷入页的弧形裁剪（边缘略微向内弯，模拟纸页弯曲）。
class _CurlClipper extends CustomClipper<Path> {
  final double edgeX;
  final double height;
  _CurlClipper({required this.edgeX, required this.height});

  @override
  Path getClip(Size size) {
    final x = edgeX.clamp(0.0, size.width);
    final path = Path()
      ..moveTo(x, 0)
      // 边缘向内弯：中部比上下多露出 4% 宽度
      ..quadraticBezierTo(
          x + size.width * 0.04, size.height / 2, x, size.height)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width, 0)
      ..close();
    return path;
  }

  @override
  bool shouldReclip(_CurlClipper old) => old.edgeX != edgeX;
}
