import 'package:flutter/material.dart';

import 'bookshelf_page.dart';
import 'bookstore_page.dart';
import 'source_page.dart';

/// 应用主壳：底部导航栏承载 书架 / 书城 / 书源 三个常驻页面。
/// IndexedStack 保持各 tab 状态（滚动位置、搜索结果不因切页丢失）。
class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  int _index = 0;

  void _goto(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          BookshelfPage(),
          BookstorePage(onOpenSourcePage: () => _goto(2)),
          SourcePage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _goto,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: '书架',
          ),
          NavigationDestination(
            icon: Icon(Icons.travel_explore_outlined),
            selectedIcon: Icon(Icons.travel_explore),
            label: '书城',
          ),
          NavigationDestination(
            icon: Icon(Icons.source_outlined),
            selectedIcon: Icon(Icons.source),
            label: '书源',
          ),
        ],
      ),
    );
  }
}
