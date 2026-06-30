// lib/ui/panels/layer_tile.dart

import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/layer.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/mesh.dart';
import '../workspace/dialogs.dart';
import 'shape_row.dart';

/// One whole layer card: the header (visibility / color / name / lock / delete,
/// plus a reorder grip and the right-click bake/export menu) followed by its
/// expandable shape list. Lifted out of layers_panel.dart so the panel can hand
/// each layer to a ReorderableListView as a single item -- dragging the grip
/// moves the ENTIRE card (shapes and all) in the z-stack.
///
/// Stateless: the layer's expanded flag lives on the engine (layer.isExpanded),
/// each ShapeRow owns its own stroke-expand state, and drop-hover highlight is
/// DragTarget candidate state -- so there is nothing local to hold. The panel
/// wraps the list in a ListenableBuilder(engine), so this rebuilds on notify.
///
/// REORDER GRIP: a dedicated drag handle (ReorderableDragStartListener) carrying
/// [dragIndex] -- the item's VISUAL index in the panel's reversed list, which is
/// exactly what ReorderableListView's onReorder hands back. The panel converts
/// visual->model (see hierarchy_ops.dart's recipe); this widget only forwards the
/// index. Using an explicit grip (with buildDefaultDragHandles:false on the outer
/// list) is what keeps the layer-reorder gesture from colliding with the per-shape
/// LongPressDraggable inside ShapeRow -- different trigger widgets, no arena fight.
/// Locked layers are still grip-draggable on purpose: locking freezes a layer's
/// GEOMETRY/contents, not its z-position, and a restack edits neither.
///
/// SHAPE DROP TARGETS (three, because shape rows leave gaps):
///   1. Each ShapeRow inserts a drop ABOVE itself -- covers every slot except the
///      very back (model index 0) and can't reveal a collapsed layer.
///   2. The HEADER is a catch-all target: drop -> send to back (index 0) and
///      auto-expand if collapsed. This is the ONLY way to drop into a collapsed
///      layer, and the coarse "just put it in this layer" gesture.
///   3. A TRAILING zone under the last row (expanded layers) covers model index 0
///      precisely -- the back of the stack, which no ShapeRow can reach.
///   All three refuse a locked destination; the engine no-ops a same-layer move
///   that wouldn't change anything.
class LayerTile extends StatelessWidget {
  final CompassEngine engine;
  final CompassLayer layer;
  final int dragIndex;

  const LayerTile({
    super.key,
    required this.engine,
    required this.layer,
    required this.dragIndex,
  });

  // --- Per-shape derivations (lifted from LayersPanel) ---

  // Whether a shape type currently implements getStrokeOutlinePath -- i.e. its
  // outline can feed the boolean walk as a stroke region. Only such shapes get the
  // stroke-stack UI. Extend as line/rect/spiral/xspline overrides land. (Mirrors
  // the same helper in the canvas context menus.)
  static bool _supportsStrokeRegion(CompassShape shape) {
    return shape is CompassCircle;
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

  // Detect whether a shape's points are tied to anything else (parent or child),
  // which lights up the little link badge in the row.
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
    } else if (shape is CompassMesh) {
      shapePts.addAll(shape.nodes.map((n) => n.point));
      if (shape.anchorPoint != null) shapePts.add(shape.anchorPoint!);
    }

