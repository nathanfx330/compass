// lib/ui/canvas/canvas_hud.dart
import 'dart:math';
import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/rectangle.dart';
import 'canvas_controller.dart'; 

class CanvasHUD extends StatelessWidget {
  final CompassEngine engine;
  final bool showScaffolding;
  final CompassTool currentTool;
  final ValueChanged<CompassTool> onToolSelected;
  
  final bool isRPressed;
  final bool isShiftRPressed;
  final bool isShiftPressed;
  final bool isAPressed;
  final bool isFPressed;
  final bool is1Pressed; // --- NEW
  final bool is2Pressed; // --- NEW

  final bool addVertexActive;
  final Offset panOffset;
  final double canvasScale;

  const CanvasHUD({
    super.key,
    required this.engine,
    required this.showScaffolding,
    required this.currentTool,
    required this.onToolSelected,
    required this.isRPressed,
    required this.isShiftRPressed,
    required this.isShiftPressed,
    required this.isAPressed,
    required this.isFPressed,
    required this.is1Pressed, // --- NEW
    required this.is2Pressed, // --- NEW
    required this.addVertexActive,
    required this.panOffset,
    required this.canvasScale,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    String overlayText = "";
    Color overlayColor = Colors.transparent;
    
    if (isShiftRPressed) {
      overlayText = 'SHIFT+R : ROTATE HIERARCHY';
      overlayColor = Colors.deepOrangeAccent;
    } else if (isRPressed) {
      overlayText = 'R : ROTATE LOCAL';
      overlayColor = Colors.orangeAccent;
    } else if (isAPressed) {
      overlayText = 'A : VERTEX TENSION';
      overlayColor = Colors.orangeAccent; 
    } else if (isFPressed) { 
      overlayText = 'F : FILLET CORNER';
      overlayColor = Colors.greenAccent.shade700;
    } else if (addVertexActive) { 
      overlayText = 'Q : ADD VERTEX';
      overlayColor = Colors.green.shade600;
    } else if (isShiftPressed && currentTool == CompassTool.select) {
      overlayText = 'SHIFT : PAN SHAPE';
      overlayColor = Colors.blueAccent;
    } else if (is1Pressed) { // --- NEW HUD LOGIC
      overlayText = '1 : LOCK HORIZONTAL AXIS';
      overlayColor = Colors.blueGrey;
    } else if (is2Pressed) { // --- NEW HUD LOGIC
      overlayText = '2 : LOCK VERTICAL AXIS';
      overlayColor = Colors.blueGrey;
    }

    return Stack(
      children: [
        // --- HUD OVERLAY FOR TRANSFORMATION MODES ---
        if (overlayText.isNotEmpty && showScaffolding)
          Positioned(
            top: 24,
            right: 24,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: overlayColor.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    )
                  ],
                ),
                child: Text(
                  overlayText,
                  style: const TextStyle(
                    fontSize: 24, 
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 2.0,
                  ),
                ),
              ),
            ),
          ),

        // --- ON-CANVAS HUD FOR SELECTED SHAPES ---
        ListenableBuilder(
          listenable: engine,
          builder: (context, _) {
            final selectedShape = engine.selectedShape;
            
            if (showScaffolding && selectedShape is CompassSpiral) {
              final logicalCx = selectedShape.center.x.value;
              final logicalCy = selectedShape.center.y.value;
              
              final physicalX = logicalCx * canvasScale + panOffset.dx;
              final physicalY = logicalCy * canvasScale + panOffset.dy;

              return Positioned(
                left: physicalX + 20, 
                top: physicalY - 50,
                child: Container(
                  width: 220,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.dividerColor),
                    boxShadow: [
                      BoxShadow(
                        color: isDark ? Colors.black54 : Colors.black26,
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Spiral Properties', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            iconSize: 14,
                            icon: const Icon(Icons.close),
                            onPressed: () => engine.selectShape(null),
                          )
                        ],
                      ),
                      const Divider(),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Direction:', style: TextStyle(fontSize: 12)),
                          SegmentedButton<bool>(
                            segments: const [
                              ButtonSegment(value: false, icon: Icon(Icons.rotate_left, size: 16)),
                              ButtonSegment(value: true, icon: Icon(Icons.rotate_right, size: 16)),
                            ],
                            selected: {selectedShape.isClockwise},
                            onSelectionChanged: (Set<bool> newSelection) {
                              engine.updateSpiral(selectedShape, isClockwise: newSelection.first);
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text('Revolutions: ${selectedShape.revolutions.toStringAsFixed(1)}', style: const TextStyle(fontSize: 12)),
                      Slider(
                        value: selectedShape.revolutions,
                        min: 0.1,
                        max: 10.0,
                        divisions: 99,
                        onChanged: (val) {
                          engine.updateSpiral(selectedShape, revolutions: val);
                        },
                      ),
                    ],
                  ),
                ),
              );
            } else if (showScaffolding && selectedShape is CompassRectangle) { 
              final logicalX = min(selectedShape.p1.x.value, selectedShape.p2.x.value);
              final logicalY = min(selectedShape.p1.y.value, selectedShape.p2.y.value);
              
              final physicalX = logicalX * canvasScale + panOffset.dx;
              final physicalY = logicalY * canvasScale + panOffset.dy;

              final width = (selectedShape.p1.x.value - selectedShape.p2.x.value).abs();
              final height = (selectedShape.p1.y.value - selectedShape.p2.y.value).abs();
              final maxRadius = max(0.1, min(width, height) / 2);

              return Positioned(
                left: physicalX + 20, 
                top: physicalY - 50,
                child: Container(
                  width: 220,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.dividerColor),
                    boxShadow: [
                      BoxShadow(
                        color: isDark ? Colors.black54 : Colors.black26,
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      )
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Rectangle Properties', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            iconSize: 14,
                            icon: const Icon(Icons.close),
                            onPressed: () => engine.selectShape(null),
                          )
                        ],
                      ),
                      const Divider(),
                      
                      Row(
                        children: [
                          SizedBox(
                            height: 24,
                            width: 24,
                            child: Checkbox(
                              value: selectedShape.isSquare,
                              onChanged: (val) {
                                if (val != null) {
                                  engine.toggleRectangleSquare(selectedShape, val);
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text('Lock as Perfect Square', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                      const SizedBox(height: 8),

                      Text('Corner Radius: ${selectedShape.cornerRadius.value.toStringAsFixed(1)}', style: const TextStyle(fontSize: 12)),
                      Slider(
                        value: selectedShape.cornerRadius.value.clamp(0.0, maxRadius),
                        min: 0.0,
                        max: maxRadius,
                        onChanged: (val) {
                          engine.updateRectangleRadius(selectedShape, val);
                        },
                      ),
                    ],
                  ),
                ),
              );
            }
            return const SizedBox.shrink();
          },
        ),

        // --- TOOLBAR ---
        if (showScaffolding)
          Positioned(
            bottom: 30,
            left: 30,
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.dividerColor, width: 1),
                boxShadow: [
                  BoxShadow(
                    color: isDark ? Colors.black54 : Colors.black26,
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  )
                ],
              ),
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  _buildToolButton(
                    icon: Icons.near_me_outlined,
                    tooltip: 'Select & Drag',
                    tool: CompassTool.select,
                    theme: theme,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    icon: Icons.add_circle_outline,
                    tooltip: 'Add Point',
                    tool: CompassTool.addPoint,
                    theme: theme,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    icon: Icons.show_chart,
                    tooltip: 'Draw Line',
                    tool: CompassTool.addLine,
                    theme: theme,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    icon: Icons.radio_button_unchecked,
                    tooltip: 'Draw Circle',
                    tool: CompassTool.addCircle,
                    theme: theme,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    icon: Icons.crop_square,
                    tooltip: 'Draw Rectangle',
                    tool: CompassTool.addRect,
                    theme: theme,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    icon: Icons.cyclone,
                    tooltip: 'Draw Golden Spiral',
                    tool: CompassTool.addSpiral,
                    theme: theme,
                  ),
                  const SizedBox(width: 8),
                  _buildToolButton(
                    icon: Icons.draw,
                    tooltip: 'Draw X-Spline',
                    tool: CompassTool.addPen,
                    theme: theme,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildToolButton({
    required IconData icon,
    required String tooltip,
    required CompassTool tool,
    required ThemeData theme,
  }) {
    final isSelected = currentTool == tool;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: isSelected ? theme.colorScheme.primary.withOpacity(0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onToolSelected(tool),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Icon(
              icon,
              color: isSelected ? theme.colorScheme.primary : theme.iconTheme.color,
            ),
          ),
        ),
      ),
    );
  }
}