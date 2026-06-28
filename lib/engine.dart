// /lib/engine.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';

// --- DATA MODELS ---
import 'models/geometry/point.dart';
import 'models/geometry/shape.dart';
import 'models/geometry/line.dart';
import 'models/geometry/circle.dart';
import 'models/geometry/spiral.dart';
import 'models/geometry/spline.dart';
import 'models/geometry/rectangle.dart';
import 'models/geometry/mesh.dart'; // <--- NEW: gradient mesh shape
import 'models/layer.dart';
import 'models/reference_layer.dart';

// --- CONSTRAINTS ---
import 'constraints.dart';

// --- IO ---
import 'io/project_serializer.dart';
import 'io/svg_exporter.dart';
import 'io/png_exporter.dart';
import 'io/obj_exporter.dart';

// --- GEOMETRY HELPERS ---
import 'path_baker.dart';
import 'shape_converter.dart'; // <--- NEW: Extracted Shape Converter

// --- HIERARCHY OPS ---
import 'hierarchy_ops.dart'; // <--- NEW: Extracted Z-order / containment mutations

/// The state holder and brain of the application.
class CompassEngine extends ChangeNotifier {
  final List<CompassPoint> points = [];
  final List<CompassLayer> layers = [];

  // Live registry of host-rider constraints: PointOnLine / PointOnCircle /
  // PointOnSpiral. Each binds a free "rider" point onto a host shape so it
  // re-projects whenever the host's defining points move. These have NO other
  // reconstruction path, so the engine must own them for serialization to persist
  // them -- and because undo() round-trips through serialize/deserialize, owning
  // them here is exactly what makes them survive Ctrl+Z too.
  //
  // Deliberately NOT tracked here: DistanceRadiusConstraint (rebuilt as the circle
  // loader's bespoke radius closure) and SquareConstraint (rebuilt from the
  // rectangle's isSquare flag). Both already survive a round-trip by other means;
  // listing them here would double-bind them.
  final List<CompassConstraint> constraints = [];

  CompassLayer? activeLayer;
  CompassShape? _selectedShape;

  CompassReferenceLayer? referenceLayer;

  // --- UNDO STACK ---
  final List<String> _undoStack = [];
  bool _isRestoring = false; 

  // --- Toggle to show vertex indices (0, 1, 2...) on the canvas ---
  bool showNodeIndices = false;

  // --- NEW: Global selection state so panels can interact with canvas selections ---
  Set<CompassPoint> selectedPoints = {};

  CompassEngine() {
    addLayer('Layer 1');
    saveSnapshot(); 
  }

  CompassShape? get selectedShape => _selectedShape;

  void toggleNodeIndices(bool show) {
    showNodeIndices = show;
    notifyListeners();
  }

  void applyUniformWidth(CompassXSpline spline, double width) {
    for (var node in spline.nodes) {
      node.widthLeft.value = width;
      node.widthRight.value = width;
      node.isLeftWidthPinned = false; // Destroy flags
      node.isRightWidthPinned = false; // Destroy flags
    }
    saveSnapshot();
    notifyListeners();
  }

  void applyTaperToSpline(CompassXSpline spline, double startWidth, double endWidth) {
    final int n = spline.nodes.length;
    if (n == 0) return;

    if (n == 1) {
      spline.nodes[0].widthLeft.value = startWidth;
      spline.nodes[0].widthRight.value = startWidth;
      spline.nodes[0].isLeftWidthPinned = false;
      spline.nodes[0].isRightWidthPinned = false;
    } else {
      for (int i = 0; i < n; i++) {
        // Calculate parametric 't' (0.0 at start, 1.0 at end)
        double t = i / (n - 1);
        double currentWidth = startWidth + (endWidth - startWidth) * t;
        
        spline.nodes[i].widthLeft.value = currentWidth;
        spline.nodes[i].widthRight.value = currentWidth;
        spline.nodes[i].isLeftWidthPinned = false; // Destroy flags
        spline.nodes[i].isRightWidthPinned = false; // Destroy flags
      }
    }
    saveSnapshot();
    notifyListeners();
  }

  // --- Width Constraint Logic ---
  void setWidthConstraint(CompassXSpline spline, CompassSplineNode node, bool isLeft, bool isPinned) {
    if (isLeft) {
      node.isLeftWidthPinned = isPinned;
    } else {
      node.isRightWidthPinned = isPinned;
    }
    _enforceWidthConstraints(spline, isLeft);
    saveSnapshot();
    notifyListeners();
  }

  void updateNodeWidth(CompassXSpline spline, CompassSplineNode node, double newWidth, bool isLeft) {
    if (isLeft) {
      node.widthLeft.value = newWidth;
    } else {
      node.widthRight.value = newWidth;
    }
    // If we are dragging a pinned node, instantly update all nodes between it and the next pin
    if ((isLeft && node.isLeftWidthPinned) || (!isLeft && node.isRightWidthPinned)) {
      _enforceWidthConstraints(spline, isLeft);
    }
    notifyListeners();
  }

  void _enforceWidthConstraints(CompassXSpline spline, bool isLeft) {
    List<int> pinnedIndices = [];
    for (int i = 0; i < spline.nodes.length; i++) {
      bool pinned = isLeft ? spline.nodes[i].isLeftWidthPinned : spline.nodes[i].isRightWidthPinned;
      if (pinned) pinnedIndices.add(i);
    }

    if (pinnedIndices.length < 2) return; // Need at least 2 flags to interpolate

    for (int p = 0; p < pinnedIndices.length - 1; p++) {
      int startIdx = pinnedIndices[p];
      int endIdx = pinnedIndices[p + 1];
      
      double startW = isLeft ? spline.nodes[startIdx].widthLeft.value : spline.nodes[startIdx].widthRight.value;
      double endW = isLeft ? spline.nodes[endIdx].widthLeft.value : spline.nodes[endIdx].widthRight.value;

      for (int i = startIdx + 1; i < endIdx; i++) {
        double t = (i - startIdx) / (endIdx - startIdx);
        double w = startW + (endW - startW) * t;
        if (isLeft) {
          spline.nodes[i].widthLeft.value = w;
        } else {
          spline.nodes[i].widthRight.value = w;
        }
      }
    }
  }

