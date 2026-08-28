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
    setState(() => _menuVisible = !_menuVisible);
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
          duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
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
          duration: const Duration(milliseconds: 240), curve: Curves.easeOut);
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

  Widget _pageBody(ChapterLayout layout, ReaderPalette palette, ReaderConfig cfg) {
    final style = _style(cfg, palette);
    _pageController ??= PageController();
    return PageView.builder(
      controller: _pageController,
      itemCount: layout.pageCount,
      onPageChanged: (page) {
        final charOffset = layout.charOffsetOfLine(page * layout.linesPerPage);
        rs.onPageChanged(rs.currentChapter, page, charOffset);
      },
      itemBuilder: (ctx, page) => SizedBox(
        width: double.infinity,
        child: Text(
          layout.pageText(page),
          style: style,
        ),
      ),
    );
  }

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
                            },
                            onChangeEnd: (v) {
                              _menuDragging = false;
                              _sliderPreview = null;
                              _jumpToGlobalOffset(v.round());
                            },
                            onChanged: (v) =>
                                setState(() => _sliderPreview = v),
                          ),
                        ),
                        Text('第${rs.currentChapter + 1}/${rs.chapters.length}章',
                            style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      TextButton.icon(
                        onPressed: rs.currentChapter > 0
                            ? () => _goChapter(rs.currentChapter - 1)
                            : null,
                        icon: const Icon(Icons.skip_previous, size: 20),
                        label: const Text('上一章'),
                      ),
                      TextButton.icon(
                        onPressed: _showToc,
                        icon: const Icon(Icons.menu_book_outlined, size: 20),
                        label: const Text('目录'),
                      ),
                      TextButton.icon(
                        onPressed: _toggleBookmark,
                        icon: Icon(
                          _hasBookmarkHere()
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                          size: 20,
                        ),
                        label: const Text('书签'),
                      ),
                      TextButton.icon(
                        onPressed: _showSettings,
                        icon: const Icon(Icons.settings_outlined, size: 20),
                        label: const Text('设置'),
                      ),
                      TextButton.icon(
                        onPressed: rs.currentChapter < rs.chapters.length - 1
                            ? () => _goChapter(rs.currentChapter + 1)
                            : null,
                        icon: const Icon(Icons.skip_next, size: 20),
                        label: const Text('下一章'),
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

  bool _menuDragging = false;

  bool _hasBookmarkHere() {
    final layout = _layout;
    if (layout == null) return false;
    final offset = layout.charOffsetOfLine(
        rs.currentPage * layout.linesPerPage);
    return rs.hasBookmarkAt(offset);
  }

  void _jumpToGlobalOffset(int charOffset) {
    // 找到目标章
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
    } else {
      final ch = rs.chapters[rs.currentChapter];
      final preview = ch.text
          .substring(offset.clamp(0, ch.text.length - 1))
          .replaceAll('\n', ' ');
      await rs.addBookmark(
          preview.substring(0, preview.length > 40 ? 40 : preview.length));
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
