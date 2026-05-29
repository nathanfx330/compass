import 'package:flutter/material.dart';
import 'workspace.dart';

void main() {
  runApp(const CompassApp());
}

class CompassApp extends StatefulWidget {
  const CompassApp({super.key});

  @override
  State<CompassApp> createState() => _CompassAppState();
}

class _CompassAppState extends State<CompassApp> {
  // Notifier to hold and broadcast the current theme state globally
  final ValueNotifier<ThemeMode> _themeNotifier = ValueNotifier(ThemeMode.dark);

  @override
  void dispose() {
    _themeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeNotifier,
      builder: (context, currentThemeMode, child) {
        return MaterialApp(
          title: 'Compass',
          themeMode: currentThemeMode,
          darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blueGrey,
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xFF1E1E1E), // Dark IDE/Editor background
          ),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blueGrey,
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFF0F0F0), // Light IDE background
            useMaterial3: true,
          ),
          debugShowCheckedModeBanner: false,
          // We pass the notifier down so the UI can trigger the change
          home: CompassWorkspace(themeNotifier: _themeNotifier),
        );
      },
    );
  }
}