  // --- MADE PUBLIC for ShapeConverter ---
  void saveSnapshot() {
    if (_isRestoring) return;
    
    final currentData = toProjectData();
    if (_undoStack.isEmpty || _undoStack.last != currentData) {
      _undoStack.add(currentData);
      if (_undoStack.length > 50) {
        _undoStack.removeAt(0);
      }
    }
  }

  void undo() {
    if (_undoStack.length > 1) {
      _isRestoring = true; 
      _undoStack.removeLast(); 
      final previousState = _undoStack.last; 
      
      loadProjectData(previousState);
      
      _isRestoring = false;
      notifyListeners();
    }
  }

  Future<void> loadReferenceImage(String path) async {
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      
      referenceLayer = CompassReferenceLayer(imagePath: path);
      referenceLayer!.image = frameInfo.image;
      
      referenceLayer!.offset = Offset(-frameInfo.image.width / 2, -frameInfo.image.height / 2);
      
      saveSnapshot();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load reference image: $e');
    }
  }

  void removeReferenceLayer() {
    referenceLayer = null;
    saveSnapshot();
    notifyListeners();
  }

  void toggleReferenceLock() {
    if (referenceLayer != null) {
      referenceLayer!.isLocked = !referenceLayer!.isLocked;
      notifyListeners();
    }
  }

  void toggleReferenceVisibility() {
    if (referenceLayer != null) {
      referenceLayer!.isVisible = !referenceLayer!.isVisible;
      notifyListeners();
    }
  }

  void updateReferenceTransform(Offset deltaOffset, double deltaScale, double deltaRotation) {
    if (referenceLayer != null && !referenceLayer!.isLocked) {
      referenceLayer!.offset += deltaOffset;
      referenceLayer!.scale += deltaScale;
      referenceLayer!.rotation += deltaRotation;
      notifyListeners();
    }
  }

  void addLayer(String name) {
    final newLayer = CompassLayer(name: name);
    layers.add(newLayer);
    activeLayer = newLayer; 
    _selectedShape = null;
    saveSnapshot();
    notifyListeners();
  }

  void removeLayer(CompassLayer layer) {
    layers.remove(layer);
    
    if (activeLayer == layer) {
      activeLayer = layers.isNotEmpty ? layers.first : null;
    }

    if (_selectedShape != null && layer.shapes.contains(_selectedShape)) {
      _selectedShape = null;
    }

    if (layers.isEmpty) {
      final newLayer = CompassLayer(name: 'Layer 1');
      layers.add(newLayer);
      activeLayer = newLayer;
    }

    saveSnapshot();
    notifyListeners();
  }

  void selectLayer(CompassLayer layer) {
    if (!layer.isLocked) {
      activeLayer = layer;
      _selectedShape = null; 
      notifyListeners();
    }
  }
  
  void toggleLayerExpanded(CompassLayer layer) {
    layer.isExpanded = !layer.isExpanded;
    notifyListeners();
  }

  void toggleLayerLock(CompassLayer layer) {
    layer.isLocked = !layer.isLocked;
    
    if (layer.isLocked && activeLayer == layer) {
       _selectedShape = null;
       activeLayer = null;
       for (var l in layers) {
         if (!l.isLocked) {
           activeLayer = l;
           break;
         }
       }
    }
    
    if (layer.isLocked && _selectedShape != null && layer.shapes.contains(_selectedShape)) {
      _selectedShape = null;
    }
    
    saveSnapshot();
    notifyListeners();
  }

  void selectShape(CompassShape? shape) {
    if (shape != null) {
      for (var layer in layers) {
        if (layer.shapes.contains(shape)) {
          if (layer.isLocked) return; 
          
          activeLayer = layer;
          layer.isExpanded = true; 
          break;
        }
      }
    }
    _selectedShape = shape;
    notifyListeners();
  }

  void removeShape(CompassShape shape) {
    List<CompassPoint> shapePoints = [];
    if (shape is CompassLine) {
      shapePoints = [shape.start, shape.end];
    } else if (shape is CompassCircle) {
      shapePoints = [shape.center];
      if (shape.radiusPoint != null) shapePoints.add(shape.radiusPoint!);
    } else if (shape is CompassSpiral) {
      shapePoints = [shape.center, shape.startPoint];
    } else if (shape is CompassRectangle) { 
      shapePoints = [shape.p1, shape.p2];
    } else if (shape is CompassXSpline) {
      shapePoints = shape.nodes.map((n) => n.point).toList();
      if (shape.anchorPoint != null) shapePoints.add(shape.anchorPoint!);
    } else if (shape is CompassMesh) {
      // Every grid node plus the centroid anchor. They only attach among
      // themselves (anchor -> each node), so the batch GC below collects the
      // whole lattice with no external dependency holding any of it alive.
      shapePoints = shape.nodes.map((n) => n.point).toList();
      if (shape.anchorPoint != null) shapePoints.add(shape.anchorPoint!);
    }

    bool removed = false;
    for (var layer in layers) {
      if (layer.shapes.remove(shape)) {
        if (_selectedShape == shape) {
          _selectedShape = null;
        }
        removed = true;
        break;
      }
    }

    if (removed) {
      // Before the constraints are torn down, gather any rider points bound to
      // this shape and fold them into the GC batch. A rider -- the free point
      // created by "Add Point to Shape", governed by a PointOnLine/Circle/Spiral
      // constraint -- lives as an attachment-CHILD of one of the host's structural
      // points plus a constraint entry; it occupies no structural slot. So without
      // this it (a) is never handed to checkAndGCPoint and lingers as a dead blue
      // dot, and (b) when the host's OWN structural point is later GC-checked, the
      // rider sitting in that point's attachedPoints reads as an "external
      // dependency" and keeps the host point alive too -- so deleting a line left
      // line.start AND the rider behind, no longer even re-projecting. Folding the
      // rider into the batch both collects it for its own GC check and stops it
      // from falsely pinning the host. Must run BEFORE the removeWhere below, while
      // the constraints still exist to be read.
      for (var c in constraints) {
        if (_constraintHasShape(c, shape)) {
          final rider = _constraintRider(c);
          if (rider != null) shapePoints.add(rider);
        }
      }

      constraints.removeWhere((c) => _constraintHasShape(c, shape));

      final batch = shapePoints.toSet();
      for (var p in shapePoints) {
        checkAndGCPoint(p, batch: batch);
      }
      
      saveSnapshot();
      notifyListeners();
    }
  }

  // --- MADE PUBLIC for ShapeConverter ---
  void checkAndGCPoint(CompassPoint p, {Set<CompassPoint>? batch}) {
    final deletionBatch = batch ?? {p};

    // (A) Still a structural member of any surviving shape? Always keep if so.
    bool isUsed = false;
    for (var layer in layers) {
      for (var s in layer.shapes) {
        if (s is CompassLine && (s.start == p || s.end == p)) isUsed = true;
        else if (s is CompassCircle && (s.center == p || s.radiusPoint == p)) isUsed = true;
        else if (s is CompassSpiral && (s.center == p || s.startPoint == p)) isUsed = true;
        else if (s is CompassRectangle && (s.p1 == p || s.p2 == p)) isUsed = true; 
        else if (s is CompassXSpline && (s.nodes.any((n) => n.point == p) || s.anchorPoint == p)) isUsed = true;
        else if (s is CompassMesh && (s.containsNode(p) || s.anchorPoint == p)) isUsed = true;
        
        if (isUsed) break;
      }
      if (isUsed) break;
    }

    if (isUsed) return;

    // (B) Still bound -- as parent or as child -- to a point OUTSIDE the batch?
    bool hasExternalDependency = false;

    for (var child in p.attachedPoints) {
      if (!deletionBatch.contains(child)) {
        hasExternalDependency = true;
        break;
      }
    }

    if (!hasExternalDependency) {
      for (var other in points) {
        if (deletionBatch.contains(other)) continue;
        if (other.attachedPoints.contains(p)) {
          hasExternalDependency = true;
          break;
        }
      }
    }

    if (!hasExternalDependency) {
      points.remove(p);
      for (var remainingPoint in points) {
        remainingPoint.attachedPoints.remove(p);
      }
      constraints.removeWhere((c) => _constraintHasPoint(c, p));
    }
  }

  // ===========================================================================
  // SHAPE CONVERTERS (Delegated to shape_converter.dart)
  // ===========================================================================

  void convertCircleToSpline(CompassCircle circle) {
    ShapeConverter.convertCircleToSpline(this, circle);
  }

  void convertRectangleToSpline(CompassRectangle rect) {
    ShapeConverter.convertRectangleToSpline(this, rect);
  }

  void convertRectangleToMesh(CompassRectangle rect, {int rows = 3, int cols = 3}) {
    ShapeConverter.convertRectangleToMesh(this, rect, rows: rows, cols: cols);
  }

  void bakeLayer(CompassLayer layer) {
    ShapeConverter.bakeLayer(this, layer);
  }

  // ===========================================================================
  // HIERARCHY Z-ORDER ACTIONS (Delegated to hierarchy_ops.dart)
  // ===========================================================================
  // Thin pass-throughs to HierarchyOps, parallel to the ShapeConverter block
  // above. Each indexed argument is a MODEL index (into engine.layers /
  // layer.shapes) and means the FINAL index the moved item should occupy -- the
  // panel converts its reversed visual indices to model indices before calling.
  // See hierarchy_ops.dart for the full index contract and the panel conversion
  // recipe. HierarchyOps owns the snapshot + notify, so these add nothing.

  void reorderLayer(int from, int to) {
    HierarchyOps.reorderLayer(this, from, to);
  }

  void reorderShape(CompassLayer layer, int from, int to) {
    HierarchyOps.reorderShape(this, layer, from, to);
  }

  void moveShapeToLayer(
    CompassShape shape,
    CompassLayer fromLayer,
    CompassLayer toLayer,
    int insertIndex,
  ) {
    HierarchyOps.moveShapeToLayer(this, shape, fromLayer, toLayer, insertIndex);
  }

  // ===========================================================================
  // GRADIENT MESH ENGINE ACTIONS
  // ===========================================================================

  // Reassign one node's color. Routed through saveSnapshot/notify because a color
  // edit is a discrete, undoable action (unlike a continuous node drag). No-ops if
  // the point isn't actually one of this mesh's nodes.
  void setMeshNodeColor(CompassMesh mesh, CompassPoint node, Color color) {
    if (mesh.setColorForPoint(node, color)) {
      saveSnapshot();
      notifyListeners();
    }
  }

  // Paint a whole selection of nodes at once (the multi-select path). Snapshots a
  // single undo step for the batch rather than one per node. Points in [nodes]
  // that don't belong to [mesh] are simply skipped.
  void setMeshSelectedColors(CompassMesh mesh, Set<CompassPoint> nodes, Color color) {
    bool changed = false;
    for (var p in nodes) {
      if (mesh.setColorForPoint(p, color)) changed = true;
    }
    if (changed) {
      saveSnapshot();
      notifyListeners();
    }
  }

  // --- X-KEY SLICING: insert a full row or column into a gradient mesh ---------
  //
  // A slice subdivides the lattice by one row or column at a parametric position
  // [t] within the hovered cell-band (0 = upper/left bounding gridline, 1 =
  // lower/right, 0.5 = midpoint). The inserted nodes' positions and colors are
  // interpolated from their neighbors at t -- pure subdivision, so the rendered
  // gradient is unchanged, it just gains a line of editable handles exactly where
  // the cursor was. Because CompassMesh's rows/cols are final, we cannot grow the
  // mesh in place: we build a NEW mesh with the grown dimensions and swap it into
  // the SAME layer slot, preserving Z-order, boolean operation, visibility, and
  // the SAME anchor (so rigid-body cohesion and the rotation pivot are untouched).
  // Existing node points are reused in their new grid slots; only the inserted
  // line's points are minted, registered in engine.points, listener-wired, and
  // attached to the anchor -- exactly the contract the rectangle->mesh converter
  // follows, which is what lets the new nodes participate in selection/
  // serialization/undo with no special casing.

  void insertMeshRow(CompassMesh mesh, int gap, [double t = 0.5]) {
    if (gap < 0 || gap > mesh.rows - 2) return;
    _applyMeshSlice(mesh, mesh.insertRowData(gap, t));
  }

  void insertMeshColumn(CompassMesh mesh, int gap, [double t = 0.5]) {
    if (gap < 0 || gap > mesh.cols - 2) return;
    _applyMeshSlice(mesh, mesh.insertColumnData(gap, t));
  }

  // Shared back-end for both slice directions. Consumes the MeshSliceData layout
  // (row-major, length newRows*newCols, each slot either a reused existing point
  // or an instruction to mint a new one), produces the new node + color lists,
  // and swaps a freshly built CompassMesh into the old one's layer position.
  void _applyMeshSlice(CompassMesh mesh, MeshSliceData data) {
    // Locate the mesh's layer + index so the replacement lands in the same slot.
    CompassLayer? owningLayer;
    int slotIndex = -1;
    for (var layer in layers) {
      final idx = layer.shapes.indexOf(mesh);
      if (idx != -1) {
        owningLayer = layer;
        slotIndex = idx;
        break;
      }
    }
    if (owningLayer == null) return;

    final anchor = mesh.anchorPoint;

    // UPGRADE: List of CompassSplineNode instead of CompassPoint
    final newNodes = List<CompassSplineNode>.filled(
        data.rows * data.cols, mesh.nodes.first,
        growable: false);
    final newColors = List<Color>.filled(
        data.rows * data.cols, const Color(0xFFCCCCCC),
        growable: false);

    for (int i = 0; i < data.rows * data.cols; i++) {
      final existing = data.existing[i];
      if (existing != null) {
        // Reuse the original node in its new slot; carry its color across.
        newNodes[i] = existing;
        newColors[i] = data.reusedColors[i] ?? const Color(0xFFCCCCCC);
      } else {
        // Mint the inserted node: register its point, wire listeners, attach to anchor.
        final pos = data.newPositions[i] ?? Offset.zero;
        final np = CompassPoint(x: pos.dx, y: pos.dy);
        points.add(np);
        np.x.addListener(notifyListeners);
        np.y.addListener(notifyListeners);
        if (anchor != null) anchor.attach(np);

        // UPGRADE: Wrap in a CompassSplineNode, inherit tension at 1.0
        final splineNode = CompassSplineNode(point: np, tension: 1.0);
        splineNode.tension.addListener(notifyListeners);

        newNodes[i] = splineNode;
        newColors[i] = data.newColors[i] ?? const Color(0xFFCCCCCC);
      }
    }

    final newMesh = CompassMesh(
      rows: data.rows,
      cols: data.cols,
      nodes: newNodes,
      colors: newColors,
      anchorPoint: anchor,
      operation: mesh.operation,
      isVisible: mesh.isVisible,
    );

    owningLayer.shapes[slotIndex] = newMesh;
    if (_selectedShape == mesh) _selectedShape = newMesh;

    saveSnapshot();
    notifyListeners();
  }
  
  // ===========================================================================

  void toggleShapeVisibility(CompassShape shape) {
    shape.isVisible = !shape.isVisible;
    if (!shape.isVisible && _selectedShape == shape) {
      _selectedShape = null; // Deselect if hidden
    }
    saveSnapshot();
    notifyListeners();
  }

  void updateSpiral(CompassSpiral spiral, {bool? isClockwise, double? revolutions}) {
    if (isClockwise != null) spiral.isClockwise = isClockwise;
    if (revolutions != null) spiral.revolutions = revolutions;
    saveSnapshot();
    notifyListeners();
  }

  void updateRectangleRadius(CompassRectangle rect, double radius) {
    rect.cornerRadius.value = radius;
    saveSnapshot();
    notifyListeners();
  }

  void toggleRectangleSquare(CompassRectangle rect, bool isSquare) {
    rect.isSquare = isSquare;
    if (isSquare) {
      rect.p2.moveBy(0, 0); 
    }
    saveSnapshot();
    notifyListeners();
  }

  void changeShapeOperation(CompassShape shape, CompassBooleanOp op) {
    shape.operation = op;
    saveSnapshot();
    notifyListeners();
  }

  // ===========================================================================
  // STROKE-REGION STACK ACTIONS
  // ===========================================================================
  // A shape owns an ordered list of outward-stacked stroke regions. Region 0 is the
  // INNERMOST ring (straddling the shape outline); each later region rides OUTWARD
  // on the previous one's outer edge, and if an inner ring widens the outer ones
  // ride along. A stroke is binary: it either FILLS (add -- paints a ring, may have
  // its own color) or CUTS (subtract -- carves the geometry beneath, paints
  // nothing). These mutators are the only way the UI edits the list; each snapshots
  // (undoable) and notifies (live reflow).

  // Append a new region as the new OUTERMOST ring. Defaults to a FILL (add) of width
  // 8 -- a painted ring that shows its color chip immediately. Flip it to a cut in
  // the row toggle to carve instead. Called by the layers-panel "+ Add Stroke".
  void addStrokeRegion(CompassShape shape,
      {CompassBooleanOp op = CompassBooleanOp.add, double width = 8.0}) {
    shape.strokeRegions.add(StrokeRegion(op: op, width: width));
    saveSnapshot();
    notifyListeners();
  }

  // Remove the region at [index] from the stack. Removing the last region returns
  // the shape to no-stroke. Out-of-range indices no-op.
  void removeStrokeRegion(CompassShape shape, int index) {
    if (index < 0 || index >= shape.strokeRegions.length) return;
    shape.strokeRegions.removeAt(index);
    saveSnapshot();
    notifyListeners();
  }

  // Set the op of the region at [index]. For a stroke this is binary in the UI --
  // add (FILL) or subtract (CUT). `none`/`intersect` are not offered for strokes but
  // are tolerated as harmless if ever passed. Out-of-range indices no-op.
  void setStrokeRegionOp(CompassShape shape, int index, CompassBooleanOp op) {
    if (index < 0 || index >= shape.strokeRegions.length) return;
    shape.strokeRegions[index].op = op;
    saveSnapshot();
    notifyListeners();
  }

  // Move the region at [index] by [delta] positions in the stack (delta -1 = one
  // step INWARD toward index 0, +1 = one step OUTWARD). This is how a cut ring is
  // restacked to sit on top of (outside) the fill rings, or fills are reordered.
  // Because the bands stack outward by list order, reordering changes each ring's
  // radius and where a cut bites. No-ops if either the source or target index is
  // out of range (so the ends clamp naturally).
  void moveStrokeRegion(CompassShape shape, int index, int delta) {
    final list = shape.strokeRegions;
    final target = index + delta;
    if (index < 0 || index >= list.length) return;
    if (target < 0 || target >= list.length) return;
    final r = list.removeAt(index);
    list.insert(target, r);
    saveSnapshot();
    notifyListeners();
  }

  // Set the width of the region at [index]. This is what the Properties-panel
  // per-stroke sliders drive: dragging one reflows that band (and every band
  // stacked outside it, since the outward cursor depends on each width) live via
  // notifyListeners. Snapshots so the change round-trips through undo. Non-positive
  // widths are clamped to a tiny epsilon so a band never inverts. Out-of-range
  // indices no-op.
  void setStrokeRegionWidth(CompassShape shape, int index, double width) {
    if (index < 0 || index >= shape.strokeRegions.length) return;
    shape.strokeRegions[index].width = width <= 0 ? 0.01 : width;
    saveSnapshot();
    notifyListeners();
  }

  // Set the fill color of the region at [index]. Only a FILL (add) ring paints, so
  // this is meaningful only for fill rings -- but the value is stored regardless, so
  // flipping a cut ring back to fill restores its color with no re-pick. Passing
  // [color] = null reverts the ring to inheriting the owning layer's fill color.
  // Discrete and undoable, so it snapshots. Out-of-range indices no-op.
  void setStrokeRegionColor(CompassShape shape, int index, Color? color) {
    if (index < 0 || index >= shape.strokeRegions.length) return;
    shape.strokeRegions[index].color = color;
    saveSnapshot();
    notifyListeners();
  }

  void changeLayerColor(CompassLayer layer, Color newColor) {
    layer.color = newColor;
    saveSnapshot();
    notifyListeners();
  }

  void changeLayerStrokeColor(CompassLayer layer, Color newColor) {
    layer.strokeColor = newColor;
    saveSnapshot();
    notifyListeners();
  }

  void changeLayerStrokeWidth(CompassLayer layer, double width) {
    layer.strokeWidth = width;
    saveSnapshot();
    notifyListeners();
  }

  // --- SPLINE SPECIFIC ENGINE ACTIONS ---

  void insertPointIntoSpline(CompassPoint p, CompassXSpline spline) {
    final tap = Offset(p.x.value, p.y.value);
    final details = spline.getInsertDetailsForOffset(tap);
    _spliceNodeIntoSpline(spline, p, details.$1, details.$2);

    saveSnapshot();
    notifyListeners();
  }

  CompassPoint? subdivideSplineSegment(CompassXSpline spline, int segmentIndex, {double t = 0.5}) {
    final int n = spline.nodes.length;
    if (n < 2) return null;

    final int segCount = spline.isClosed ? n : n - 1;
    if (segmentIndex < 0 || segmentIndex >= segCount) return null;

    int index = segmentIndex + 1;
    if (spline.isClosed && segmentIndex == n - 1) index = n;

    final a = spline.nodes[segmentIndex].point;
    final b = spline.nodes[(segmentIndex + 1) % n].point;
    final p = CompassPoint(
      x: (a.x.value + b.x.value) / 2,
      y: (a.y.value + b.y.value) / 2,
    );
    points.add(p);
    p.x.addListener(notifyListeners);
    p.y.addListener(notifyListeners);

    _spliceNodeIntoSpline(spline, p, index, t);

    saveSnapshot();
    notifyListeners();
    return p;
  }

  void _spliceNodeIntoSpline(CompassXSpline spline, CompassPoint p, int index, double t) {
    final node = CompassSplineNode(point: p);
    
    // Ensure all properties trigger a canvas repaint when modified
    node.tension.addListener(notifyListeners);
    node.widthLeft.addListener(notifyListeners);
    node.widthRight.addListener(notifyListeners);

    // De Casteljau exact subdivision for Bezier curves
    if ((index > 0 && index < spline.nodes.length) || (spline.isClosed && index == spline.nodes.length)) {
      final prevIdx = index - 1;
      final nextIdx = index == spline.nodes.length ? 0 : index;

      final prevNode = spline.nodes[prevIdx];
      final nextNode = spline.nodes[nextIdx];

      // Interpolate the variable width using parameter `t` to prevent the stroke from pinching to 0
      node.widthLeft.value = prevNode.widthLeft.value * (1.0 - t) + nextNode.widthLeft.value * t;
      node.widthRight.value = prevNode.widthRight.value * (1.0 - t) + nextNode.widthRight.value * t;

      final controls = spline.getEvaluatedControls();
      final hOut = controls[prevIdx].$1;
      final hIn = controls[nextIdx].$2;

      final p0 = Offset(prevNode.point.x.value, prevNode.point.y.value);
      final p3 = Offset(nextNode.point.x.value, nextNode.point.y.value);

      final p1 = p0 + hOut;
      final p2 = p3 + hIn;

      // 1st order
      final m0 = Offset.lerp(p0, p1, t)!;
      final m1 = Offset.lerp(p1, p2, t)!;
      final m2 = Offset.lerp(p2, p3, t)!;
      // 2nd order
      final r0 = Offset.lerp(m0, m1, t)!;
      final r1 = Offset.lerp(m1, m2, t)!;
      // 3rd order (Point on curve)
      final bPt = Offset.lerp(r0, r1, t)!;

      // Force the new point to snap exactly to the mathematical split
      p.x.value = bPt.dx;
      p.y.value = bPt.dy;

      Offset safeDivide(Offset v, double tension) {
        return tension > 0.001 ? Offset(v.dx / tension, v.dy / tension) : Offset.zero;
      }

      prevNode.handleIn ??= safeDivide(controls[prevIdx].$2, prevNode.tension.value);
      prevNode.handleOut = safeDivide(m0 - p0, prevNode.tension.value);

      nextNode.handleOut ??= safeDivide(controls[nextIdx].$1, nextNode.tension.value);
      nextNode.handleIn = safeDivide(m2 - p3, nextNode.tension.value);

      node.handleIn = safeDivide(r0 - bPt, node.tension.value);
      node.handleOut = safeDivide(r1 - bPt, node.tension.value);
    }

    if (index >= spline.nodes.length) {
      spline.nodes.add(node);
    } else {
      spline.nodes.insert(index, node);
    }

    if (spline.nodes.isNotEmpty) {
      final firstPoint = spline.nodes.first.point;
      if (firstPoint != p) {
        firstPoint.attach(p);
      }
    }
  }

  void toggleSplineClosed(CompassXSpline spline) {
    spline.isClosed = !spline.isClosed;
    saveSnapshot();
    notifyListeners();
  }

  void resetPointHandles(CompassPoint p) {
    bool changed = false;
    for (var layer in layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is CompassXSpline) {
          for (var node in shape.nodes) {
            if (node.point == p) {
              if (node.handleIn != null || node.handleOut != null) {
                node.handleIn = null;
                node.handleOut = null;
                changed = true;
              }
            }
          }
        }
      }
    }
    
    if (changed) {
      saveSnapshot();
      notifyListeners();
    }
  }

  void convertPointToBezier(CompassPoint p) {
    bool changed = false;
    for (var layer in layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is CompassXSpline) {
          List<(Offset, Offset)>? controls;
          for (int i = 0; i < shape.nodes.length; i++) {
            final node = shape.nodes[i];
            if (node.point != p) continue;
            if (node.handleIn != null || node.handleOut != null) continue;

            controls ??= shape.getEvaluatedControls();
            final t = node.tension.value;
            final hOut = controls[i].$1;
            final hIn = controls[i].$2;

            Offset safeDivide(Offset v, double tension) {
              return tension > 0.001 ? Offset(v.dx / tension, v.dy / tension) : v;
            }

            node.handleOut = safeDivide(hOut, t);
            node.handleIn = safeDivide(hIn, t);
            changed = true;
          }
        }
      }
    }

    if (changed) {
      saveSnapshot();
      notifyListeners();
    }
  }

  void commitNodeToBezierEdit(CompassSplineNode node) {
    final t = node.tension.value;
    if ((t - 1.0).abs() > 0.0001) {
      if (node.handleIn != null) {
        node.handleIn = Offset(node.handleIn!.dx * t, node.handleIn!.dy * t);
      }
      if (node.handleOut != null) {
        node.handleOut = Offset(node.handleOut!.dx * t, node.handleOut!.dy * t);
      }
      node.tension.value = 1.0;
    }
    notifyListeners();
  }

  void updateNodeHandle(CompassSplineNode node, bool isOut, Offset handle) {
    if (isOut) {
      node.handleOut = handle;
    } else {
      node.handleIn = handle;
    }
    notifyListeners();
  }

  void applyFilletToNode(CompassXSpline spline, CompassSplineNode node, double cutDistance) {
    int index = spline.nodes.indexOf(node);
    if (index == -1) return;

    final fillet = spline.computeFillet(node, cutDistance);
    if (fillet == null) return;

    int prevIndex = (index - 1 + spline.nodes.length) % spline.nodes.length;
    int nextIndex = (index + 1) % spline.nodes.length;
    
    final prevNode = spline.nodes[prevIndex];
    final nextNode = spline.nodes[nextIndex];

    Offset safeDivide(Offset v, double tension) {
      return tension > 0.001 ? Offset(v.dx / tension, v.dy / tension) : Offset.zero;
    }

    final controls = spline.getEvaluatedControls();
    if (prevNode.handleIn == null && prevNode.handleOut == null) {
      prevNode.handleIn = safeDivide(controls[prevIndex].$2, prevNode.tension.value);
    }
    prevNode.handleOut = safeDivide(fillet.prevHandleOut, prevNode.tension.value);

    if (nextNode.handleIn == null && nextNode.handleOut == null) {
      nextNode.handleOut = safeDivide(controls[nextIndex].$1, nextNode.tension.value);
    }
    nextNode.handleIn = safeDivide(fillet.nextHandleIn, nextNode.tension.value);

    final pt1 = CompassPoint(x: fillet.cutPt1.dx, y: fillet.cutPt1.dy);
    final pt2 = CompassPoint(x: fillet.cutPt2.dx, y: fillet.cutPt2.dy);
    
    points.add(pt1);
    pt1.x.addListener(notifyListeners);
    pt1.y.addListener(notifyListeners);

    points.add(pt2);
    pt2.x.addListener(notifyListeners);
    pt2.y.addListener(notifyListeners);

    if (spline.anchorPoint != null) {
      spline.anchorPoint!.attach(pt1);
      spline.anchorPoint!.attach(pt2);
      spline.anchorPoint!.detach(node.point);
    }

    final newNode1 = CompassSplineNode(
      point: pt1,
      tension: 1.0, 
      handleIn: fillet.node1HandleIn,
      handleOut: fillet.node1HandleOut,
    );
    newNode1.tension.addListener(notifyListeners);

    final newNode2 = CompassSplineNode(
      point: pt2,
      tension: 1.0, 
      handleIn: fillet.node2HandleIn,
      handleOut: fillet.node2HandleOut,
    );
    newNode2.tension.addListener(notifyListeners);

    spline.nodes.insert(index, newNode1);
    spline.nodes.insert(index + 1, newNode2);
    spline.nodes.remove(node);

    checkAndGCPoint(node.point);

    saveSnapshot();
    notifyListeners();
  }

  void smoothNodes(
    Set<CompassPoint> selected,
    Map<CompassPoint, Offset> originalPositions,
    Map<CompassSplineNode, (Offset?, Offset?)> originalHandles,
    double amount,
  ) {
    if (selected.isEmpty) return;
    final a = amount.clamp(0.0, 1.0);

    bool changed = false;

    for (var layer in layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is! CompassXSpline) continue;
        final spline = shape;
        final n = spline.nodes.length;
        if (n < 2) continue;

        final sel = <int>[];
        for (int i = 0; i < n; i++) {
          if (selected.contains(spline.nodes[i].point)) sel.add(i);
        }
        if (sel.isEmpty) continue;

        Offset origPos(int i) {
          final p = spline.nodes[i].point;
          return originalPositions[p] ?? Offset(p.x.value, p.y.value);
        }

        if (sel.length >= 2) {
          for (final i in sel) {
            if (!spline.isClosed && (i == 0 || i == n - 1)) continue;

            final prev = origPos((i - 1 + n) % n);
            final next = origPos((i + 1) % n);
            final mid = Offset((prev.dx + next.dx) / 2, (prev.dy + next.dy) / 2);

            final start = origPos(i);
            final target = Offset.lerp(start, mid, a)!;

            final node = spline.nodes[i];
            if ((node.point.x.value - target.dx).abs() > 1e-9 ||
                (node.point.y.value - target.dy).abs() > 1e-9) {
              node.point.x.value = target.dx;
              node.point.y.value = target.dy;
              changed = true;
            }
          }
        } else {
          final i = sel.first;
          if (!spline.isClosed && (i == 0 || i == n - 1)) continue;

          final node = spline.nodes[i];

          Offset? baseIn, baseOut;
          final cap = originalHandles[node];
          if (cap != null && (cap.$1 != null || cap.$2 != null)) {
            baseIn = cap.$1;
            baseOut = cap.$2;
          } else {
            final controls = spline.getEvaluatedControls();
            final t = node.tension.value;
            Offset stripDiv(Offset v) =>
                t > 0.001 ? Offset(v.dx / t, v.dy / t) : v;
            baseOut = stripDiv(controls[i].$1);
            baseIn = stripDiv(controls[i].$2);
          }

          baseIn ??= Offset.zero;
          baseOut ??= Offset.zero;

          final prev = origPos((i - 1 + n) % n);
          final next = origPos((i + 1) % n);
          final chord = next - prev;
          final chordLen = chord.distance;
          if (chordLen < 1e-6) continue; 

          final dir = Offset(chord.dx / chordLen, chord.dy / chordLen);

          Offset alignTo(Offset base, Offset unitTarget) {
            final len = base.distance;
            if (len < 1e-6) return base; 
            final aligned = Offset(unitTarget.dx * len, unitTarget.dy * len);
            final blended = Offset.lerp(base, aligned, a)!;
            final bl = blended.distance;
            if (bl < 1e-6) return aligned;
            return Offset(blended.dx / bl * len, blended.dy / bl * len);
          }

          final newOut = alignTo(baseOut, dir);
          final newIn = alignTo(baseIn, Offset(-dir.dx, -dir.dy));

          if ((node.tension.value - 1.0).abs() > 1e-6) {
            node.tension.value = 1.0;
          }
          node.handleOut = newOut;
          node.handleIn = newIn;
          changed = true;
        }
      }
    }

    if (changed) notifyListeners();
  }

  void smoothWidths(
    Set<CompassPoint> selected,
    Map<CompassSplineNode, (double, double)> originalWidths,
    double amount,
  ) {
    if (selected.isEmpty) return;
    final a = amount.clamp(0.0, 1.0);

    bool changed = false;

    for (var layer in layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is! CompassXSpline) continue;
        final spline = shape;
        final n = spline.nodes.length;
        if (n < 2) continue;

        final sel = <int>[];
        for (int i = 0; i < n; i++) {
          if (selected.contains(spline.nodes[i].point)) sel.add(i);
        }
        if (sel.isEmpty) continue;

        (double, double) origW(int i) {
          final node = spline.nodes[i];
          return originalWidths[node] ?? (node.widthLeft.value, node.widthRight.value);
        }

        for (final i in sel) {
          if (!spline.isClosed && (i == 0 || i == n - 1)) continue;

          final prev = origW((i - 1 + n) % n);
          final next = origW((i + 1) % n);

          final targetL = (prev.$1 + next.$1) / 2.0;
          final targetR = (prev.$2 + next.$2) / 2.0;

          final startW = origW(i);

          final newL = startW.$1 + (targetL - startW.$1) * a;
          final newR = startW.$2 + (targetR - startW.$2) * a;

          final node = spline.nodes[i];

          if ((node.widthLeft.value - newL).abs() > 1e-6 ||
              (node.widthRight.value - newR).abs() > 1e-6) {
            node.widthLeft.value = newL;
            node.widthRight.value = newR;
            changed = true;
          }
        }
      }
    }

    if (changed) notifyListeners();
  }

  // -------------------------------------

  void addPoint(CompassPoint p) {
    points.add(p);
    p.x.addListener(notifyListeners);
    p.y.addListener(notifyListeners);
    saveSnapshot();
    notifyListeners();
  }

  void removePoint(CompassPoint p) {
    // A mesh is a rigid rows x cols lattice: deleting any single node would leave
    // a hole the bilinear grid can't represent. So deleting a mesh node deletes
    // the WHOLE mesh, routed through removeShape -- which batch-GCs every node and
    // the anchor together (the grid can be large; the spline-collapse path below
    // only detaches, which would strand all the other nodes as dead points). We
    // detect ownership before the generic removeWhere and delegate, then return:
    // removeShape already snapshots, notifies, and clears selection. (If several
    // nodes of the same mesh are deleted in one pass, the first call removes the
    // mesh and GCs the rest, so later calls simply find nothing and no-op.)
    for (var layer in layers) {
      for (var s in layer.shapes) {
        if (s is CompassMesh && (s.containsNode(p) || s.anchorPoint == p)) {
          removeShape(s);
          return;
        }
      }
    }

    for (var layer in layers) {
      layer.shapes.removeWhere((shape) {
        if (shape is CompassLine) {
          return shape.start == p || shape.end == p;
        } else if (shape is CompassCircle) {
          return shape.center == p || shape.radiusPoint == p;
        } else if (shape is CompassSpiral) {
          return shape.center == p || shape.startPoint == p;
        } else if (shape is CompassRectangle) {
          return shape.p1 == p || shape.p2 == p;
        } else if (shape is CompassXSpline) {
          shape.nodes.removeWhere((n) => n.point == p);
          if (shape.nodes.length < 2) {
             if (shape.anchorPoint != null) {
                for (var n in shape.nodes) shape.anchorPoint!.detach(n.point);
             }
             return true; 
          }
          return false; 
        }
        return false;
      });
    }
    
    if (_selectedShape != null) {
      bool stillExists = false;
      for (var layer in layers) {
        if (layer.shapes.contains(_selectedShape)) {
          stillExists = true;
          break;
        }
      }
      if (!stillExists) _selectedShape = null;
    }

    points.remove(p);
    for (var remainingPoint in points) {
      remainingPoint.attachedPoints.remove(p);
    }
    constraints.removeWhere((c) => _constraintHasPoint(c, p));

    saveSnapshot();
    notifyListeners();
  }

  void addShape(CompassShape s) {
    if (activeLayer != null) {
      activeLayer!.shapes.add(s);
      _selectedShape = s;
      activeLayer!.isExpanded = true;
      saveSnapshot();
      notifyListeners();
    }
  }

  void addPointOnLine(CompassPoint point, CompassLine line) {
    constraints.add(PointOnLineConstraint(point: point, line: line));
    saveSnapshot();
    notifyListeners();
  }

  void addPointOnCircle(CompassPoint point, CompassCircle circle) {
    constraints.add(PointOnCircleConstraint(point: point, circle: circle));
    saveSnapshot();
    notifyListeners();
  }

  void addPointOnSpiral(CompassPoint point, CompassSpiral spiral) {
    constraints.add(PointOnSpiralConstraint(point: point, spiral: spiral));
    saveSnapshot();
    notifyListeners();
  }

  bool _constraintHasShape(CompassConstraint c, CompassShape shape) {
    if (c is PointOnLineConstraint) return c.line == shape;
    if (c is PointOnCircleConstraint) return c.circle == shape;
    if (c is PointOnSpiralConstraint) return c.spiral == shape;
    return false;
  }

  // The free "rider" point a host-rider constraint binds onto its host shape --
  // the point created via "Add Point to Shape". removeShape uses this to fold a
  // deleted shape's riders into the GC batch so they die with the shape instead of
  // lingering, and so they don't falsely keep the host's structural points alive.
  // Returns null for constraint kinds with no such rider (there are none today,
  // but this keeps the switch total if more constraints are added later).
  CompassPoint? _constraintRider(CompassConstraint c) {
    if (c is PointOnLineConstraint) return c.point;
    if (c is PointOnCircleConstraint) return c.point;
    if (c is PointOnSpiralConstraint) return c.point;
    return null;
  }

  bool _constraintHasPoint(CompassConstraint c, CompassPoint p) {
    if (c is PointOnLineConstraint) {
      return c.point == p || c.line.start == p || c.line.end == p;
    }
    if (c is PointOnCircleConstraint) {
      return c.point == p || c.circle.center == p || c.circle.radiusPoint == p;
    }
    if (c is PointOnSpiralConstraint) {
      return c.point == p || c.spiral.center == p || c.spiral.startPoint == p;
    }
    return false;
  }

  void finalizePointDrag() {
    saveSnapshot();
  }

  String toProjectData() {
    return ProjectSerializer.serialize(this);
  }

  void loadProjectData(String data) {
    ProjectSerializer.deserialize(this, data, notifyListeners);
  }

  String toSVG() {
    return SVGExporter.toSVG(this);
  }

  Future<Uint8List?> toPNG({double scale = 2.0}) {
    return PNGExporter.toPNG(this, scale: scale);
  }

  String toOBJ(
    CompassLayer layer, {
    double samplingSpacing = 2.0,
    bool gridMode = false,
    int gridCount = 48,
  }) {
    return OBJExporter.toOBJ(
      layer,
      samplingSpacing: samplingSpacing,
      gridMode: gridMode,
      gridCount: gridCount,
    );
  }
}