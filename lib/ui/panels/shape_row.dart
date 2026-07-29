// lib/ui/panels/shape_row.dart

import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/layer.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/mesh.dart';
import '../../models/geometry/image.dart';
import '../widgets/compass_color_picker.dart';

/// The drag payload for a shape row: the shape being dragged plus the layer it
/// currently lives in. The source layer is carried so a drop target can tell a
/// same-layer reorder from a cross-layer move WITHOUT scanning every layer to
/// find where the shape came from -- the move primitive needs both the from- and
/// to-layer, and the from-layer is only known here at the drag source.
///
/// Defined here (the drag origin) and imported by layer_tile.dart, whose
/// empty-layer body is the other DragTarget that consumes this payload.
class ShapeDragData {
  final CompassShape shape;
  final CompassLayer sourceLayer;
  const ShapeDragData(this.shape, this.sourceLayer);
}

/// One shape's row in the hierarchy, draggable to reorder within its layer or to
/// move into another layer, plus its expandable OUTWARD-STACKED stroke stack.
/// Lifted out of layers_panel.dart and made public so layer_tile.dart can compose
/// it. Stateful only to hold the local expand toggle for the stroke sub-list (the
/// shape data itself lives in the engine).
///
/// DRAG/DROP:
///   * Drag is IMMEDIATE (plain Draggable, not LongPressDraggable) and triggered
///     ONLY by the grip handle at the left of the row -- mirroring the layer card's
///     ReorderableDragStartListener grip, so shapes and layers feel identical to
///     pick up on a desktop mouse (grab + pull, no hold). Wrapping only the grip
///     (not the whole row) keeps the drag out of the gesture arena with the row's
///     tap-to-select and its trailing buttons, so they never contend. The grip is
///     omitted on a locked layer, so its rows aren't draggable.
///   * The whole row is a DragTarget<ShapeDragData>. A drop lands the dragged
///     shape directly ABOVE this row visually (see the index math in the accept
///     handler). Self-drops and drops onto a locked layer are refused.
///
/// Stroke model in the UI: stroke 1 is the INNERMOST ring (on the shape outline),
/// each later stroke rides OUTWARD on the previous one. A stroke is BINARY -- it
/// FILLS (paints a ring, can carry its own color) or CUTS (carves the geometry
/// beneath, paints nothing). No intersect. Each row carries: a Cut/Fill toggle
/// (engine.setStrokeRegionOp with add/subtract), up/down arrows to restack inward/
/// outward (engine.moveStrokeRegion), a color chip on Fill rings
/// (engine.setStrokeRegionColor), and a delete (engine.removeStrokeRegion). The "+"
/// appends a new OUTERMOST ring (engine.addStrokeRegion, defaulting to Fill).
/// Per-ring WIDTH is the Properties-panel slider, not here.
class ShapeRow extends StatefulWidget {
  final CompassEngine engine;
  final CompassLayer layer;
  final CompassShape shape;
  final bool isLinked;
  final Color opColor;
  final bool supportsStroke;

  const ShapeRow({
    super.key,
    required this.engine,
    required this.layer,
    required this.shape,
    required this.isLinked,
    required this.opColor,
    required this.supportsStroke,
  });

  @override
  State<ShapeRow> createState() => _ShapeRowState();
}

class _ShapeRowState extends State<ShapeRow> {
  bool _strokesExpanded = false;

