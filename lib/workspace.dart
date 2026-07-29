// lib/workspace.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine.dart';
import 'theme_manager.dart'; // <--- NEW: Import ThemeManager
import 'ui/canvas/compass_canvas.dart';

// --- UI COMPONENTS ---
import 'ui/panels/layers_panel.dart';
import 'ui/panels/properties_panel.dart';
import 'ui/workspace/menu_bar.dart';
import 'ui/workspace/dialogs.dart';

class CompassWorkspace extends StatefulWidget {
  final ThemeManager themeManager; // <--- CHANGED: Use ThemeManager

  const CompassWorkspace({
    super.key,
    required this.themeManager, // <--- CHANGED
  });

  @override
  State<CompassWorkspace> createState() => _CompassWorkspaceState();
}

class _CompassWorkspaceState extends State<CompassWorkspace> {
  late CompassEngine _engine;
  bool _showScaffolding = true;
  bool _showHandles = true; // State for showing/hiding Bezier handles

  // --- NEW: GHOST VERTICES ---
  // When true, the vertex DOTS (and tension boxes) are not painted, but hit
  // testing stays fully live: you can still click, drag, box-select, and hover
  // the invisible points -- the hover ring and selection highlight still paint,
  // so the moment your cursor finds a hidden vertex you get feedback. This is
  // the "work on the pure shape, but keep sculpting it" mode: scaffolding
  // stays on (wireframes, tools, interaction), only the dot clutter goes.
  // Distinct from _showScaffolding=false, which hides everything AND disables
  // interaction with points.
  bool _ghostVertices = false;
  bool _showFpsOverlay = false;
  
  // NEW: State for the resizable right panel width
  double _rightPanelWidth = 280.0;

  final List<Color> _swatchColors = [
    const Color(0xFF222222), 
    Colors.black,
    Colors.white,
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.blueGrey,
  ];

  @override
  void initState() {
    super.initState();
    _engine = CompassEngine();
  }

  @override
  void dispose() {
    _engine.dispose();
    super.dispose();
  }

  void _clearCanvas() {
    setState(() {
      _engine.dispose();
      _engine = CompassEngine(); 
    });
  }

  void _toggleScaffolding() {
    setState(() {
      _showScaffolding = !_showScaffolding;
    });
  }

  // Toggle method for handles
  void _toggleHandles() {
    setState(() {
      _showHandles = !_showHandles;
    });
  }

  // <--- NEW: Toggle method for ghost vertices
  void _toggleGhostVertices() {
    setState(() {
      _ghostVertices = !_ghostVertices;
    });
  }

  void _toggleFpsOverlay() {
    setState(() {
      _showFpsOverlay = !_showFpsOverlay;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    // <--- FIX: Ensure panels and toolbars use the specific theme backgrounds 
    // rather than defaulting to bright surface colors in Light Mode. --->
    final bool isLightMode = widget.themeManager.themeMode == CompassThemeMode.light;
    final Color panelBackgroundColor = isLightMode 
        ? Colors.white // Force pure white for the side panel so the gray canvas pops
        : theme.colorScheme.surface;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () => _engine.undo(),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () => _engine.undo(),
      },
      child: Focus(
        autofocus: true, 
        child: Scaffold(
          body: Column(
            children: [
              // === DESKTOP MENU BAR ===
              CompassMenuBar(
                engine: _engine,
                themeManager: widget.themeManager, // <--- CHANGED: Pass ThemeManager
                showScaffolding: _showScaffolding,
                onToggleScaffolding: _toggleScaffolding,
                showHandles: _showHandles,
                onToggleHandles: _toggleHandles,
                ghostVertices: _ghostVertices, // <--- NEW
                onToggleGhostVertices: _toggleGhostVertices, // <--- NEW
                showFpsOverlay: _showFpsOverlay,
                onToggleFpsOverlay: _toggleFpsOverlay,
                onClearCanvas: _clearCanvas,
              ),

              // === WORKSPACE BODY ===
              Expanded(
                child: Row(
                  children: [
                    // === CANVAS (Expands to fill remaining space) ===
                    Expanded(
                      child: ClipRect(
                        child: CompassCanvas(
                          engine: _engine,
                          showScaffolding: _showScaffolding,
                          onToggleScaffolding: _toggleScaffolding, 
                          showHandles: _showHandles,
                          onToggleHandles: _toggleHandles,
                          ghostVertices: _ghostVertices, // <--- NEW
                          onToggleGhostVertices: _toggleGhostVertices, // <--- NEW
                          showFpsOverlay: _showFpsOverlay,
                        ),
                      ),
                    ),

                    // === HORIZONTAL SLIDER DRAG HANDLE ===
                    MouseRegion(
                      cursor: SystemMouseCursors.resizeColumn,
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onPanUpdate: (details) {
                          setState(() {
                            // Invert delta because panel is anchored to the right
                            _rightPanelWidth -= details.delta.dx;
                            // Constrain the panel width so it doesn't break the layout or hide completely
                            _rightPanelWidth = _rightPanelWidth.clamp(220.0, 600.0);
                          });
                        },
                        child: Container(
                          width: 4,
                          decoration: BoxDecoration(
                            color: panelBackgroundColor, // <--- FIXED
                            border: Border(
                              left: BorderSide(color: theme.dividerColor, width: 1),
                            )
                          ),
                        ),
                      ),
                    ),

                    // === RIGHT PANEL (Hierarchy & Properties) ===
                    Container(
                      width: _rightPanelWidth, 
                      decoration: BoxDecoration(
                        color: panelBackgroundColor, // <--- FIXED
                      ),
                      child: DefaultTabController(
                        length: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TabBar(
                              labelColor: theme.colorScheme.primary,
                              unselectedLabelColor: theme.unselectedWidgetColor,
                              indicatorColor: theme.colorScheme.primary,
                              tabs: const [
                                Tab(text: 'Layers'),
                                Tab(text: 'Properties'),
                              ],
                            ),
                            Expanded(
                              child: TabBarView(
                                children: [
                                  LayersPanel(
                                    engine: _engine, 
                                    onLoadReferenceImage: () => CompassDialogs.showLoadReferenceImage(context, _engine),
                                  ),
                                  PropertiesPanel(
                                    engine: _engine, 
                                    swatchColors: _swatchColors
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}