// lib/theme_manager.dart

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';

/// Custom theme mode enum to support a "Dim" state between Light and Dark.
enum CompassThemeMode { light, dim, dark }

/// Defines a single theme containing a seed color and specific light/dim/dark backgrounds.
class CompassTheme {
  final String id;
  final String name;
  final Color seedColor;
  final Color lightBackground;
  final Color dimBackground; 
  final Color darkBackground;
  final bool isPrebuilt;
  final bool isMonochrome; // <--- NEW: Flag for zero-hue themes

  CompassTheme({
    required this.id,
    required this.name,
    required this.seedColor,
    required this.lightBackground,
    required this.dimBackground, 
    required this.darkBackground,
    this.isPrebuilt = false,
    this.isMonochrome = false, // <--- NEW: Default to false
  });

  CompassTheme copyWith({
    String? name,
    Color? seedColor,
    Color? lightBackground,
    Color? dimBackground, 
    Color? darkBackground,
    bool? isMonochrome,
  }) {
    return CompassTheme(
      id: id,
      name: name ?? this.name,
      seedColor: seedColor ?? this.seedColor,
      lightBackground: lightBackground ?? this.lightBackground,
      dimBackground: dimBackground ?? this.dimBackground, 
      darkBackground: darkBackground ?? this.darkBackground,
      isPrebuilt: isPrebuilt,
      isMonochrome: isMonochrome ?? this.isMonochrome,
    );
  }

  // --- JSON Serialization for Custom Themes ---
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'seedColor': seedColor.value,
      'lightBackground': lightBackground.value,
      'dimBackground': dimBackground.value,
      'darkBackground': darkBackground.value,
      'isMonochrome': isMonochrome, // <--- NEW
    };
  }

  factory CompassTheme.fromJson(Map<String, dynamic> json) {
    return CompassTheme(
      id: json['id'],
      name: json['name'],
      seedColor: Color(json['seedColor']),
      lightBackground: Color(json['lightBackground']),
      dimBackground: Color(json['dimBackground']),
      darkBackground: Color(json['darkBackground']),
      isPrebuilt: false, // Themes loaded from JSON are custom
      isMonochrome: json['isMonochrome'] ?? false, // <--- NEW
    );
  }
}

/// Manages the active Theme Mode and the active Color Theme across the app.
class ThemeManager extends ChangeNotifier {
  CompassThemeMode _themeMode = CompassThemeMode.dark;
  CompassThemeMode get themeMode => _themeMode;

  set themeMode(CompassThemeMode mode) {
    if (_themeMode != mode) {
      _themeMode = mode;
      _saveSettings(); // <--- Auto-save on change
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
      lightBackground: const Color(0xFFF0F0F0),
      dimBackground: const Color(0xFF2D2F33),   
      darkBackground: const Color(0xFF1E1E1E),  
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'ocean_blue',
      name: 'Ocean Blue',
      seedColor: Colors.blue,
      lightBackground: const Color(0xFFF0F4F8),
      dimBackground: const Color(0xFF1E293B),   
      darkBackground: const Color(0xFF0F172A),
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'engine',
      name: 'Engine',
      seedColor: const Color(0xFF4188D2),
      lightBackground: const Color(0xFFE5E7EB),
      dimBackground: const Color(0xFF2C2E3A),   
      darkBackground: const Color(0xFF21232B),
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'nord',
      name: 'Nord',
      seedColor: const Color(0xFF88C0D0),       
      lightBackground: const Color(0xFFECEFF4), 
      dimBackground: const Color(0xFF3B4252),   
      darkBackground: const Color(0xFF2E3440),  
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'gruvbox',
      name: 'Gruvbox',
      seedColor: const Color(0xFFFE8019),       
      lightBackground: const Color(0xFFE0DCD3), 
      dimBackground: const Color(0xFF3C3836),   
      darkBackground: const Color(0xFF282828),  
      isPrebuilt: true,
    ),
    CompassTheme(
      id: 'monochrome',
      name: 'Monochrome',
      seedColor: const Color(0xFF757575),       
      lightBackground: const Color(0xFFCCCCCC), 
      dimBackground: const Color(0xFF333333),   
      darkBackground: const Color(0xFF111111),  
      isPrebuilt: true,
      isMonochrome: true, // <--- NEW: Force pure grayscale rendering for this theme
    ),
  ];

  List<CompassTheme> get themes => _themes;

  ThemeManager() {
    _activeTheme = _themes.first;
    _loadSettings(); // <--- Load settings immediately on startup
  }

  void setActiveTheme(CompassTheme theme) {
    if (_activeTheme != theme) {
      _activeTheme = theme;
      _saveSettings(); // <--- Auto-save on change
      notifyListeners();
    }
  }

  void addCustomTheme(CompassTheme theme) {
    _themes.add(theme);
    _activeTheme = theme;
    _saveSettings(); // <--- Auto-save custom themes
    notifyListeners();
  }

  void updateCustomTheme(CompassTheme updatedTheme) {
    final index = _themes.indexWhere((t) => t.id == updatedTheme.id);
    if (index != -1 && !_themes[index].isPrebuilt) {
      _themes[index] = updatedTheme;
      if (_activeTheme.id == updatedTheme.id) {
        _activeTheme = updatedTheme;
      }
      _saveSettings(); // <--- Auto-save edits
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
      _saveSettings(); // <--- Auto-save deletions
      notifyListeners();
    }
  }

  // ===========================================================================
  // FILE I/O FOR PERSISTENT SETTINGS
  // ===========================================================================

  File get _settingsFile => File('compass_settings.json');

  Future<void> _loadSettings() async {
    try {
      final file = _settingsFile;
      if (!await file.exists()) return;

      final data = await file.readAsString();
      final json = jsonDecode(data) as Map<String, dynamic>;

      // Load Theme Mode
      if (json.containsKey('themeMode')) {
        final modeStr = json['themeMode'] as String;
        _themeMode = CompassThemeMode.values.firstWhere(
          (e) => e.name == modeStr,
          orElse: () => CompassThemeMode.dark,
        );
      }

      // Load Custom Themes
      if (json.containsKey('customThemes')) {
        final customList = json['customThemes'] as List;
        for (var item in customList) {
          try {
            _themes.add(CompassTheme.fromJson(item));
          } catch (e) {
            debugPrint('Failed to load a custom theme: $e');
          }
        }
      }

      // Restore Active Theme
      if (json.containsKey('activeThemeId')) {
        final targetId = json['activeThemeId'] as String;
        _activeTheme = _themes.firstWhere(
          (t) => t.id == targetId,
          orElse: () => _themes.first,
        );
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Error loading compass settings: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final customThemes = _themes.where((t) => !t.isPrebuilt).map((t) => t.toJson()).toList();

      final json = {
        'themeMode': _themeMode.name,
        'activeThemeId': _activeTheme.id,
        'customThemes': customThemes,
      };

      await _settingsFile.writeAsString(jsonEncode(json));
    } catch (e) {
      debugPrint('Error saving compass settings: $e');
    }
  }
}