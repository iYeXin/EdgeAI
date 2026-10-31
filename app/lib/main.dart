import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/app_shell.dart';
import 'ui/core/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.surface,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ),
  );
  runApp(const EdgeAiApp());
}

class EdgeAiApp extends StatelessWidget {
  const EdgeAiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Edge AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.material(),
      home: const AppShell(),
    );
  }
}