    for (var p in shapePts) {
      if (p.attachedPoints.isNotEmpty) return true;
      for (var other in engine.points) {
        if (other != p && other.attachedPoints.contains(p)) return true;
      }
    }
    return false;
  }

  // --- Drop handlers ---

  // Header drop (catch-all): reveal the layer if collapsed, then send the shape to
  // the BACK of this layer (model index 0 = visual bottom). toggleLayerExpanded
  // does NOT snapshot (it's incidental UI state), so the single undo step comes
  // from the move. moveShapeToLayer folds a same-layer move into a reorder and
  // no-ops if nothing actually changes.
  void _handleHeaderDrop(CompassShape dragged, CompassLayer fromLayer) {
    if (layer.isLocked) return;
    if (!layer.isExpanded) engine.toggleLayerExpanded(layer);
    engine.moveShapeToLayer(dragged, fromLayer, layer, 0);
  }

  // Trailing-zone drop: send to the back of this layer (model index 0). Same
  // destination as the header, but this zone sits physically below the last shape
  // row, so it reads as an insertion line at the bottom of the visual stack --
  // matching ShapeRow's "line above each row" language.
  void _handleBackDrop(CompassShape dragged, CompassLayer fromLayer) {
    if (layer.isLocked) return;
    engine.moveShapeToLayer(dragged, fromLayer, layer, 0);
  }

  // --- Right-click layer menu (faithful from LayersPanel) ---

  Future<void> _showLayerMenu(BuildContext context, Offset globalPos) async {
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy),
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
      // Guard the silent no-op: check BOTH the standard fill and the area stroke
      // path to ensure geometry exists.
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
      // No pre-guard here: the OBJ exporter reads getLayerFillPath, which differs
      // from the bake guard's path for closed width-splines. Let showExportOBJ
      // surface the empty case via toOBJ's empty-string return -- the exporter
      // stays the single source of truth for "is there fillable area."
      if (context.mounted) {
        CompassDialogs.showExportOBJ(context, engine, layer);
      }
    }
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActiveLayer = layer == engine.activeLayer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // --- HEADER (catch-all shape drop target + reorder grip + controls) ---
        DragTarget<ShapeDragData>(
          onWillAcceptWithDetails: (d) => !layer.isLocked,
          onAcceptWithDetails: (d) => _handleHeaderDrop(d.data.shape, d.data.sourceLayer),
          builder: (context, candidate, rejected) {
            final bool targeted = candidate.isNotEmpty;
            return Material(
              color: targeted
                  ? theme.colorScheme.primary.withOpacity(0.14)
                  : (isActiveLayer
                      ? theme.colorScheme.primary.withOpacity(0.08)
                      : Colors.transparent),
              child: Row(
                children: [
                  // Reorder grip -- the ONLY trigger for layer z-reordering, so it
                  // never fights ShapeRow's long-press drag.
                  MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: ReorderableDragStartListener(
                      index: dragIndex,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8.0, right: 6.0),
                        child: Container(
                          width: 3,
                          height: 14,
                          decoration: BoxDecoration(
                            color: theme.iconTheme.color?.withOpacity(0.25),
                            borderRadius: BorderRadius.circular(1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: () {
                        if (isActiveLayer) {
                          engine.toggleLayerExpanded(layer);
                        } else {
                          engine.selectLayer(layer);
                        }
                      },
                      onSecondaryTapDown: (details) =>
                          _showLayerMenu(context, details.globalPosition),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                        child: Row(
                          children: [
                            Icon(
                              layer.isExpanded
                                  ? Icons.keyboard_arrow_down
                                  : Icons.keyboard_arrow_right,
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
                                color: layer.isVisible
                                    ? theme.iconTheme.color
                                    : theme.disabledColor,
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
                                color: layer.color == Colors.transparent
                                    ? theme.scaffoldBackgroundColor
                                    : layer.color,
                                shape: BoxShape.circle,
                                border: Border.all(color: theme.dividerColor),
                              ),
                              child: layer.color == Colors.transparent
                                  ? const Center(
                                      child: Icon(Icons.close, size: 8, color: Colors.grey))
                                  : null,
                            ),
                            Expanded(
                              child: Text(
                                layer.name,
                                style: TextStyle(
                                  fontWeight:
                                      isActiveLayer ? FontWeight.bold : FontWeight.w500,
                                  color: isActiveLayer
                                      ? theme.colorScheme.primary
                                      : (layer.isLocked ? theme.disabledColor : null),
                                ),
                              ),
                            ),
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
                ],
              ),
            );
          },
        ),

        // --- SHAPES + trailing back-drop zone (only when expanded) ---
        // Collapsed layers render no body, so the header catch-all is the route to
        // drop a shape into a collapsed layer (it expands on drop).
        if (layer.isExpanded) ...[
          ...layer.shapes.reversed.map((shape) {
            return ShapeRow(
              // Key by shape identity so each ShapeRow's stroke-expand state follows
              // its shape across a reorder rather than staying with the slot.
              key: ValueKey(shape),
              engine: engine,
              layer: layer,
              shape: shape,
              isLinked: _isShapeLinked(shape),
              opColor: _getOpColor(shape.operation),
              supportsStroke: _supportsStrokeRegion(shape),
            );
          }),
          _buildBackDropZone(theme),
        ],

        const Divider(height: 1),
      ],
    );
  }

  // The bottom drop zone. Empty layer: a generous hinted target (the whole body).
  // Non-empty: a slim "send to back" strip below the last shape row, covering
  // model index 0 -- the one slot no ShapeRow can reach. Locked layers render an
  // inert placeholder (empty) or nothing (non-empty), accepting no drops.
  Widget _buildBackDropZone(ThemeData theme) {
    final bool isEmpty = layer.shapes.isEmpty;

    if (layer.isLocked) {
      if (isEmpty) {
        return Padding(
          padding: const EdgeInsets.only(left: 32, right: 16, top: 6, bottom: 8),
          child: Text(
            'Layer locked',
            style: TextStyle(
              fontSize: 11,
              color: theme.disabledColor,
              fontStyle: FontStyle.italic,
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    return DragTarget<ShapeDragData>(
      onWillAcceptWithDetails: (d) {
        // Refuse the pure no-op: a same-layer drag whose shape already sits at the
        // back (model index 0), so the strip doesn't highlight when it'd do nothing.
        if (identical(d.data.sourceLayer, layer) &&
            layer.shapes.isNotEmpty &&
            identical(layer.shapes.first, d.data.shape)) {
          return false;
        }
        return true;
      },
      onAcceptWithDetails: (d) => _handleBackDrop(d.data.shape, d.data.sourceLayer),
      builder: (context, candidate, rejected) {
        final bool targeted = candidate.isNotEmpty;

        if (isEmpty) {
          return Container(
            margin: const EdgeInsets.fromLTRB(32, 4, 16, 8),
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: targeted ? theme.colorScheme.primary.withOpacity(0.08) : Colors.transparent,
            ),
            child: Text(
              targeted ? 'Release to add to this layer' : 'Empty layer',
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: targeted
                    ? theme.colorScheme.primary
                    : theme.textTheme.bodySmall?.color?.withOpacity(0.5),
              ),
            ),
          );
        }

        // Non-empty: slim back-of-stack strip. The top border lands directly below
        // the last visual shape row, reading as "insert at the bottom (back)."
        return Container(
          margin: const EdgeInsets.only(left: 32, right: 16, top: 2, bottom: 6),
          height: targeted ? 18 : 12,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: targeted ? theme.colorScheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: targeted
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4, top: 2),
                    child: Text(
                      'Send to back',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                )
              : null,
        );
      },
    );
  }
}