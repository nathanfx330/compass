// lib/theme_manager.dart

import 'package:flutter/material.dart';

/// Custom theme mode enum to support a "Dim" state between Light and Dark.
enum CompassThemeMode { light, dim, dark }

/// Defines a single theme containing a seed color and specific light/dim/dark backgrounds.
class CompassTheme {
  final String id;
  final String name;
  final Color seedColor;
  final Color lightBackground;
  final Color dimBackground; // <--- NEW
  final Color darkBackground;
  final bool isPrebuilt;

  CompassTheme({
    required this.id,
    required this.name,
    required this.seedColor,
    required this.lightBackground,
    required this.dimBackground, // <--- NEW
    required this.darkBackground,
    this.isPrebuilt = false,
  });

  CompassTheme copyWith({
    String? name,
    Color? seedColor,
    Color? lightBackground,
    Color? dimBackground, // <--- NEW
    Color? darkBackground,
  }) {
    return CompassTheme(
      id: id,
      name: name ?? this.name,
      seedColor: seedColor ?? this.seedColor,
      lightBackground: lightBackground ?? this.lightBackground,
      dimBackground: dimBackground ?? this.dimBackground, // <--- NEW
      darkBackground: darkBackground ?? this.darkBackground,
      isPrebuilt: isPrebuilt,
    );
  }
}

/// Manages the active Theme Mode and the active Color Theme across the app.
class ThemeManager extends ChangeNotifier {
  // <--- CHANGED: Now uses our custom enum
  CompassThemeMode _themeMode = CompassThemeMode.dark;
  CompassThemeMode get themeMode => _themeMode;

  set themeMode(CompassThemeMode mode) {
    if (_themeMode != mode) {
      _themeMode = mode;
      notifyListeners();
    }
  }

  late CompassTheme _activeTheme;
  CompassTheme get activeTheme => _activeTheme;

  // Our starting prebuilt themes, now with a 'dimBackground' added to each
  final List<CompassTheme> _themes = [
    CompassTheme(
      id: 'default_bluegrey',
      name: 'Compass Default',
      seedColor: Colors.blueGrey,
      lightBackground: const Color(0xFFF0F0F0),
      dimBackground: const Color(0xFF2D2F33),   // <--- NEW: A mid-dark gray
      darkBackground: const Color(0xFF1E1E1E),  
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'ocean_blue',
      name: 'Ocean Blue',
      seedColor: Colors.blue,
      lightBackground: const Color(0xFFF0F4F8),
      dimBackground: const Color(0xFF1E293B),   // <--- NEW: Tailwind Slate 800
      darkBackground: const Color(0xFF0F172A),
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'engine',
      name: 'Engine',
      seedColor: const Color(0xFF4188D2),
      lightBackground: const Color(0xFFE5E7EB),
      dimBackground: const Color(0xFF2C2E3A),   // <--- NEW: Slightly lighter graphite
      darkBackground: const Color(0xFF21232B),
      isPrebuilt: true,
    ),
    // <--- REPLACED Rosé Pine with Nord --->
    CompassTheme(
      id: 'nord',
      name: 'Nord',
      seedColor: const Color(0xFF88C0D0),       // Frost Cyan
      lightBackground: const Color(0xFFECEFF4), // Snow Storm
      dimBackground: const Color(0xFF3B4252),   // Polar Night (Lighter)
      darkBackground: const Color(0xFF2E3440),  // Polar Night (Darker)
      isPrebuilt: true,
    ),
    // <--- NEW: Added Gruvbox --->
    CompassTheme(
      id: 'gruvbox',
      name: 'Gruvbox',
      seedColor: const Color(0xFFFE8019),       // Orange Accent
      // <--- CHANGED: Replaced the bright yellow with a muted, warm stone gray --->
      lightBackground: const Color(0xFFE0DCD3), 
      dimBackground: const Color(0xFF3C3836),   // Dark bg1 (Lighter)
      darkBackground: const Color(0xFF282828),  // Dark bg0 (Darker)
      isPrebuilt: true,
    ),
  ];

  List<CompassTheme> get themes => _themes;

  ThemeManager() {
    _activeTheme = _themes.first;
  }

  void setActiveTheme(CompassTheme theme) {
    if (_activeTheme != theme) {
      _activeTheme = theme;
      notifyListeners();
    }
  }

  void addCustomTheme(CompassTheme theme) {
    _themes.add(theme);
    _activeTheme = theme;
    notifyListeners();
  }

  void updateCustomTheme(CompassTheme updatedTheme) {
    final index = _themes.indexWhere((t) => t.id == updatedTheme.id);
    if (index != -1 && !_themes[index].isPrebuilt) {
      _themes[index] = updatedTheme;
      if (_activeTheme.id == updatedTheme.id) {
        _activeTheme = updatedTheme;
      }
      notifyListeners();
    }
  }

  void deleteCustomTheme(String id) {
    final index = _themes.indexWhere((t) => t.id == id);
    if (index != -1 && !_themes[index].isPrebuilt) {
      _themes.removeAt(index);
      if (_activeTheme.id == id) {
        _activeTheme = _themes.first;
      }
      notifyListeners();
    }
  }
}