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

        // Determine the actual scaffold background based on our custom 3-state enum.
        // Both 'dim' and 'dark' use a dark brightness for text/icons, but they use
        // different scaffold backgrounds.
        Color backgroundColor;
        Brightness brightness;

        switch (_themeManager.themeMode) {
          case CompassThemeMode.light:
            backgroundColor = activeTheme.lightBackground;
            brightness = Brightness.light;
            break;
          case CompassThemeMode.dim:
            backgroundColor = activeTheme.dimBackground;
            brightness = Brightness.dark;
            break;
          case CompassThemeMode.dark:
            backgroundColor = activeTheme.darkBackground;
            brightness = Brightness.dark;
            break;
        }

        return MaterialApp(
          title: 'Compass',
          // We bypass Flutter's built in themeMode switching and just supply a
          // single computed `theme` object based on our custom state.
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: activeTheme.seedColor,
              brightness: brightness,
            ),
            scaffoldBackgroundColor: backgroundColor,
          ),
          debugShowCheckedModeBanner: false,
          home: CompassWorkspace(themeManager: _themeManager),
        );
      },
    );
  }
}