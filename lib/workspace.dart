// ./lib/workspace.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'engine.dart';
import 'ui/canvas/compass_canvas.dart';

// --- UI COMPONENTS ---
import 'ui/panels/layers_panel.dart';
import 'ui/panels/properties_panel.dart';
import 'ui/workspace/menu_bar.dart';
import 'ui/workspace/dialogs.dart';

class CompassWorkspace extends StatefulWidget {
  final ValueNotifier<ThemeMode> themeNotifier;

  const CompassWorkspace({
    super.key,
    required this.themeNotifier,
  });

  @override
  State<CompassWorkspace> createState() => _CompassWorkspaceState();
}

class _CompassWorkspaceState extends State<CompassWorkspace> {
  late CompassEngine _engine;
  bool _showScaffolding = true;
  bool _showHandles = true; // <--- NEW: State for showing/hiding Bezier handles

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

  // <--- NEW: Toggle method for handles
  void _toggleHandles() {
    setState(() {
      _showHandles = !_showHandles;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                themeNotifier: widget.themeNotifier,
                showScaffolding: _showScaffolding,
                onToggleScaffolding: _toggleScaffolding,
                showHandles: _showHandles, // <--- NEW
                onToggleHandles: _toggleHandles, // <--- NEW
                onClearCanvas: _clearCanvas,
              ),

              // === WORKSPACE BODY ===
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRect(
                        child: CompassCanvas(
                          engine: _engine,
                          showScaffolding: _showScaffolding,
                          onToggleScaffolding: _toggleScaffolding, 
                          showHandles: _showHandles, // <--- NEW
                          onToggleHandles: _toggleHandles, // <--- NEW
                        ),
                      ),
                    ),
                    
                    Container(
                      width: 280, 
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        border: Border(
                          left: BorderSide(color: theme.dividerColor, width: 1),
                        ),
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