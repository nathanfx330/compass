// /lib/main.dart

import 'package:flutter/material.dart';
import 'workspace.dart';
import 'theme_manager.dart';

void main() {
  runApp(const CompassApp());
}

class CompassApp extends StatefulWidget {
  const CompassApp({super.key});

  @override
  State<CompassApp> createState() => _CompassAppState();
}

class _CompassAppState extends State<CompassApp> {
  // Use our new ThemeManager to hold both light/dark mode and the active color theme
  final ThemeManager _themeManager = ThemeManager();

  @override
  void dispose() {
    _themeManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _themeManager,
      builder: (context, _) {
        final activeTheme = _themeManager.activeTheme;

        return MaterialApp(
          title: 'Compass',
          themeMode: _themeManager.themeMode,
          darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
            colorScheme: ColorScheme.fromSeed(
              seedColor: activeTheme.seedColor,
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: activeTheme.darkBackground,
          ),
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: activeTheme.seedColor,
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: activeTheme.lightBackground,
          ),
          debugShowCheckedModeBanner: false,
          // Pass the manager down so the UI can trigger theme changes
          home: CompassWorkspace(themeManager: _themeManager),
        );
      },
    );
  }
}