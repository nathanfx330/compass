// lib/hierarchy_ops.dart

import 'engine.dart';
import 'models/layer.dart';
import 'models/geometry/shape.dart';

/// Z-order / containment mutations for the layer + shape hierarchy: reorder
/// layers in the z-stack, reorder shapes within a layer, and move a shape from
/// one layer into another. Delegated out of CompassEngine exactly as
/// ShapeConverter is -- static methods taking the engine first, each ending in
/// engine.saveSnapshot() + engine.notifyListeners() so every move is one undo
/// step and repaints live.
///
/// INDEX CONTRACT (the one thing every caller must get right):
///   Every `to` / `insertIndex` parameter is the FINAL index the moved item
///   should occupy in its destination list. The in-list ops are literally
///   `list.insert(to, list.removeAt(from))`, which lands the item at index `to`
///   in the resulting list for ALL from/to: if to <= from nothing ahead of it
///   shifted, and if to > from the removal already pulled the tail down by one,
///   so inserting at `to` in the shortened list is still final index `to`. These
///   are MODEL indices into engine.layers / layer.shapes -- NOT the panel's
///   reversed visual indices. The panel converts visual<->model and applies any
///   ReorderableListView newIndex adjustment BEFORE calling in; the conversion
///   recipe lives on reorderLayer below.
///
/// WHY A CROSS-LAYER MOVE NEEDS NO POINT/CONSTRAINT SURGERY:
///   Points live in the global engine.points pool, constraints hold their hosts
///   by object reference, and fill/stroke COLOR is a layer property while a
///   shape's own per-region stroke colors live on the shape. So relocating a
///   shape is purely splicing one object between two `shapes` lists: it keeps its
///   points, keeps its constraints, keeps its stroke-band colors, and simply
///   re-renders in the destination layer's fill/stroke. No GC, no rebind, no
///   anchor fixup -- the decoupling the engine already enforces is what makes
///   this a one-line splice instead of a migration.
class HierarchyOps {
  // ---------------------------------------------------------------------------
  // LAYER Z-ORDER
  // ---------------------------------------------------------------------------

  /// Moves the layer at model index [from] so it ends up at model index [to] in
  /// engine.layers. Bottom of the list = bottom of the z-stack, so this restacks
  /// which layer paints over which.
  ///
  /// activeLayer and the selected shape are object references, so they ride a
  /// reorder through untouched -- no index fixup here.
  ///
  /// PANEL CONVERSION (layers are displayed reversed, top-of-stack first):
  ///   onReorder: (oldIndex, newIndex) {
  ///     if (newIndex > oldIndex) newIndex -= 1;          // ReorderableListView
  ///     final L = engine.layers.length;
  ///     engine.reorderLayer((L - 1) - oldIndex, (L - 1) - newIndex); // vis->model
  ///   }
  static void reorderLayer(CompassEngine engine, int from, int to) {
    final layers = engine.layers;
    if (from < 0 || from >= layers.length) return;
    if (to < 0 || to >= layers.length) return;
    if (from == to) return;

    final layer = layers.removeAt(from);
    layers.insert(to, layer);

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // SHAPE ORDER WITHIN A LAYER
  // ---------------------------------------------------------------------------

  /// Moves the shape at index [from] within [layer].shapes to final index [to].
  ///
  /// This reorders the BOOLEAN WALK, not merely paint order: getLayerFillPath /
  /// getLayerPath / getLayerStrokeAreaPath / getLayerMeshClipPath all consume
  /// layer.shapes in order, so lifting a subtract above an add changes the
  /// RESOLVED geometry, not just what sits on top. That is the intended power of
  /// dragging shapes in the hierarchy. Selection survives (object reference);
  /// activeLayer is untouched.
  static void reorderShape(
      CompassEngine engine, CompassLayer layer, int from, int to) {
    if (!engine.layers.contains(layer)) return;
    final shapes = layer.shapes;
    if (from < 0 || from >= shapes.length) return;
    if (to < 0 || to >= shapes.length) return;
    if (from == to) return;

    final shape = shapes.removeAt(from);
    shapes.insert(to, shape);

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // CROSS-LAYER MOVE
  // ---------------------------------------------------------------------------

  /// Moves [shape] out of [fromLayer] and into [toLayer] at final index
  /// [insertIndex] (clamped to toLayer's bounds). See the class header for why
  /// this needs no point/constraint/anchor surgery.
  ///
  /// If [fromLayer] == [toLayer] this is really an in-layer reorder, so it
  /// delegates to [reorderShape] passing [insertIndex] as the final index -- the
  /// SAME meaning the parameter carries on the cross-layer path, so a caller
  /// hands over a desired final index either way and never has to reason about
  /// pre- vs post-removal coordinates.
  ///
  /// SELECTION: re-anchored only when [shape] was the selected shape. In that
  /// case we route through engine.selectShape AFTER the move, which finds the
  /// shape in its new home, makes [toLayer] the active layer, expands it,
  /// reselects, and notifies -- keeping the active layer coherent with the
  /// selection. If the shape was not selected, selection/active-layer are left
  /// alone. (engine.selectShape no-ops its selection update when the target layer
  /// is locked, so the PANEL -- not this primitive -- is responsible for not
  /// offering locked layers as drop targets; on an unlocked toLayer its notify
  /// always fires, which is the path the panel guarantees.)
  static void moveShapeToLayer(
    CompassEngine engine,
    CompassShape shape,
    CompassLayer fromLayer,
    CompassLayer toLayer,
    int insertIndex,
  ) {
    if (!engine.layers.contains(fromLayer)) return;
    if (!engine.layers.contains(toLayer)) return;

    if (fromLayer == toLayer) {
      final from = fromLayer.shapes.indexOf(shape);
      if (from == -1) return;
      reorderShape(engine, fromLayer, from, insertIndex);
      return;
    }

    final from = fromLayer.shapes.indexOf(shape);
    if (from == -1) return;

    final wasSelected = engine.selectedShape == shape;

    fromLayer.shapes.removeAt(from);

    // Manual clamp (matching the int-clamp idiom used elsewhere, e.g. the mesh
    // subdivision guard) -- avoids num/int return-type friction from .clamp().
    int clamped = insertIndex;
    if (clamped < 0) clamped = 0;
    if (clamped > toLayer.shapes.length) clamped = toLayer.shapes.length;
    toLayer.shapes.insert(clamped, shape);

    engine.saveSnapshot();

    if (wasSelected) {
      // Re-anchors active layer to toLayer, expands it, reselects, notifies.
      engine.selectShape(shape);
    } else {
      engine.notifyListeners();
    }
  }
}