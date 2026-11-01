import 'package:flutter/material.dart';

import '../models/model_manager_sheet.dart';
import 'chat_page_controller.dart';
import 'core/app_theme.dart';

class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key, required this.controller, this.onBack});

  final ChatPageController controller;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final manager = controller.manager;
        if (manager == null) {
          return const Scaffold(
            backgroundColor: AppColors.background,
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          backgroundColor: AppColors.background,
          body: SafeArea(
            child: ModelManagerSheet(
              manager: manager,
              currentPath: controller.modelPath,
              pageMode: true,
              onBack: onBack,
              onSelected: controller.selectModel,
            ),
          ),
        );
      },
    );
  }
}
