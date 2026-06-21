// ./lib/ui/workspace/menu_bar.dart

import 'package:flutter/material.dart';
import '../../engine.dart';
import 'dialogs.dart';

class CompassMenuBar extends StatelessWidget {
  final CompassEngine engine;
  final ValueNotifier<ThemeMode> themeNotifier;
  final bool showScaffolding;
  final VoidCallback onToggleScaffolding;
  final bool showHandles; // <--- NEW
  final VoidCallback onToggleHandles; // <--- NEW
  final VoidCallback onClearCanvas;

  const CompassMenuBar({
    super.key,
    required this.engine,
    required this.themeNotifier,
    required this.showScaffolding,
    required this.onToggleScaffolding,
    required this.showHandles, // <--- NEW
    required this.onToggleHandles, // <--- NEW
    required this.onClearCanvas,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          Expanded(
            child: MenuBar(
              style: MenuStyle(
                backgroundColor: WidgetStateProperty.all(Colors.transparent),
                elevation: WidgetStateProperty.all(0),
              ),
              children: [
                SubmenuButton(
                  menuChildren: [
                    MenuItemButton(
                      onPressed: () => CompassDialogs.showAboutDialog(context),
                      leadingIcon: const Icon(Icons.info_outline),
                      child: const Text('About Compass'),
                    ),
                  ],
                  child: const Text(
                    'Compass',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                SubmenuButton(
                  menuChildren: [
                    MenuItemButton(
                      onPressed: onClearCanvas,
                      leadingIcon: const Icon(Icons.insert_drive_file_outlined),
                      child: const Text('New Project'),
                    ),
                    const CustomMenuItemDivider(),
                    MenuItemButton(
                      onPressed: () => CompassDialogs.showOpenProject(context, engine),
                      leadingIcon: const Icon(Icons.folder_open),
                      child: const Text('Open Project...'),
                    ),
                    MenuItemButton(
                      onPressed: () => CompassDialogs.showSaveProject(context, engine),
                      leadingIcon: const Icon(Icons.save),
                      child: const Text('Save Project...'),
                    ),
                    const CustomMenuItemDivider(),
                    MenuItemButton(
                      onPressed: () => CompassDialogs.showLoadReferenceImage(context, engine),
                      leadingIcon: const Icon(Icons.add_photo_alternate_outlined),
                      child: const Text('Load Reference Image...'),
                    ),
                    const CustomMenuItemDivider(),
                    MenuItemButton(
                      onPressed: () => CompassDialogs.showExportSVG(context, engine),
                      leadingIcon: const Icon(Icons.image),
                      child: const Text('Export as SVG...'),
                    ),
                    MenuItemButton(
                      onPressed: () => CompassDialogs.showExportPNG(context, engine),
                      leadingIcon: const Icon(Icons.photo_camera),
                      child: const Text('Export as PNG...'),
                    ),
                  ],
                  child: const Text('File'),
                ),
                SubmenuButton(
                  menuChildren: [
                    MenuItemButton(
                      onPressed: () => engine.undo(),
                      leadingIcon: const Icon(Icons.undo),
                      child: const Text('Undo (Ctrl+Z)'),
                    ),
                    const CustomMenuItemDivider(),
                    MenuItemButton(
                      onPressed: onClearCanvas,
                      leadingIcon: const Icon(Icons.delete_outline),
                      child: const Text('Clear Canvas'),
                    ),
                  ],
                  child: const Text('Edit'),
                ),
                SubmenuButton(
                  menuChildren: [
                    MenuItemButton(
                      onPressed: onToggleScaffolding,
                      leadingIcon: Icon(showScaffolding ? Icons.visibility : Icons.visibility_off),
                      child: Text(showScaffolding ? 'Hide Scaffolding' : 'Show Scaffolding'),
                    ),
                    // <--- NEW: Menu Item for toggling Handles --->
                    MenuItemButton(
                      onPressed: onToggleHandles,
                      leadingIcon: Icon(showHandles ? Icons.gesture : Icons.timeline),
                      child: Text(showHandles ? 'Hide Handles' : 'Show Handles'),
                    ),
                    const CustomMenuItemDivider(),
                    SubmenuButton(
                      menuChildren: [
                        MenuItemButton(
                          onPressed: () => themeNotifier.value = ThemeMode.light,
                          leadingIcon: const Icon(Icons.light_mode),
                          child: const Text('Light Mode'),
                        ),
                        MenuItemButton(
                          onPressed: () => themeNotifier.value = ThemeMode.dark,
                          leadingIcon: const Icon(Icons.dark_mode),
                          child: const Text('Dark Mode'),
                        ),
                      ],
                      child: const Text('Theme'),
                    ),
                  ],
                  child: const Text('View'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CustomMenuItemDivider extends StatelessWidget {
  const CustomMenuItemDivider({super.key});
  
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.0),
      child: Divider(height: 1),
    );
  }
}