  // The per-FILL-ring color chip. Shown only when the ring is a Fill (a Cut paints
  // nothing, so a color there is meaningless). A null color means "inherit the layer
  // fill color": the chip then shows a neutral swatch with a tiny eyedropper. A set
  // color fills the chip. Tap opens the opaque HSV picker; long-press clears back to
  // inherit. (The chip lives in the stroke sub-list, which is entirely outside the
  // grip's Draggable, so this long-press contends with nothing.)
  Widget _buildStrokeColorChip(CompassShape shape, int index, StrokeRegion region, ThemeData theme) {
    final Color? c = region.color;
    final bool hasColor = c != null;

    return Tooltip(
      message: hasColor ? 'Ring color (long-press to clear)' : 'Set ring color',
      child: GestureDetector(
        onTap: () async {
          final initial = c ?? Colors.black;
          final picked = await showCompassColorPicker(context, initialColor: initial);
          if (picked != null) {
            widget.engine.setStrokeRegionColor(shape, index, picked);
          }
        },
        onLongPress: () {
          widget.engine.setStrokeRegionColor(shape, index, null);
        },
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: hasColor ? c : theme.scaffoldBackgroundColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: hasColor ? theme.dividerColor : Colors.orangeAccent.withOpacity(0.6),
              width: 1,
            ),
          ),
          child: hasColor
              ? null
              : Icon(
                  Icons.colorize,
                  size: 11,
                  color: theme.colorScheme.primary.withOpacity(0.8),
                ),
        ),
      ),
    );
  }

  // The floating pill shown under the cursor while dragging -- a compact echo of
  // the row (icon + name). Needs its own Material since Draggable feedback mounts
  // in an Overlay with no Material ancestor.
  Widget _dragFeedback(ThemeData theme, String shapeName, IconData shapeIcon) {
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surface,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.primary.withOpacity(0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(shapeIcon, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(shapeName,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  // Resolves a drop of [dragged] (coming from [fromLayer]) onto THIS row's shape,
  // landing it directly ABOVE this row visually, then dispatches via
  // engine.moveShapeToLayer (which folds same-layer into a reorder).
  //
  // INDEX MATH -- the panel shows shapes reversed (top of the visual stack =
  // highest model index), so "above B visually" = the model slot just HIGHER than
  // B. The destination index differs same-layer vs cross-layer because of the
  // removal shift the index contract describes:
  //   * cross-layer: [dragged] isn't in this layer, so nothing shifts -> insert at
  //     bIndex + 1.
  //   * same-layer: [dragged] is removed FIRST. If it sat BELOW B (aIndex < bIndex)
  //     that removal pulls B down one, so the final slot just above B is bIndex; if
  //     it sat ABOVE B, B is unaffected and the slot is bIndex + 1.
  // moveShapeToLayer takes this as its FINAL-index insertIndex, so one call covers
  // both paths.
  void _handleDrop(CompassShape dragged, CompassLayer fromLayer) {
    final layer = widget.layer;
    final bIndex = layer.shapes.indexOf(widget.shape);
    if (bIndex == -1) return;

    final int insertIndex;
    if (identical(fromLayer, layer)) {
      final aIndex = layer.shapes.indexOf(dragged);
      if (aIndex == -1 || aIndex == bIndex) return; // gone, or self
      insertIndex = aIndex < bIndex ? bIndex : bIndex + 1;
    } else {
      insertIndex = bIndex + 1;
    }

    widget.engine.moveShapeToLayer(dragged, fromLayer, layer, insertIndex);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = widget.engine;
    final layer = widget.layer;
    final shape = widget.shape;
    final isSelectedShape = shape == engine.selectedShape;

    String shapeName = 'Unknown Shape';
    IconData shapeIcon = Icons.shape_line;

    if (shape is CompassLine) {
      shapeName = 'Line';
      shapeIcon = Icons.show_chart;
    } else if (shape is CompassCircle) {
      shapeName = 'Circle';
      shapeIcon = Icons.radio_button_unchecked;
    } else if (shape is CompassSpiral) {
      shapeName = 'Spiral';
      shapeIcon = Icons.cyclone;
    } else if (shape is CompassRectangle) {
      shapeName = 'Rectangle';
      shapeIcon = Icons.crop_square;
    } else if (shape is CompassXSpline) {
      shapeName = 'X-Spline';
      shapeIcon = Icons.draw;
    } else if (shape is CompassMesh) {
      shapeName = 'Gradient Mesh';
      shapeIcon = Icons.grid_on;
    } else if (shape is CompassImage) {
      shapeName = 'IMG · ${shape.displayName}';
      shapeIcon = Icons.image_outlined;
    }

    final bool dim = !(shape.isVisible && !layer.isLocked);
    final int strokeCount = shape.strokeRegions.length;

    // --- Grip + shape icon, the row's leading cluster. ---
    // On an unlocked layer the grip is a Draggable<ShapeDragData> handle (immediate
    // drag, grab-and-pull) sitting just left of the shape icon -- the shape drag's
    // ONLY trigger, matching the layer card grip. On a locked layer the grip is
    // omitted entirely (a fixed-width spacer holds the icon's alignment), so locked
    // rows can't be dragged and read as inert.
    final Widget shapeIconWidget = Icon(
      shapeIcon,
      size: 16,
      color: dim ? theme.disabledColor : null,
    );

    // REPLACED Icons.drag_indicator with a minimal vertical bar
    final Widget gripHandle = MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Tooltip(
        message: 'Drag to reorder',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
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
    );

    final Widget leadingCluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!layer.isLocked)
          Draggable<ShapeDragData>(
            data: ShapeDragData(shape, layer),
            feedback: _dragFeedback(theme, shapeName, shapeIcon),
            // No childWhenDragging swap on the grip itself -- the row stays put and
            // only the floating pill moves, which reads cleaner than ghosting a
            // single icon. (The whole-row ghost from the old design isn't possible
            // now that just the grip is the draggable, and isn't worth the wiring.)
            child: gripHandle,
          )
        else
          // Keep the icon column aligned with draggable rows (grip width ~11).
          const SizedBox(width: 11),
        const SizedBox(width: 4),
        shapeIconWidget,
      ],
    );

    // --- The main shape row. ---
    final Widget mainRow = Padding(
      padding: const EdgeInsets.only(left: 32.0),
      child: ListTile(
        selected: isSelectedShape,
        selectedTileColor: theme.colorScheme.primary.withOpacity(0.15),
        selectedColor: theme.colorScheme.primary,
        leading: leadingCluster,
        title: Row(
          children: [
            Text(
              shapeName,
              style: TextStyle(
                fontSize: 13,
                color: dim ? theme.disabledColor : null,
              ),
            ),
            if (widget.isLinked) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: 'Shape shares mathematical constraints',
                child: Icon(Icons.link, size: 12, color: theme.colorScheme.primary.withOpacity(0.7)),
              ),
            ],
            // A small count badge when the shape carries stroke regions, so the
            // stack is discoverable without expanding.
            if (widget.supportsStroke && strokeCount > 0) ...[
              const SizedBox(width: 6),
              Tooltip(
                message: '$strokeCount stroke ring${strokeCount == 1 ? '' : 's'}',
                child: Icon(Icons.donut_large, size: 12, color: Colors.orangeAccent.withOpacity(0.9)),
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
                : (dim ? theme.disabledColor : widget.opColor),
            fontWeight: FontWeight.bold,
          ),
        ),
        trailing: layer.isLocked
            ? const SizedBox.shrink()
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // --- "+ Add Stroke" : appends a ring as the new OUTERMOST one.
                  // Shown only for stroke-capable shapes. Auto-expands the stack
                  // so the new row (and the Properties-panel slider) are visible.
                  if (widget.supportsStroke)
                    IconButton(
                      iconSize: 16,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: const Icon(Icons.add_circle_outline, color: Colors.orangeAccent),
                      tooltip: 'Add Stroke Ring',
                      onPressed: () {
                        engine.addStrokeRegion(shape);
                        setState(() => _strokesExpanded = true);
                      },
                    ),
                  if (widget.supportsStroke) const SizedBox(width: 4),

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
                  // Quick Operation Toggle (FILL op of the shape itself)
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
          engine.selectShape(shape);
        },
      ),
    );

    return DragTarget<ShapeDragData>(
      onWillAcceptWithDetails: (details) {
        if (layer.isLocked) return false; // never drop into a locked layer
        if (details.data.shape == shape) return false; // self-drop is a no-op
        return true;
      },
      onAcceptWithDetails: (details) {
        _handleDrop(details.data.shape, details.data.sourceLayer);
      },
      builder: (context, candidate, rejected) {
        final bool isTargeted = candidate.isNotEmpty;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Insertion indicator: a thin accent line ABOVE the row (drop lands
            // above). Always present at height 2 -- only its color toggles -- so
            // hovering causes no layout jump. Inset to align with the row body.
            Padding(
              padding: const EdgeInsets.only(left: 32.0),
              child: Container(
                height: 2,
                color: isTargeted ? theme.colorScheme.primary : Colors.transparent,
              ),
            ),

            mainRow,

            // --- STROKE STACK (inner -> outer; each ring Cut or Fill, restackable) ---
            // Only for stroke-capable, unlocked shapes that actually have rings.
            // Entirely outside the grip's Draggable, so the color chip's long-press
            // contends with nothing. Ring 1 (top of the list) is the INNERMOST,
            // sitting on the shape outline; later rings ride outward. Each row: a
            // Cut/Fill toggle, up/down to restack, a color chip on Fill rings, a delete.
            if (widget.supportsStroke && !layer.isLocked && strokeCount > 0) ...[
              Padding(
                padding: const EdgeInsets.only(left: 56.0, right: 16.0),
                child: InkWell(
                  onTap: () => setState(() => _strokesExpanded = !_strokesExpanded),
                  child: Row(
                    children: [
                      Icon(
                        _strokesExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                        size: 16,
                        color: theme.iconTheme.color?.withOpacity(0.6),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.donut_large, size: 13, color: Colors.orangeAccent.withOpacity(0.9)),
                      const SizedBox(width: 6),
                      Text(
                        'Stroke Rings ($strokeCount)  ·  inner → outer',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: theme.textTheme.bodySmall?.color?.withOpacity(0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_strokesExpanded)
                ...List.generate(strokeCount, (i) {
                  final region = shape.strokeRegions[i];
                  final bool isFill = region.op == CompassBooleanOp.add; // add = FILL, subtract = CUT
                  final bool isInnermost = i == 0;
                  final bool isOutermost = i == strokeCount - 1;
                  return Padding(
                    padding: const EdgeInsets.only(left: 72.0, right: 16.0, top: 2.0, bottom: 2.0),
                    child: Row(
                      children: [
                        // Ring number + position hint (innermost first).
                        SizedBox(
                          width: 46,
                          child: Text(
                            isInnermost
                                ? '${i + 1} · in'
                                : (isOutermost ? '${i + 1} · out' : '${i + 1}'),
                            style: TextStyle(
                              fontSize: 11,
                              color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
                            ),
                          ),
                        ),
                        // --- Cut / Fill binary toggle. Tap flips between the two.
                        GestureDetector(
                          onTap: () => engine.setStrokeRegionOp(
                            shape,
                            i,
                            isFill ? CompassBooleanOp.subtract : CompassBooleanOp.add,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: (isFill ? Colors.green : Colors.redAccent).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: (isFill ? Colors.green : Colors.redAccent).withOpacity(0.7),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              isFill ? 'FILL' : 'CUT',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isFill ? Colors.green : Colors.redAccent,
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        // Color chip -- only meaningful for a FILL ring (a CUT paints nothing).
                        if (isFill) ...[
                          _buildStrokeColorChip(shape, i, region, theme),
                          const SizedBox(width: 6),
                        ],
                        // Restack inward (toward the outline / index 0).
                        IconButton(
                          iconSize: 15,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 22),
                          icon: Icon(
                            Icons.keyboard_arrow_up,
                            color: isInnermost ? theme.disabledColor : theme.iconTheme.color?.withOpacity(0.8),
                          ),
                          tooltip: 'Move inward',
                          onPressed: isInnermost ? null : () => engine.moveStrokeRegion(shape, i, -1),
                        ),
                        // Restack outward (away from the outline).
                        IconButton(
                          iconSize: 15,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 22),
                          icon: Icon(
                            Icons.keyboard_arrow_down,
                            color: isOutermost ? theme.disabledColor : theme.iconTheme.color?.withOpacity(0.8),
                          ),
                          tooltip: 'Move outward',
                          onPressed: isOutermost ? null : () => engine.moveStrokeRegion(shape, i, 1),
                        ),
                        const SizedBox(width: 2),
                        // Remove this ring.
                        IconButton(
                          iconSize: 14,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                          tooltip: 'Remove Ring',
                          onPressed: () => engine.removeStrokeRegion(shape, i),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ],
        );
      },
    );
  }
}