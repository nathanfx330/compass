// /lib/theme_manager.dart

import 'package:flutter/material.dart';

/// Defines a single theme containing a seed color and specific light/dark backgrounds.
class CompassTheme {
  final String id;
  final String name;
  final Color seedColor;
  final Color lightBackground;
  final Color darkBackground;
  final bool isPrebuilt;

  CompassTheme({
    required this.id,
    required this.name,
    required this.seedColor,
    required this.lightBackground,
    required this.darkBackground,
    this.isPrebuilt = false,
  });

  CompassTheme copyWith({
    String? name,
    Color? seedColor,
    Color? lightBackground,
    Color? darkBackground,
  }) {
    return CompassTheme(
      id: id,
      name: name ?? this.name,
      seedColor: seedColor ?? this.seedColor,
      lightBackground: lightBackground ?? this.lightBackground,
      darkBackground: darkBackground ?? this.darkBackground,
      isPrebuilt: isPrebuilt,
    );
  }
}

/// Manages the active Theme Mode and the active Color Theme across the app.
class ThemeManager extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.dark;
  ThemeMode get themeMode => _themeMode;

  set themeMode(ThemeMode mode) {
    if (_themeMode != mode) {
      _themeMode = mode;
      notifyListeners();
    }
  }

  late CompassTheme _activeTheme;
  CompassTheme get activeTheme => _activeTheme;

  // Our starting prebuilt themes
  final List<CompassTheme> _themes = [
    CompassTheme(
      id: 'default_bluegrey',
      name: 'Compass Default',
      seedColor: Colors.blueGrey,
      lightBackground: const Color(0xFFF0F0F0), // Light IDE background
      darkBackground: const Color(0xFF1E1E1E),  // Dark IDE background
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'ocean_blue',
      name: 'Ocean Blue',
      seedColor: Colors.blue,
      lightBackground: const Color(0xFFF0F4F8),
      darkBackground: const Color(0xFF0F172A),
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'monokai',
      name: 'Monokai',
      seedColor: const Color(0xFFA6E22E),
      lightBackground: const Color(0xFFFAFAFA),
      darkBackground: const Color(0xFF272822),
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'rose_pine',
      name: 'Rosé Pine',
      seedColor: const Color(0xFFEB6F92),
      lightBackground: const Color(0xFFFAF4ED),
      darkBackground: const Color(0xFF191724),
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