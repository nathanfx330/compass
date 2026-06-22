// /lib/ui/panels/layers_panel.dart

import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/spline.dart';
import '../workspace/dialogs.dart';

class LayersPanel extends StatelessWidget {
  final CompassEngine engine;
  final VoidCallback onLoadReferenceImage;

  const LayersPanel({
    super.key,
    required this.engine,
    required this.onLoadReferenceImage,
  });

  // --- NEW: Helper method to detect if a shape's points are tied to anything else
  bool _isShapeLinked(CompassShape shape) {
    List<CompassPoint> shapePts = [];
    if (shape is CompassLine) {
      shapePts = [shape.start, shape.end];
    } else if (shape is CompassCircle) {
      shapePts = [shape.center, if (shape.radiusPoint != null) shape.radiusPoint!];
    } else if (shape is CompassSpiral) {
      shapePts = [shape.center, shape.startPoint];
    } else if (shape is CompassRectangle) {
      shapePts = [shape.p1, shape.p2];
    } else if (shape is CompassXSpline) {
      shapePts.addAll(shape.nodes.map((n) => n.point));
      if (shape.anchorPoint != null) shapePts.add(shape.anchorPoint!);
    }

    for (var p in shapePts) {
      // Is this point acting as a parent to something else?
      if (p.attachedPoints.isNotEmpty) return true;
      // Is this point a child of something else in the global engine?
      for (var other in engine.points) {
        if (other != p && other.attachedPoints.contains(p)) return true;
      }
    }
    return false;
  }

