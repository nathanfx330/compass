// lib/ui/panels/properties_panel.dart

import 'package:flutter/material.dart';
import '../../engine.dart';
import '../../models/geometry/shape.dart';  
import '../../models/geometry/circle.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/mesh.dart';
import '../../models/geometry/image.dart';
import '../widgets/compass_color_picker.dart';

class PropertiesPanel extends StatefulWidget {
  final CompassEngine engine;
  final List<Color> swatchColors;

  const PropertiesPanel({
    super.key,
    required this.engine,
    required this.swatchColors,
  });

  @override
  State<PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends State<PropertiesPanel> {
  final TextEditingController _uniformController = TextEditingController(text: '10.0');
  final TextEditingController _startTaperController = TextEditingController(text: '2.0');
  final TextEditingController _endTaperController = TextEditingController(text: '20.0');

  @override
  void dispose() {
    _uniformController.dispose();
    _startTaperController.dispose();
    _endTaperController.dispose();
    super.dispose();
  }

  // A color counts as "custom" — and lights up the Custom chip — when it is a
  // real color that is NOT transparent and NOT one of the presets. Preset colors
  // are stored as the MaterialColor objects from swatchColors, so an exact
  // identity match here works; a picked color is a plain Color and will never
  // match a MaterialColor, which is exactly why a hand-picked value reads as
  // custom even if its hex coincides with a preset's shade.
  bool _isCustomColor(Color c) =>
      c != Colors.transparent && !widget.swatchColors.contains(c);

  // Per-op color for the small stroke-region labels, matching the layers panel.
  Color _strokeOpColor(CompassBooleanOp op) {
    switch (op) {
      case CompassBooleanOp.add:
        return Colors.green;
      case CompassBooleanOp.subtract:
        return Colors.redAccent;
      case CompassBooleanOp.intersect:
        return Colors.blueAccent;
      case CompassBooleanOp.none:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: widget.engine,
      builder: (context, _) {
        final activeLayer = widget.engine.activeLayer;
        final selectedShape = widget.engine.selectedShape;
        final CompassShape? strokeShape =
            selectedShape is CompassCircle ||
                    selectedShape is CompassRectangle ||
                    selectedShape is CompassXSpline
                ? selectedShape
                : null;

        if (activeLayer == null) {
          return const Center(
            child: Text(
              'Select a layer to edit properties.',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Layer: ${activeLayer.name}',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              
              Text(
                'Fill Color',
                style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildColorSwatch(
                    color: Colors.transparent, 
                    isSelected: activeLayer.color == Colors.transparent, 
                    theme: theme,
                    onTap: () => widget.engine.changeLayerColor(activeLayer, Colors.transparent),
                    isNone: true,
                  ),
                  ...widget.swatchColors.map((color) {
                    return _buildColorSwatch(
                      color: color, 
                      isSelected: activeLayer.color == color, 
                      theme: theme,
                      onTap: () => widget.engine.changeLayerColor(activeLayer, color),
                    );
                  }),
                  _buildCustomSwatch(
                    context: context,
                    currentColor: activeLayer.color,
                    isSelected: _isCustomColor(activeLayer.color),
                    theme: theme,
                    onPicked: (c) => widget.engine.changeLayerColor(activeLayer, c),
                  ),
                ],
              ),
              
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 24),

              Text(
                'Stroke Color',
                style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildColorSwatch(
                    color: Colors.transparent, 
                    isSelected: activeLayer.strokeColor == Colors.transparent, 
                    theme: theme,
                    onTap: () => widget.engine.changeLayerStrokeColor(activeLayer, Colors.transparent),
                    isNone: true,
                  ),
                  ...widget.swatchColors.map((color) {
                    return _buildColorSwatch(
                      color: color, 
                      isSelected: activeLayer.strokeColor == color, 
                      theme: theme,
                      onTap: () => widget.engine.changeLayerStrokeColor(activeLayer, color),
                    );
                  }),
                  _buildCustomSwatch(
                    context: context,
                    currentColor: activeLayer.strokeColor,
                    isSelected: _isCustomColor(activeLayer.strokeColor),
                    theme: theme,
                    onPicked: (c) => widget.engine.changeLayerStrokeColor(activeLayer, c),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              Row(
                children: [
                  Text(
                    'Stroke Width',
                    style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
                  ),
                  const Spacer(),
                  Text(
                    activeLayer.strokeWidth.toStringAsFixed(1),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Slider(
                value: activeLayer.strokeWidth,
                min: 0.0,
                max: 20.0,
                divisions: 40,
                activeColor: theme.colorScheme.primary,
                onChanged: (value) {
                  widget.engine.changeLayerStrokeWidth(activeLayer, value);
                },
              ),

              if (selectedShape is CompassImage) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 24),
                Row(
                  children: [
                    const Icon(Icons.image_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'IMG · ${selectedShape.displayName}',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  selectedShape.imagePath,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.textTheme.bodySmall?.color?.withOpacity(0.7),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Opacity'),
                    const Spacer(),
                    Text('${(selectedShape.opacity * 100).round()}%'),
                  ],
                ),
                Slider(
                  value: selectedShape.opacity.clamp(0.0, 1.0).toDouble(),
                  min: 0.0,
                  max: 1.0,
                  divisions: 100,
                  onChanged: (value) =>
                      widget.engine.setImageOpacity(selectedShape, value),
                ),
                Text(
                  selectedShape.image == null
                      ? 'Source image is unavailable. The Boolean mask remains editable and exportable.'
                      : "Pixels render through the layer's live Boolean mask.",
                  style: TextStyle(
                    fontSize: 12,
                    color: selectedShape.image == null
                        ? Colors.orangeAccent
                        : theme.textTheme.bodySmall?.color?.withOpacity(0.8),
                  ),
                ),
              ],

              // --- STROKE REGIONS SECTION (outward-stacked per-shape stroke stack) ---
              if (strokeShape != null &&
                  strokeShape.strokeRegions.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 24),

                Row(
                  children: [
                    const Icon(Icons.donut_large, size: 18, color: Colors.orangeAccent),
                    const SizedBox(width: 8),
                    Text(
                      'Stroke Regions',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Each band stacks outward from the shape outline. Add or remove '
                  'strokes from the shape\'s row in the hierarchy.',
                  style: TextStyle(fontSize: 12, color: theme.textTheme.bodySmall?.color?.withOpacity(0.8)),
                ),
                const SizedBox(height: 8),

                ...List.generate(strokeShape.strokeRegions.length, (i) {
                  final region = strokeShape.strokeRegions[i];
                  final double sliderVal = region.width.clamp(0.0, 100.0);
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Stroke ${i + 1}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: theme.textTheme.bodySmall?.color,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              region.op.name.toUpperCase(),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: _strokeOpColor(region.op),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              region.width.toStringAsFixed(1),
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Slider(
                          value: sliderVal,
                          min: 0.0,
                          max: 100.0,
                          divisions: 200,
                          activeColor: _strokeOpColor(region.op),
                          onChanged: (value) {
                            widget.engine.setStrokeRegionWidth(strokeShape, i, value);
                          },
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 8),
              ],

              // --- AREA STROKE PROFILE SECTION ---
              if (selectedShape is CompassXSpline) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 24),

                // --- Corner Pulley properties (round + miter) ---
                if (widget.engine.selectedPoints.isNotEmpty) ...[
                  Builder(
                    builder: (context) {
                      // Look for any active constraints on the currently selected nodes
                      CompassSplineNode? activeCircleConstraint;
                      CompassSplineNode? activeMiterConstraint;
                      
                      for (var node in selectedShape.nodes) {
                        if (widget.engine.selectedPoints.contains(node.point)) {
                          if (node.cornerRadius.value > 0.01) {
                            activeCircleConstraint = node;
                          } else if (node.miterSize.value > 0.01) {
                            activeMiterConstraint = node;
                          }
                        }
                      }
                      
                      if (activeCircleConstraint == null && activeMiterConstraint == null) {
                        return const SizedBox.shrink();
                      }

                      final bool isCircle = activeCircleConstraint != null;
                      final node = isCircle ? activeCircleConstraint! : activeMiterConstraint!;
                      final double val = isCircle ? node.cornerRadius.value : node.miterSize.value;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isCircle ? 'Circular Pulley Size' : 'Miter Pulley Size',
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(
                                isCircle ? Icons.radio_button_unchecked : Icons.square_foot, 
                                size: 16, 
                                color: isCircle ? Colors.lightBlueAccent : Colors.deepOrangeAccent
                              ),
                              const SizedBox(width: 8),
                              Text(val.toStringAsFixed(1), style: const TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          Slider(
                            value: val.clamp(0.0, 500.0),
                            min: 0.0,
                            max: 500.0,
                            activeColor: isCircle ? Colors.lightBlueAccent : Colors.deepOrangeAccent,
                            onChanged: (newValue) {
                              if (isCircle) {
                                for (var n in selectedShape.nodes) {
                                  if (widget.engine.selectedPoints.contains(n.point) && n.cornerRadius.value > 0) {
                                    n.cornerRadius.value = newValue;
                                  }
                                }
                              } else {
                                for (var n in selectedShape.nodes) {
                                  if (widget.engine.selectedPoints.contains(n.point) && n.miterSize.value > 0) {
                                    n.miterSize.value = newValue;
                                  }
                                }
                              }
                            },
                          ),
                          const SizedBox(height: 24),
                          const Divider(),
                          const SizedBox(height: 24),
                        ],
                      );
                    },
                  ),
                ],

                Text(
                  'Area Stroke Profile',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),

                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: SwitchListTile(
                    title: const Text('Show Vertex Numbers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Display 0...N on canvas', style: TextStyle(fontSize: 11)),
                    value: widget.engine.showNodeIndices,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    dense: true,
                    onChanged: (val) {
                      widget.engine.toggleNodeIndices(val);
                    },
                  ),
                ),
                const SizedBox(height: 16),

                Text(
                  'Uniform Width',
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _uniformController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(), 
                          labelText: 'Width (px)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () {
                        final w = double.tryParse(_uniformController.text);
                        if (w != null && w >= 0) widget.engine.applyUniformWidth(selectedShape, w);
                      },
                      child: const Text('Apply'),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                Text(
                  'Taper Width',
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _startTaperController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(), 
                          labelText: 'Start (0)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward, color: Colors.grey, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _endTaperController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(), 
                          labelText: 'End (N)',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: () {
                      final startW = double.tryParse(_startTaperController.text);
                      final endW = double.tryParse(_endTaperController.text);
                      if (startW != null && endW != null && startW >= 0 && endW >= 0) {
                        widget.engine.applyTaperToSpline(selectedShape, startW, endW);
                      }
                    },
                    child: const Text('Apply Taper'),
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // --- GRADIENT MESH SWATCHES ---
              if (selectedShape is CompassMesh) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 24),
                
                Text(
                  'Mesh Swatches',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Colors currently used in this mesh. Select node(s) on the canvas, then click a swatch to apply.',
                  style: TextStyle(fontSize: 12, color: theme.textTheme.bodySmall?.color?.withOpacity(0.8)),
                ),
                const SizedBox(height: 16),
                
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    ...selectedShape.colors.toSet().map((color) {
                      return Tooltip(
                        message: 'Apply to selected nodes',
                        child: _buildColorSwatch(
                          color: color, 
                          isSelected: false, 
                          theme: theme,
                          onTap: () {
                            if (widget.engine.selectedPoints.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Select at least one mesh node to apply a color.')),
                              );
                              return;
                            }
                            widget.engine.setMeshSelectedColors(selectedShape, widget.engine.selectedPoints, color);
                          },
                        ),
                      );
                    }),
                    
                    _buildCustomSwatch(
                      context: context,
                      currentColor: Colors.transparent,
                      isSelected: false,
                      theme: theme,
                      onPicked: (c) {
                        if (widget.engine.selectedPoints.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Select at least one mesh node to apply a color.')),
                          );
                          return;
                        }
                        widget.engine.setMeshSelectedColors(selectedShape, widget.engine.selectedPoints, c);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildColorSwatch({
    required Color color, 
    required bool isSelected, 
    required ThemeData theme, 
    required VoidCallback onTap,
    bool isNone = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: isNone ? theme.scaffoldBackgroundColor : color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : theme.dividerColor,
            width: isSelected ? 3 : 1,
          ),
          boxShadow: isSelected ? [
            BoxShadow(
              color: theme.colorScheme.primary.withOpacity(0.4),
              blurRadius: 6,
              spreadRadius: 1,
            )
          ] : null,
        ),
        child: isNone 
          ? const Center(child: Icon(Icons.format_color_reset, size: 16, color: Colors.grey))
          : null,
      ),
    );
  }

  Widget _buildCustomSwatch({
    required BuildContext context,
    required Color currentColor,
    required bool isSelected,
    required ThemeData theme,
    required void Function(Color) onPicked,
  }) {
    final Color bg = isSelected ? currentColor : theme.scaffoldBackgroundColor;
    final Color iconColor = isSelected
        ? (currentColor.computeLuminance() > 0.5 ? Colors.black87 : Colors.white)
        : theme.colorScheme.primary;

    return Tooltip(
      message: 'Custom color…',
      child: GestureDetector(
        onTap: () async {
          final initial =
              currentColor == Colors.transparent ? Colors.black : currentColor;
          final picked =
              await showCompassColorPicker(context, initialColor: initial);
          if (picked != null) onPicked(picked);
        },
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? theme.colorScheme.primary : theme.dividerColor,
              width: isSelected ? 3 : 1,
            ),
            boxShadow: isSelected ? [
              BoxShadow(
                color: theme.colorScheme.primary.withOpacity(0.4),
                blurRadius: 6,
                spreadRadius: 1,
              )
            ] : null,
          ),
          child: Center(
            child: Icon(Icons.colorize, size: 16, color: iconColor),
          ),
        ),
      ),
    );
  }
}