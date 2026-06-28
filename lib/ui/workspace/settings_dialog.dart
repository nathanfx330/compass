// lib/ui/workspace/settings_dialog.dart

import 'package:flutter/material.dart';
import '../../../theme_manager.dart';
import '../widgets/compass_color_picker.dart';

class SettingsDialog extends StatelessWidget {
  final ThemeManager themeManager;

  const SettingsDialog({super.key, required this.themeManager});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Preferences'),
      content: SizedBox(
        width: 500,
        height: 600,
        child: DefaultTabController(
          length: 1, // Expandable later if you add General, Shortcuts, etc.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const TabBar(
                tabs: [Tab(text: 'Appearance & Themes')],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TabBarView(
                  children: [
                    _AppearanceTab(themeManager: themeManager),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _AppearanceTab extends StatelessWidget {
  final ThemeManager themeManager;

  const _AppearanceTab({required this.themeManager});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeManager,
      builder: (context, _) {
        final theme = Theme.of(context);
        return ListView(
          children: [
            Text('Color Mode', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode), label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode), label: Text('Dark')),
              ],
              selected: {themeManager.themeMode},
              onSelectionChanged: (set) => themeManager.themeMode = set.first,
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Themes', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                TextButton.icon(
                  onPressed: () => _showEditThemeDialog(context, themeManager, null),
                  icon: const Icon(Icons.add),
                  label: const Text('Custom Theme'),
                )
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: themeManager.themes.map((t) => _buildThemeCard(context, t, theme)).toList(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildThemeCard(BuildContext context, CompassTheme t, ThemeData theme) {
    final isActive = themeManager.activeTheme.id == t.id;
    return GestureDetector(
      onTap: () => themeManager.setActiveTheme(t),
      child: Container(
        width: 150,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isActive ? theme.colorScheme.primary : theme.dividerColor,
            width: isActive ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 40,
              decoration: BoxDecoration(
                color: t.seedColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
              ),
              child: Row(
                children: [
                  Expanded(child: Container(color: t.lightBackground.withOpacity(0.9))),
                  Expanded(child: Container(color: t.darkBackground.withOpacity(0.9))),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      t.name,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!t.isPrebuilt)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: () => _showEditThemeDialog(context, themeManager, t),
                          child: const Icon(Icons.edit, size: 14),
                        ),
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => themeManager.deleteCustomTheme(t.id),
                          child: const Icon(Icons.delete, size: 14, color: Colors.redAccent),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditThemeDialog(BuildContext context, ThemeManager manager, CompassTheme? existingTheme) {
    showDialog(
      context: context,
      builder: (context) => _EditThemeDialog(manager: manager, theme: existingTheme),
    );
  }
}

class _EditThemeDialog extends StatefulWidget {
  final ThemeManager manager;
  final CompassTheme? theme; // Null if creating new

  const _EditThemeDialog({required this.manager, this.theme});

  @override
  State<_EditThemeDialog> createState() => _EditThemeDialogState();
}

class _EditThemeDialogState extends State<_EditThemeDialog> {
  late TextEditingController _nameCtrl;
  late Color _seedColor;
  late Color _lightBg;
  late Color _darkBg;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.theme?.name ?? 'My Custom Theme');
    _seedColor = widget.theme?.seedColor ?? Colors.teal;
    _lightBg = widget.theme?.lightBackground ?? const Color(0xFFF0F0F0);
    _darkBg = widget.theme?.darkBackground ?? const Color(0xFF1E1E1E);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickColor(String label, Color current, ValueChanged<Color> onSelected) async {
    final picked = await showCompassColorPicker(context, initialColor: current);
    if (picked != null) {
      setState(() => onSelected(picked));
    }
  }

  Widget _colorRow(String label, Color current, ValueChanged<Color> onSelected) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        GestureDetector(
          onTap: () => _pickColor(label, current, onSelected),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: current,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.theme == null ? 'New Theme' : 'Edit Theme'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Theme Name', 
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            _colorRow('Primary (Seed) Color', _seedColor, (c) => _seedColor = c),
            const SizedBox(height: 12),
            _colorRow('Light Canvas Background', _lightBg, (c) => _lightBg = c),
            const SizedBox(height: 12),
            _colorRow('Dark Canvas Background', _darkBg, (c) => _darkBg = c),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(), 
          child: const Text('Cancel')
        ),
        FilledButton(
          onPressed: () {
            if (widget.theme == null) {
              widget.manager.addCustomTheme(CompassTheme(
                id: UniqueKey().toString(),
                name: _nameCtrl.text,
                seedColor: _seedColor,
                lightBackground: _lightBg,
                darkBackground: _darkBg,
              ));
            } else {
              widget.manager.updateCustomTheme(widget.theme!.copyWith(
                name: _nameCtrl.text,
                seedColor: _seedColor,
                lightBackground: _lightBg,
                darkBackground: _darkBg,
              ));
            }
            Navigator.of(context).pop();
          },
          child: const Text('Save Theme'),
        ),
      ],
    );
  }
}