  Color _getOpColor(CompassBooleanOp op) {
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Hierarchy',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_box_outlined),
                tooltip: 'New Layer',
                onPressed: () {
                  engine.addLayer('Layer ${engine.layers.length + 1}');
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        
        // MATHEMATICAL LAYERS
        Expanded(
          child: ListenableBuilder(
            listenable: engine,
            builder: (context, _) {
              if (engine.layers.isEmpty) {
                return const Center(
                  child: Text(
                    'No layers yet.',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }

              return ListView.builder(
                itemCount: engine.layers.length,
                itemBuilder: (context, index) {
                  final layerIndex = engine.layers.length - 1 - index;
                  final layer = engine.layers[layerIndex];
                  final isActiveLayer = layer == engine.activeLayer;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // --- LAYER HEADER ---
                      Material(
                        color: isActiveLayer 
                            ? theme.colorScheme.primary.withOpacity(0.08)
                            : Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            if (isActiveLayer) {
                              engine.toggleLayerExpanded(layer);
                            } else {
                              engine.selectLayer(layer);
                            }
                          },
                          // --- Right-click a layer for layer-level actions:
                          //   * Bake to X-Spline -- flatten the boolean result into
                          //     editable splines on a fresh layer above (in-app).
                          //   * Export to OBJ -- write the resolved fill as a flat
                          //     triangle mesh to disk (off-app, for Blender/Godot).
                          // ---
                          onSecondaryTapDown: (details) async {
                            final selected = await showMenu<String>(
                              context: context,
                              position: RelativeRect.fromLTRB(
                                details.globalPosition.dx,
                                details.globalPosition.dy,
                                details.globalPosition.dx,
                                details.globalPosition.dy,
                              ),
                              items: const [
                                PopupMenuItem<String>(
                                  value: 'bake',
                                  child: Row(
                                    children: [
                                      Icon(Icons.draw, size: 18),
                                      SizedBox(width: 12),
                                      Text('Bake to X-Spline'),
                                    ],
                                  ),
                                ),
                                PopupMenuDivider(),
                                PopupMenuItem<String>(
                                  value: 'export_obj',
                                  child: Row(
                                    children: [
                                      Icon(Icons.view_in_ar, size: 18),
                                      SizedBox(width: 12),
                                      Text('Export to OBJ…'),
                                    ],
                                  ),
                                ),
                              ],
                            );

                            if (selected == 'bake') {
                              // Guard the silent no-op: check BOTH the standard fill 
                              // and the area stroke path to ensure geometry exists.
                              final fillEmpty = layer.getLayerFillPath().computeMetrics().isEmpty;
                              final areaEmpty = layer.getLayerStrokeAreaPath().computeMetrics().isEmpty;

                              if (fillEmpty && areaEmpty) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Nothing to bake — this layer has no filled area.'),
                                    ),
                                  );
                                }
                                return;
                              }

                              engine.bakeLayer(layer);
                            } else if (selected == 'export_obj') {
                              // No pre-guard here: the OBJ exporter reads the FILL
                              // path (getLayerFillPath), which differs from the bake
                              // guard's getLayerPath for closed width-splines. Rather
                              // than risk blocking a valid export with the wrong path
                              // check, we let showExportOBJ surface the empty case via
                              // toOBJ's empty-string return -- the exporter stays the
                              // single source of truth for "is there fillable area."
                              if (context.mounted) {
                                CompassDialogs.showExportOBJ(context, engine, layer);
                              }
                            }
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                            child: Row(
                              children: [
                                Icon(
                                  layer.isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                                  size: 20,
                                  color: theme.iconTheme.color?.withOpacity(0.6),
                                ),
                                const SizedBox(width: 4),
                                
                                IconButton(
                                  iconSize: 18,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: Icon(
                                    layer.isVisible ? Icons.visibility : Icons.visibility_off,
                                    color: layer.isVisible ? theme.iconTheme.color : theme.disabledColor,
                                  ),
                                  onPressed: () {
                                    layer.isVisible = !layer.isVisible;
                                    engine.selectLayer(layer); 
                                  },
                                ),
                                const SizedBox(width: 8),

                                Container(
                                  width: 12,
                                  height: 12,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: layer.color == Colors.transparent ? theme.scaffoldBackgroundColor : layer.color,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: theme.dividerColor),
                                  ),
                                  child: layer.color == Colors.transparent 
                                    ? const Center(child: Icon(Icons.close, size: 8, color: Colors.grey))
                                    : null,
                                ),
                                Expanded(
                                  child: Text(
                                    layer.name,
                                    style: TextStyle(
                                      fontWeight: isActiveLayer ? FontWeight.bold : FontWeight.w500,
                                      color: isActiveLayer ? theme.colorScheme.primary : (layer.isLocked ? theme.disabledColor : null),
                                    ),
                                  ),
                                ),
                                
                                // --- NEW: Layer Lock Button ---
                                IconButton(
                                  iconSize: 16,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: Icon(
                                    layer.isLocked ? Icons.lock : Icons.lock_open,
                                    color: layer.isLocked ? theme.disabledColor : Colors.orange,
                                  ),
                                  tooltip: layer.isLocked ? 'Unlock Layer' : 'Lock Layer',
                                  onPressed: () {
                                    engine.toggleLayerLock(layer);
                                  },
                                ),
                                const SizedBox(width: 4),

                                IconButton(
                                  iconSize: 16,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                  tooltip: 'Delete Layer',
                                  onPressed: () {
                                    engine.removeLayer(layer);
                                  },
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // --- SHAPES INSIDE THE LAYER ---
                      if (layer.isExpanded && layer.shapes.isNotEmpty)
                        ...layer.shapes.reversed.map((shape) {
                          final isSelectedShape = shape == engine.selectedShape;

                          String shapeName = 'Unknown Shape';
                          IconData shapeIcon = Icons.shape_line;

                          if (shape.runtimeType.toString() == 'CompassLine') {
                            shapeName = 'Line';
                            shapeIcon = Icons.show_chart;
                          } else if (shape.runtimeType.toString() == 'CompassCircle') {
                            shapeName = 'Circle';
                            shapeIcon = Icons.radio_button_unchecked;
                          } else if (shape.runtimeType.toString() == 'CompassSpiral') {
                            shapeName = 'Spiral';
                            shapeIcon = Icons.cyclone;
                          } else if (shape.runtimeType.toString() == 'CompassRectangle') { // <--- ADDED
                            shapeName = 'Rectangle';
                            shapeIcon = Icons.crop_square;
                          } else if (shape.runtimeType.toString() == 'CompassXSpline') {
                            shapeName = 'X-Spline';
                            shapeIcon = Icons.draw;
                          }

                          return Padding(
                            padding: const EdgeInsets.only(left: 32.0),
                            child: ListTile(
                              selected: isSelectedShape,
                              selectedTileColor: theme.colorScheme.primary.withOpacity(0.15),
                              selectedColor: theme.colorScheme.primary,
                              leading: Icon(
                                shapeIcon, 
                                size: 16,
                                color: (shape.isVisible && !layer.isLocked) ? null : theme.disabledColor,
                              ),
                              title: Row(
                                children: [
                                  Text(
                                    shapeName, 
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: (shape.isVisible && !layer.isLocked) ? null : theme.disabledColor,
                                    ),
                                  ),
                                  // --- NEW: Add the link icon if relationships exist
                                  if (_isShapeLinked(shape)) ...[
                                    const SizedBox(width: 6),
                                    Tooltip(
                                      message: 'Shape shares mathematical constraints',
                                      child: Icon(Icons.link, size: 12, color: theme.colorScheme.primary.withOpacity(0.7)),
                                    ),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                shape.operation.name.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isSelectedShape 
                                      ? theme.colorScheme.primary 
                                      : (shape.isVisible && !layer.isLocked ? _getOpColor(shape.operation) : theme.disabledColor),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              trailing: layer.isLocked ? const SizedBox.shrink() : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Visibility Toggle
                                  IconButton(
                                    iconSize: 16,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: Icon(
                                      shape.isVisible ? Icons.visibility : Icons.visibility_off,
                                      color: shape.isVisible ? theme.iconTheme.color?.withOpacity(0.7) : theme.disabledColor,
                                    ),
                                    tooltip: shape.isVisible ? 'Hide Shape' : 'Show Shape',
                                    onPressed: () {
                                      engine.toggleShapeVisibility(shape);
                                    },
                                  ),
                                  const SizedBox(width: 4),
                                  // Quick Operation Toggle
                                  PopupMenuButton<CompassBooleanOp>(
                                    initialValue: shape.operation,
                                    tooltip: 'Change Operation',
                                    child: Padding(
                                      padding: const EdgeInsets.all(4.0),
                                      child: Icon(Icons.tune, size: 16, color: theme.iconTheme.color?.withOpacity(0.7)),
                                    ),
                                    onSelected: (op) => engine.changeShapeOperation(shape, op),
                                    itemBuilder: (context) => CompassBooleanOp.values.map((op) {
                                      return PopupMenuItem(
                                        value: op,
                                        child: Text(op.name.toUpperCase(), style: const TextStyle(fontSize: 12)),
                                      );
                                    }).toList(),
                                  ),
                                  const SizedBox(width: 4),
                                  // Delete Button
                                  IconButton(
                                    iconSize: 16,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                    tooltip: 'Delete Shape',
                                    onPressed: () {
                                      engine.removeShape(shape);
                                    },
                                  ),
                                ],
                              ),
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16.0),
                              visualDensity: VisualDensity.compact,
                              onTap: () {
                                // Delegate to engine to handle locked check
                                engine.selectShape(shape);
                              },
                            ),
                          );
                        }),
                        
                      const Divider(height: 1),
                    ],
                  );
                },
              );
            },
          ),
        ),

        // --- THE REFERENCE IMAGE LAYER (PERMANENTLY PINNED TO BOTTOM) ---
        ListenableBuilder(
          listenable: engine,
          builder: (context, _) {
            final ref = engine.referenceLayer;
            
            return Container(
              color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(height: 1, thickness: 2),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Row(
                      children: [
                        const Icon(Icons.image, size: 16, color: Colors.grey),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Reference Image',
                            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
                          ),
                        ),
                        
                        if (ref == null)
                           TextButton(
                             onPressed: onLoadReferenceImage,
                             child: const Text('Load...'),
                           )
                        else ...[
                          IconButton(
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(
                              ref.isVisible ? Icons.visibility : Icons.visibility_off,
                              color: ref.isVisible ? theme.iconTheme.color : theme.disabledColor,
                            ),
                            onPressed: engine.toggleReferenceVisibility,
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(
                              ref.isLocked ? Icons.lock : Icons.lock_open,
                              color: ref.isLocked ? theme.disabledColor : Colors.orange,
                            ),
                            tooltip: ref.isLocked ? 'Unlock to move/scale' : 'Lock position',
                            onPressed: engine.toggleReferenceLock,
                          ),
                          const SizedBox(width: 12),
                          IconButton(
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            onPressed: engine.removeReferenceLayer,
                          ),
                        ]
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
        ),
      ],
    );
  }
}