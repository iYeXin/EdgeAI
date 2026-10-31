import 'package:flutter/material.dart';

import 'chat_page.dart';
import 'chat_page_controller.dart';
import 'core/app_theme.dart';
import 'models_page.dart';
import 'settings_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final ChatPageController _controller = ChatPageController();
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller.onOpenModels = () {
      if (mounted) setState(() => _index = 1);
    };
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                ChatPage(controller: _controller),
                ModelsPage(controller: _controller),
                SettingsPage(controller: _controller),
              ],
            ),
          ),
          _BottomBar(
            index: _index,
            onSelected: (value) => setState(() => _index = value),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.index, required this.onSelected});

  final int index;
  final ValueChanged<int> onSelected;

  static const _items = [
    (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, '聊天'),
    (Icons.storage_outlined, Icons.storage_rounded, '模型'),
    (Icons.tune_outlined, Icons.tune_rounded, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 62,
          child: Row(
            children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelected(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          index == i ? _items[i].$2 : _items[i].$1,
                          size: 22,
                          color: index == i
                              ? AppColors.primary
                              : AppColors.muted,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _items[i].$3,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: index == i
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: index == i
                                ? AppColors.primary
                                : AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
