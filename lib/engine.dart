// /lib/engine.dart

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';

// --- DATA MODELS ---
import 'models/geometry/point.dart';
import 'models/geometry/shape.dart';
import 'models/geometry/gradient.dart'; // <--- NEW: per-shape linear fill gradient
import 'models/geometry/line.dart';
import 'models/geometry/circle.dart';
import 'models/geometry/spiral.dart';
import 'models/geometry/spline.dart';
import 'models/geometry/rectangle.dart';
import 'models/geometry/mesh.dart';
import 'models/geometry/image.dart';
import 'models/layer.dart';
import 'models/reference_layer.dart';

// --- CONSTRAINTS ---
import 'constraints.dart';

// --- IO ---
import 'io/project_serializer.dart';
import 'io/svg_exporter.dart';
import 'io/png_exporter.dart';
import 'io/obj_exporter.dart';
import 'io/ascii_exporter.dart'; // <--- NEW: ascii exporter

// --- GEOMETRY HELPERS ---
import 'path_baker.dart';
import 'shape_converter.dart';

// --- HIERARCHY OPS ---
import 'hierarchy_ops.dart';

/// The state holder and brain of the application.
class CompassEngine extends ChangeNotifier {
  final List<CompassPoint> points = [];
  final List<CompassLayer> layers = [];

  // Live registry of ALL live constraints.
  //
  // Host-rider constraints (PointOnLine / PointOnCircle / PointOnSpiral) have NO
  // other reconstruction path, so the engine must own them for serialization to
  // persist them -- and because undo() round-trips through serialize/deserialize,
  // owning them here is exactly what makes them survive Ctrl+Z too.
  //
  // DistanceRadiusConstraint and SquareConstraint are ALSO registered here now --
  // not for serialization (the serializer type-checks and only ever WRITES
  // PONLINE/PONCIRCLE/PONSPIRAL lines; these two are rebuilt on load from the
  // circle's radius wiring and the rectangle's isSquare flag respectively) -- but
  // for LIFECYCLE: a constraint the engine cannot find is a constraint the engine
  // cannot unbind, and an un-unbound constraint keeps enforcing against deleted
  // geometry forever (its bind() listeners hold it alive and firing). Every
  // constraint construction site must therefore register here.
  //
  // REMOVAL RULE: never bare-remove from this list. Route through
  // _removeConstraintsWhere (or unbindAllConstraints), which unbind()s first --
  // otherwise the removed constraint lives on as a zombie inside the point
  // notifiers' listener lists.
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

  // Monotonic document/UI revision used by render caches. Point notifiers are
  // wired directly to notifyListeners(), so geometry drags increment this too.
  int _renderRevision = 0;
  int get renderRevision => _renderRevision;

  // The live document painter listens here. UI-only state (selection, expanded
  // hierarchy rows, node labels) continues through the engine ChangeNotifier
  // without forcing the document pixels to repaint.
  final ChangeNotifier _documentRepaintNotifier = ChangeNotifier();
  Listenable get documentRepaint => _documentRepaintNotifier;

  int _notificationBatchDepth = 0;
  bool _notificationPending = false;

  /// Coalesces the many coordinate/listener notifications produced by one
  /// pointer update into a single render invalidation. Constraints still run
  /// synchronously; only the outward ChangeNotifier emission is deferred.
  T runNotificationBatch<T>(T Function() action) {
    _notificationBatchDepth++;
    try {
      return action();
    } finally {
      _notificationBatchDepth--;
      if (_notificationBatchDepth == 0 && _notificationPending) {
        _notificationPending = false;
        notifyListeners();
      }
    }
  }

  @override
  void notifyListeners() {
    if (_notificationBatchDepth > 0) {
      _notificationPending = true;
      return;
    }

    _renderRevision++;
    _documentRepaintNotifier.notifyListeners();
    super.notifyListeners();
  }

  /// Emits panel/overlay state without invalidating document raster content.
  void notifyUiListeners() {
    super.notifyListeners();
  }

  @override
  void dispose() {
    // New Project swaps the whole engine out; unbind everything so the discarded
    // constraint graph is fully inert (no listener can fire during teardown).
    unbindAllConstraints();
    for (final layer in layers) {
      for (final shape in layer.shapes) {
        if (shape is CompassImage) shape.image?.dispose();
      }
    }
    _documentRepaintNotifier.dispose();
    super.dispose();
  }

  // ===========================================================================
  // CONSTRAINT LIFECYCLE
  // ===========================================================================

  /// The ONLY sanctioned way to drop constraints: unbind (detach every listener
  /// bind() registered) and then remove from the registry. A bare removeWhere
  /// leaves the constraint alive inside the point notifiers' listener lists,
  /// still enforcing against whatever geometry it referenced -- the "zombie
  /// constraint" bug that snapped surviving points onto deleted shapes.
  void _removeConstraintsWhere(bool Function(CompassConstraint) test) {
    for (final c in constraints) {
      if (test(c)) c.unbind();
    }
    constraints.removeWhere(test);
  }

  /// Unbinds and drops every constraint. Used on engine dispose, and intended
  /// for the deserializer's clear-before-load (the old graph must be silenced
  /// before the new one is built on fresh points).
  void unbindAllConstraints() {
    for (final c in constraints) {
      c.unbind();
    }
    constraints.clear();
  }

  /// Drops any selected points that no longer exist in the live pool. Deletion
  /// paths and full reloads (open / undo) both replace or remove points, and a
  /// selection holding dead objects keeps ghost highlights on screen AND lets a
  /// drag fire listeners on geometry the engine has already forgotten.
  void _pruneSelection() {
    selectedPoints.removeWhere((p) => !points.contains(p));
  }

  /// The structural points of a shape, one place instead of three hand-rolled
  /// copies (removeShape / removePoints / removeLayer).
  ///
  /// GRADIENT STOPS ride the tail of EVERY shape type: a shape gradient is a
  /// base-class property, and its stop points live in engine.points attached to
  /// the shape's primary structural point. Appending them here is what makes a
  /// shape's stops die WITH the shape (removeShape / removeLayer both GC through
  /// this list), with no per-type casing.
  List<CompassPoint> _pointsOfShape(CompassShape shape) {
    final pts = <CompassPoint>[];
    if (shape is CompassLine) {
      pts.addAll([shape.start, shape.end]);
    } else if (shape is CompassCircle) {
      pts.add(shape.center);
      if (shape.radiusPoint != null) pts.add(shape.radiusPoint!);
    } else if (shape is CompassSpiral) {
      pts.addAll([shape.center, shape.startPoint]);
    } else if (shape is CompassRectangle) {
      pts.addAll([shape.p1, shape.p2]);
    } else if (shape is CompassImage) {
      pts.addAll([shape.origin, shape.xHandle, shape.yHandle]);
    } else if (shape is CompassXSpline) {
      pts.addAll(shape.nodes.map((n) => n.point));
      if (shape.anchorPoint != null) pts.add(shape.anchorPoint!);
    } else if (shape is CompassMesh) {
      pts.addAll(shape.nodes.map((n) => n.point));
      if (shape.anchorPoint != null) pts.add(shape.anchorPoint!);
    }

    // Gradient stop points ride every shape type (gradient is on the base class).
    final g = shape.gradient;
    if (g != null) {
      pts.addAll(g.stops.map((s) => s.point));
    }
    return pts;
  }

  void toggleNodeIndices(bool show) {
    showNodeIndices = show;
    notifyUiListeners();
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

  Future<ui.Image?> _decodeRasterImage(String path) async {
    final lower = path.toLowerCase();
    if (!(lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg'))) {
      return null;
    }

    final file = File(path);
    if (!await file.exists()) return null;

    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  /// Reloads the runtime pixels for an existing IMG object without changing its
  /// geometry or creating an undo state. Used after project deserialization.
  Future<bool> decodeImageShape(
    CompassImage shape, {
    bool notify = true,
  }) async {
    try {
      final decoded = await _decodeRasterImage(shape.imagePath);
      if (decoded == null) return false;

      final isStillLive = layers.any((layer) => layer.shapes.contains(shape));
      if (!isStillLive) {
        decoded.dispose();
        return false;
      }

      shape.image?.dispose();
      shape.image = decoded;
      if (notify) notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to decode IMG object: $e');
      return false;
    }
  }

  /// Imports a PNG/JPG as a normal ordered IMG object on a fresh layer.
  ///
  /// The three points form an affine frame: origin, X edge, and Y edge. The
  /// origin owns the two edge points in the attachment graph, so dragging it
  /// translates the whole image while the existing point/rotation tools can
  /// reshape or rotate the frame naturally.
  Future<CompassImage?> importImageLayer(String path) async {
    ui.Image? decoded;
    try {
      decoded = await _decodeRasterImage(path);
      if (decoded == null) return null;

      final maxDimension = max(decoded.width, decoded.height).toDouble();
      final displayScale = maxDimension > 900.0 ? 900.0 / maxDimension : 1.0;
      final width = decoded.width * displayScale;
      final height = decoded.height * displayScale;

      final origin = CompassPoint(x: -width / 2.0, y: -height / 2.0);
      final xHandle = CompassPoint(x: width / 2.0, y: -height / 2.0);
      final yHandle = CompassPoint(x: -width / 2.0, y: height / 2.0);

      origin.attach(xHandle);
      origin.attach(yHandle);

      for (final point in [origin, xHandle, yHandle]) {
        points.add(point);
        point.x.addListener(notifyListeners);
        point.y.addListener(notifyListeners);
      }

      final imageShape = CompassImage(
        imagePath: path,
        origin: origin,
        xHandle: xHandle,
        yHandle: yHandle,
        image: decoded,
      );
      decoded = null; // Ownership transferred to the document shape.

      final safeName = imageShape.displayName
          .replaceAll(RegExp(r'[,\r\n]'), ' ')
          .trim();
      final layer = CompassLayer(
        name: safeName.isEmpty ? 'IMG' : 'IMG · $safeName',
      );
      layer.shapes.add(imageShape);
      layers.add(layer);
      activeLayer = layer;
      _selectedShape = imageShape;
      selectedPoints.clear();

      saveSnapshot();
      notifyListeners();
      return imageShape;
    } catch (e) {
      decoded?.dispose();
      debugPrint('Failed to import IMG layer: $e');
      return null;
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

  /// Renames [layer]. Snapshots + notifies, so a rename is a single undo step
  /// and repaints the hierarchy panel live.
  ///
  /// SERIALIZER-SAFE SANITIZATION: the project format is line-based and
  /// comma-delimited -- the LAYER line writes the name at parts[2] and the
  /// deserializer splits on ',' -- so a comma OR a newline in a name would
  /// corrupt the parse (and thus every save/load AND every undo, since undo
  /// round-trips through serialize/deserialize). Layer names were always
  /// auto-generated ("Layer N") until now, so this never bit; a user-typed name
  /// can contain anything, so we strip commas and CR/LF here (replaced with a
  /// space) as the single chokepoint. A name that is empty after trimming, or
  /// unchanged, is a no-op (no snapshot, no notify) so blanking the field and
  /// hitting Enter cleanly reverts rather than minting junk state.
  void renameLayer(CompassLayer layer, String newName) {
    final cleaned = newName
        .replaceAll(',', ' ')
        .replaceAll(RegExp(r'[\r\n]'), ' ')
        .trim();
    if (cleaned.isEmpty) return;
    if (layer.name == cleaned) return;
    layer.name = cleaned;
    saveSnapshot();
    notifyListeners();
  }

  void removeLayer(CompassLayer layer) {
    if (!layers.contains(layer)) return;

    // FULL GC on layer deletion. Previously this was a bare layers.remove():
    // every point of every shape in the layer stayed in the pool (and RENDERED,
    // since an unused point counts as unlocked), and every constraint hosted by
    // the layer's shapes stayed live -- so deleting a layer left a floating
    // point cloud with zombie rules attached. Same recipe as removeShape, over
    // the whole shape list at once, in one batch so intra-layer attachment
    // edges (anchor -> nodes, center -> satellites) can't block each other.
    final shapePoints = <CompassPoint>[];
    for (var shape in layer.shapes) {
      shapePoints.addAll(_pointsOfShape(shape));
    }

    // Riders of constraints hosted by any shape in this layer are GC candidates
    // too, exactly as in removeShape.
    for (var c in constraints) {
      for (var shape in layer.shapes) {
        if (_constraintHasShape(c, shape)) {
          final rider = _constraintRider(c);
          if (rider != null) shapePoints.add(rider);
          break;
        }
      }
    }

    final deadShapes = List<CompassShape>.from(layer.shapes);
    for (final shape in deadShapes) {
      if (shape is CompassImage) shape.image?.dispose();
    }
    layers.remove(layer);
    
    if (activeLayer == layer) {
      activeLayer = layers.isNotEmpty ? layers.first : null;
    }

    if (_selectedShape != null && deadShapes.contains(_selectedShape)) {
      _selectedShape = null;
    }

    if (layers.isEmpty) {
      final newLayer = CompassLayer(name: 'Layer 1');
      layers.add(newLayer);
      activeLayer = newLayer;
    }

    // Unbind + drop every constraint hosted by a deleted shape (must happen
    // BEFORE the point GC, mirroring removeShape's order; constraints matched
    // only by a deleted POINT are handled inside checkAndGCPoint per point).
    _removeConstraintsWhere(
        (c) => deadShapes.any((s) => _constraintHasShape(c, s)));

    final batch = shapePoints.toSet();
    for (var p in shapePoints) {
      checkAndGCPoint(p, batch: batch);
    }

    _pruneSelection();

    saveSnapshot();
    notifyListeners();
  }

  void selectLayer(CompassLayer layer) {
    if (!layer.isLocked) {
      activeLayer = layer;
      _selectedShape = null; 
      notifyUiListeners();
    }
  }
  
  void toggleLayerExpanded(CompassLayer layer) {
    layer.isExpanded = !layer.isExpanded;
    notifyUiListeners();
  }

  /// Toggles a layer's document visibility and invalidates the document painter.
  ///
  /// Layer visibility changes the rasterized artwork, so it must not travel
  /// through the UI-only selection notification path used by [selectLayer].
  void toggleLayerVisibility(CompassLayer layer) {
    layer.isVisible = !layer.isVisible;

    // Preserve the visibility-button's existing behavior of activating the
    // clicked layer when it is editable. Hidden layers can remain active so
    // they are easy to reveal again from the hierarchy.
    if (!layer.isLocked) {
      activeLayer = layer;
      _selectedShape = null;
    }

    saveSnapshot();
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
    notifyUiListeners();
  }

  // ===========================================================================
  // DESELECT ALL (engine side)
  // ===========================================================================

  /// Clears the engine-owned selection state: the selected point set and the
  /// selected shape. One notify for the batch.
  ///
  /// This exists so UI that has no CanvasController reference (the menu bar,
  /// which only holds the engine) can offer "Deselect All". It is deliberately
  /// the SMALL half of the story: the CanvasController's deselectAll() clears
  /// this PLUS all controller-side interaction state (active pen spline,
  /// shapeStartPoint, transient drag/rotate/width/fillet slots, stranded
  /// isBeingDragged flags) and is what the Escape key binds to. The menu path
  /// reaches the controller-side cleanup indirectly: clearing the engine
  /// selection here prunes everything the controller's selection getters proxy
  /// to, and the controller repaints via the engine notify.
  ///
  /// No undo snapshot: selection is not document state (it is never serialized),
  /// so deselecting must never mint an undo step.
  void deselectAll() {
    selectedPoints.clear();
    _selectedShape = null;
    notifyListeners();
  }

  void removeShape(CompassShape shape) {
    List<CompassPoint> shapePoints = _pointsOfShape(shape);

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
      if (shape is CompassImage) shape.image?.dispose();

      for (var c in constraints) {
        if (_constraintHasShape(c, shape)) {
          final rider = _constraintRider(c);
          if (rider != null) shapePoints.add(rider);
        }
      }

      // Unbind BEFORE dropping: a bare removeWhere here was the root of the
      // zombie-constraint bug -- the host shape vanished but its riders kept
      // getting re-projected onto the frozen ghost geometry on every drag.
      _removeConstraintsWhere((c) => _constraintHasShape(c, shape));

      final batch = shapePoints.toSet();
      for (var p in shapePoints) {
        checkAndGCPoint(p, batch: batch);
      }

      _pruneSelection();
      
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
        else if (s is CompassImage &&
            (s.origin == p || s.xHandle == p || s.yHandle == p)) isUsed = true;
        else if (s is CompassXSpline && (s.nodes.any((n) => n.point == p) || s.anchorPoint == p)) isUsed = true;
        else if (s is CompassMesh && (s.containsNode(p) || s.anchorPoint == p)) isUsed = true;

        // A GRADIENT STOP of any surviving shape is "used": it must live as long
        // as its shape does, regardless of shape type. Checked independently of
        // the structural if/else chain above since gradient is a base-class prop.
        if (!isUsed && s.gradient != null &&
            s.gradient!.stops.any((st) => st.point == p)) {
          isUsed = true;
        }

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
      // Unbind-aware: the constraint must stop listening, not just leave the list.
      _removeConstraintsWhere((c) => _constraintHasPoint(c, p));
      selectedPoints.remove(p);
    }
  }

  /// Hard-GC used by applyFilletToNode: the fillet REPLACES the corner node, so
  /// the old corner point must go -- but if that corner was ever spliced in via
  /// the Q tool, it carries an incoming spline-cohesion attach edge (anchor
  /// -> spliced point) that checkAndGCPoint's dependency check reads as "still
  /// needed", stranding the point on the canvas. Here we verify the point is
  /// structurally unused first (a SHARED corner survives untouched), then strip
  /// its attachment edges in both directions and delete it. Edge-stripping is
  /// safe precisely because structural non-use was just proven: the only edges
  /// a non-structural point carries are stale cohesion links to the shape that
  /// is discarding it.
  void _gcPointHardIfUnused(CompassPoint p) {
    for (var layer in layers) {
      for (var s in layer.shapes) {
        if (_pointsOfShape(s).contains(p)) return; // structurally used: keep
      }
    }

    points.remove(p);
    for (var remainingPoint in points) {
      remainingPoint.attachedPoints.remove(p);
    }
    p.attachedPoints.clear();
    _removeConstraintsWhere((c) => _constraintHasPoint(c, p));
    selectedPoints.remove(p);
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

  void setMeshNodeColor(CompassMesh mesh, CompassPoint node, Color color) {
    if (mesh.setColorForPoint(node, color)) {
      saveSnapshot();
      notifyListeners();
    }
  }

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

  void insertMeshRow(CompassMesh mesh, int gap, [double t = 0.5]) {
    if (gap < 0 || gap > mesh.rows - 2) return;
    _applyMeshSlice(mesh, mesh.insertRowData(gap, t));
  }

  void insertMeshColumn(CompassMesh mesh, int gap, [double t = 0.5]) {
    if (gap < 0 || gap > mesh.cols - 2) return;
    _applyMeshSlice(mesh, mesh.insertColumnData(gap, t));
  }

  void _applyMeshSlice(CompassMesh mesh, MeshSliceData data) {
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

    final newNodes = List<CompassSplineNode>.filled(
        data.rows * data.cols, mesh.nodes.first,
        growable: false);
    final newColors = List<Color>.filled(
        data.rows * data.cols, const Color(0xFFCCCCCC),
        growable: false);

    for (int i = 0; i < data.rows * data.cols; i++) {
      final existing = data.existing[i];
      if (existing != null) {
        newNodes[i] = existing;
        newColors[i] = data.reusedColors[i] ?? const Color(0xFFCCCCCC);
      } else {
        final pos = data.newPositions[i] ?? Offset.zero;
        final np = CompassPoint(x: pos.dx, y: pos.dy);
        points.add(np);
        np.x.addListener(notifyListeners);
        np.y.addListener(notifyListeners);
        if (anchor != null) anchor.attach(np);

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
  // SHAPE GRADIENT (linear fill) ENGINE ACTIONS
  // ===========================================================================
  //
  // A per-shape linear fill gradient (models/geometry/gradient.dart). Distinct
  // from the gradient MESH above: this is a flat shader fill on an ordinary
  // shape's silhouette, edited via draggable STOP DOTS on the canvas.
  //
  // STOP POINTS ARE ORDINARY POINTS. Each stop is a CompassPoint in engine.points,
  // attached as a CHILD of the shape's primary structural point
  // (_gradientAnchorPoint). That single attach edge buys everything for free:
  //   * shape translate (dragging the primary point) cascades to the stops via
  //     moveBy's attachedPoints walk;
  //   * rigid-body drag / rotation gathers the stops because getRigidBody walks
  //     attachedPoints bidirectionally from the shape's structural points;
  //   * shape deletion GCs the stops because _pointsOfShape appends them.
  // Dragging a STOP itself is independent (moveBy cascades to children, not up to
  // the parent), which is exactly the desired "move this one stop" behavior.
  //
  // NOTE (build order): the serializer does not yet know about gradients, so a
  // gradient survives the live session but is dropped on save / undo until the
  // GRADIENT serialization line lands. Build/test the renderer + canvas editing
  // first; do the serializer before relying on persistence or Ctrl+Z.

  CompassLayer? _layerOfShape(CompassShape shape) {
    for (var l in layers) {
      if (l.shapes.contains(shape)) return l;
    }
    return null;
  }

  /// The point a shape's gradient stops attach to (its rigid-body handle). For a
  /// pen spline with no anchor this falls back to the first node's point -- so
  /// dragging node 0 also drags the gradient stops (a minor quirk on anchorless
  /// splines; every anchored shape -- circle/rect/converted/baked -- is clean).
  CompassPoint? _gradientAnchorPoint(CompassShape shape) {
    if (shape is CompassCircle) return shape.center;
    if (shape is CompassSpiral) return shape.center;
    if (shape is CompassLine) return shape.start;
    if (shape is CompassRectangle) return shape.p1;
    if (shape is CompassImage) return shape.origin;
    if (shape is CompassXSpline) {
      return shape.anchorPoint ??
          (shape.nodes.isNotEmpty ? shape.nodes.first.point : null);
    }
    if (shape is CompassMesh) return shape.anchorPoint;
    return null;
  }

  /// A reasonable placement for a stop when none is supplied -- the shape's
  /// centroid. (With a single stop the render is a solid, so this only matters
  /// as the initial dot location.) Engine-local so this file never imports UI.
  Offset _gradientCentroid(CompassShape shape) {
    if (shape is CompassCircle) return Offset(shape.center.x.value, shape.center.y.value);
    if (shape is CompassSpiral) return Offset(shape.center.x.value, shape.center.y.value);
    if (shape is CompassLine) {
      return Offset((shape.start.x.value + shape.end.x.value) / 2,
          (shape.start.y.value + shape.end.y.value) / 2);
    }
    if (shape is CompassRectangle) {
      return Offset((shape.p1.x.value + shape.p2.x.value) / 2,
          (shape.p1.y.value + shape.p2.y.value) / 2);
    }
    if (shape is CompassImage) {
      return shape.getPath().getBounds().center;
    }
    if (shape is CompassXSpline) {
      if (shape.anchorPoint != null) {
        return Offset(shape.anchorPoint!.x.value, shape.anchorPoint!.y.value);
      }
      if (shape.nodes.isNotEmpty) {
        double cx = 0, cy = 0;
        for (var n in shape.nodes) {
          cx += n.point.x.value;
          cy += n.point.y.value;
        }
        return Offset(cx / shape.nodes.length, cy / shape.nodes.length);
      }
    }
    if (shape is CompassMesh) {
      if (shape.anchorPoint != null) {
        return Offset(shape.anchorPoint!.x.value, shape.anchorPoint!.y.value);
      }
      if (shape.nodes.isNotEmpty) {
        double cx = 0, cy = 0;
        for (var n in shape.nodes) {
          cx += n.point.x.value;
          cy += n.point.y.value;
        }
        return Offset(cx / shape.nodes.length, cy / shape.nodes.length);
      }
    }
    return Offset.zero;
  }

  /// Creates a fresh stop point in the pool, wires its repaint listeners, and
  /// attaches it to the shape's rigid-body handle. Returns the point.
  CompassPoint _spawnStopPoint(CompassShape shape, Offset pos) {
    final sp = CompassPoint(x: pos.dx, y: pos.dy);
    points.add(sp);
    sp.x.addListener(notifyListeners);
    sp.y.addListener(notifyListeners);
    final anchor = _gradientAnchorPoint(shape);
    if (anchor != null && anchor != sp) anchor.attach(sp);
    return sp;
  }

  /// Drops a stop point from the pool and strips its cohesion edges both ways.
  /// Mirrors checkAndGCPoint's teardown (listeners ride the point to GC, as
  /// everywhere else in the engine).
  void _detachStopPoint(CompassPoint p) {
    points.remove(p);
    for (var other in points) {
      other.attachedPoints.remove(p);
    }
    p.attachedPoints.clear();
    selectedPoints.remove(p);
  }

  /// Strips any gradient stop whose point is in [targets] from EVERY shape's
  /// gradient, and nulls a gradient emptied of its last stop (revert to flat).
  /// The stop POINTS themselves are dropped by the caller's normal pool sweep --
  /// this only severs the gradient's reference so no dangling stop survives.
  /// Called from removePoints so the generic Delete key on a selected stop dot
  /// does the sane thing instead of corrupting the gradient.
  void _detachGradientStopsInTargets(Set<CompassPoint> targets) {
    for (var layer in layers) {
      for (var shape in layer.shapes) {
        final g = shape.gradient;
        if (g == null) continue;
        if (g.stops.any((s) => targets.contains(s.point))) {
          g.stops.removeWhere((s) => targets.contains(s.point));
          if (g.stops.isEmpty) shape.gradient = null;
        }
      }
    }
  }

  /// RIGHT-CLICK "Make Gradient". Seeds the shape with a ONE-stop linear gradient
  /// whose color is the shape's current effective fill (the owning layer's fill
  /// color; a neutral gray if the layer is transparent). The single stop renders
  /// as a solid of that color -- identical to before -- until a second stop is
  /// added, at which point the axis/line appears. [seedPos] (the right-click
  /// location) places the first dot right under the cursor; falls back to the
  /// centroid. No-op if the shape already carries a gradient.
  void makeShapeGradient(CompassShape shape, {Offset? seedPos}) {
    if (shape.gradient != null) return;

    final layer = _layerOfShape(shape);
    Color seed = layer?.color ?? const Color(0xFF222222);
    if (seed.alpha == 0) seed = const Color(0xFF808080); // layer had no fill

    final pos = seedPos ?? _gradientCentroid(shape);
    final sp = _spawnStopPoint(shape, pos);

    shape.gradient =
        LinearGradientFill(stops: [GradientStop(point: sp, color: seed)]);

    _selectedShape = shape;
    saveSnapshot();
    notifyListeners();
  }

  /// Adds a stop to [shape]'s existing linear gradient.
  ///
  /// STOP 2 establishes the end of the gradient axis. It is allowed to use the
  /// supplied world-space [pos] directly, because there is no axis to project
  /// onto until that second endpoint exists.
  ///
  /// STOP 3 AND LATER are interior color stops. They are projected onto the
  /// existing first-to-last axis, then inserted before the final endpoint in
  /// projected order. This preserves the two endpoint stops and prevents adding
  /// a color stop from silently redefining the gradient direction.
  ///
  /// When [color] is omitted:
  ///   * the second endpoint receives a contrasting color so the new ramp is
  ///     immediately visible;
  ///   * an interior stop samples the gradient's current color at its projected
  ///     position, so inserting it does not alter the artwork until recolored.
  void addGradientStop(CompassShape shape, Offset pos, {Color? color}) {
    final gradient = shape.gradient;
    if (gradient == null) return;

    final isEstablishingAxis = gradient.stops.length < 2;
    final resolvedPosition =
        isEstablishingAxis ? pos : gradient.projectOntoAxis(pos);

    Color resolvedColor;
    if (color != null) {
      resolvedColor = color;
    } else if (isEstablishingAxis) {
      final referenceColor = gradient.stops.isNotEmpty
          ? gradient.stops.first.color
          : const Color(0xFF808080);

      resolvedColor = referenceColor.computeLuminance() < 0.5
          ? Colors.white
          : Colors.black;
    } else {
      resolvedColor = gradient.colorAtPosition(resolvedPosition) ??
          gradient.stops.first.color;
    }

    final stopPoint = _spawnStopPoint(shape, resolvedPosition);
    final stop = GradientStop(
      point: stopPoint,
      color: resolvedColor,
    );

    gradient.insertInteriorStop(stop);

    saveSnapshot();
    notifyListeners();
  }

  /// Recolors the stop whose point is [stopPoint]. No-op if the shape has no
  /// gradient or the point isn't one of its stops.
  void setGradientStopColor(CompassShape shape, CompassPoint stopPoint, Color color) {
    final g = shape.gradient;
    if (g == null) return;
    for (final s in g.stops) {
      if (s.point == stopPoint) {
        s.color = color;
        saveSnapshot();
        notifyListeners();
        return;
      }
    }
  }

  /// Removes one stop by its point, drops that point, and -- if it was the last
  /// stop -- nulls the gradient (revert to a flat layer fill). No-op if the point
  /// isn't a stop of this shape's gradient.
  void removeGradientStop(CompassShape shape, CompassPoint stopPoint) {
    final g = shape.gradient;
    if (g == null) return;
    final idx = g.stops.indexWhere((s) => s.point == stopPoint);
    if (idx == -1) return;

    g.stops.removeAt(idx);
    _detachStopPoint(stopPoint);
    if (g.stops.isEmpty) shape.gradient = null;

    saveSnapshot();
    notifyListeners();
  }

  /// Removes the whole gradient from [shape] (drops every stop point) and reverts
  /// it to a flat layer fill.
  void removeGradient(CompassShape shape) {
    final g = shape.gradient;
    if (g == null) return;
    for (final s in g.stops) {
      _detachStopPoint(s.point);
    }
    shape.gradient = null;

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

  void setImageOpacity(CompassImage image, double opacity) {
    final next = opacity.clamp(0.0, 1.0).toDouble();
    if ((image.opacity - next).abs() < 1e-9) return;
    image.opacity = next;
    saveSnapshot();
    notifyListeners();
  }

  // ===========================================================================
  // STROKE-REGION STACK ACTIONS
  // ===========================================================================

  void addStrokeRegion(CompassShape shape,
      {CompassBooleanOp op = CompassBooleanOp.add, double width = 8.0}) {
    shape.strokeRegions.add(StrokeRegion(op: op, width: width));
    saveSnapshot();
    notifyListeners();
  }

  void removeStrokeRegion(CompassShape shape, int index) {
    if (index < 0 || index >= shape.strokeRegions.length) return;
    shape.strokeRegions.removeAt(index);
    saveSnapshot();
    notifyListeners();
  }

  void setStrokeRegionOp(CompassShape shape, int index, CompassBooleanOp op) {
    if (index < 0 || index >= shape.strokeRegions.length) return;
    shape.strokeRegions[index].op = op;
    saveSnapshot();
    notifyListeners();
  }

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

  void setStrokeRegionWidth(CompassShape shape, int index, double width) {
    if (index < 0 || index >= shape.strokeRegions.length) return;
    shape.strokeRegions[index].width = width <= 0 ? 0.01 : width;
    saveSnapshot();
    notifyListeners();
  }

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
    _spliceNodeIntoSpline(spline, p, details.$1, details.$2, exactPos: tap);

    saveSnapshot();
    notifyListeners();
  }

  CompassPoint? subdivideSplineSegment(CompassXSpline spline, int segmentIndex, {double t = 0.5, Offset? exactPos}) {
    final int n = spline.nodes.length;
    if (n < 2) return null;

    final int segCount = spline.isClosed ? n : n - 1;
    if (segmentIndex < 0 || segmentIndex >= segCount) return null;

    int index = segmentIndex + 1;
    if (spline.isClosed && segmentIndex == n - 1) index = n;

    final a = spline.nodes[segmentIndex].point;
    final b = spline.nodes[(segmentIndex + 1) % n].point;
    
    // Utilize exact position on the resolved curve if provided
    final p = CompassPoint(
      x: exactPos?.dx ?? (a.x.value + b.x.value) / 2,
      y: exactPos?.dy ?? (a.y.value + b.y.value) / 2,
    );
    
    points.add(p);
    p.x.addListener(notifyListeners);
    p.y.addListener(notifyListeners);

    _spliceNodeIntoSpline(spline, p, index, t, exactPos: exactPos);

    saveSnapshot();
    notifyListeners();
    return p;
  }

  void _spliceNodeIntoSpline(CompassXSpline spline, CompassPoint p, int index, double t, {Offset? exactPos}) {
    final node = CompassSplineNode(point: p);
    
    node.tension.addListener(notifyListeners);
    node.widthLeft.addListener(notifyListeners);
    node.widthRight.addListener(notifyListeners);

    if ((index > 0 && index < spline.nodes.length) || (spline.isClosed && index == spline.nodes.length)) {
      final prevIdx = index - 1;
      final nextIdx = index == spline.nodes.length ? 0 : index;

      final prevNode = spline.nodes[prevIdx];
      final nextNode = spline.nodes[nextIdx];

      node.widthLeft.value = prevNode.widthLeft.value * (1.0 - t) + nextNode.widthLeft.value * t;
      node.widthRight.value = prevNode.widthRight.value * (1.0 - t) + nextNode.widthRight.value * t;

      bool hasPulley = prevNode.cornerRadius.value > 0.01 || prevNode.miterSize.value > 0.01 ||
                       nextNode.cornerRadius.value > 0.01 || nextNode.miterSize.value > 0.01;

      if (exactPos != null && hasPulley) {
        // If a pulley abstracts the corner, bypass baking handles
        p.x.value = exactPos.dx;
        p.y.value = exactPos.dy;
      } else {
        // Perform a standard raw de Casteljau split to preserve explicit curve geometry
        final controls = spline.getEvaluatedControls();
        final hOut = controls[prevIdx].$1;
        final hIn = controls[nextIdx].$2;

        final p0 = Offset(prevNode.point.x.value, prevNode.point.y.value);
        final p3 = Offset(nextNode.point.x.value, nextNode.point.y.value);

        final p1 = p0 + hOut;
        final p2 = p3 + hIn;

        final m0 = Offset.lerp(p0, p1, t)!;
        final m1 = Offset.lerp(p1, p2, t)!;
        final m2 = Offset.lerp(p2, p3, t)!;
        final r0 = Offset.lerp(m0, m1, t)!;
        final r1 = Offset.lerp(m1, m2, t)!;
        final bPt = Offset.lerp(r0, r1, t)!;

        p.x.value = exactPos?.dx ?? bPt.dx;
        p.y.value = exactPos?.dy ?? bPt.dy;

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
    }

    if (index >= spline.nodes.length) {
      spline.nodes.add(node);
    } else {
      spline.nodes.insert(index, node);
    }

    // COHESION EDGE: bind the spliced point to the spline's ANCHOR only -- never
    // to another editable vertex.
    //
    // THE BUG THIS FIXES ("a vertex suddenly locks to 1 or 3 other vertices"):
    // this used to be `spline.nodes.first.point.attach(p)`, which made the
    // spline's FIRST NODE a PARENT of every point ever spliced in. CompassPoint
    // .moveBy cascades down attachedPoints, and the ordinary single-vertex drag
    // path (isPanningSelectedPoints) uses moveBy -- so grabbing that one first
    // vertex silently dragged along every spliced point with it (one child if you
    // added one point, three if you added three). It only surfaced when you
    // happened to grab the ORIGINAL first vertex rather than a freshly-added leaf,
    // which is why it felt random and "once per session." Pen-drawn nodes get no
    // attach edge at all, so it was specifically a splicing artifact.
    //
    // WHY THE ANCHOR IS THE RIGHT PARENT: the anchor is a non-vertex move handle
    // (centroid pivot), not a draggable curve point, so no ordinary vertex drag
    // ever cascades through it. Anchored splines (circle/rect converts, baked
    // layers) still move cohesively on Shift-drag and anchor-drag, and spliced
    // points now ride the anchor exactly like the shape's original nodes -- which
    // also means the fillet's _gcPointHardIfUnused detaches cleanly (the stale
    // "first node -> spliced point" edge it used to fight no longer exists).
    //
    // WHY ANCHORLESS PEN SPLINES LOSE NOTHING: they simply get no cohesion edge,
    // so each vertex drags independently (the correct behavior). Rigid-body
    // Shift-drag / Shift+R still gather the whole spline via SHAPE MEMBERSHIP in
    // CanvasGeometry.getRigidBody(hierarchy: true) -- that traversal walks shape
    // node lists, and never needed this attach edge.
    //
    // NOTE ON OLD FILES: existing .compass saves already contain the old
    // first-node ATTACH edges and will replay them on load, so re-saving an old
    // file is the clean cure for pre-existing documents. New edits are correct
    // immediately.
    final anchor = spline.anchorPoint;
    if (anchor != null && anchor != p) {
      anchor.attach(p);
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

  // ===========================================================================
  // SHARP VERTEX TOGGLE (S key)
  // ===========================================================================

  /// True when a spline node is already "sharp" in the S-key sense: zero
  /// tension and no explicit Bézier handles. With tension 0 the Catmull-Rom
  /// evaluated controls collapse to zero-length tangents, so the curve enters
  /// and leaves the vertex as straight chords -- the sharpest a corner can be.
  /// Exposed as a static so the renderer/panels can badge sharp nodes later
  /// without re-deriving the rule.
  static bool isNodeSharp(CompassSplineNode node) {
    return node.tension.value < 0.01 &&
        node.handleIn == null &&
        node.handleOut == null;
  }

  /// S-key action: toggles the sharp state of every X-Spline vertex whose point
  /// is in [targets]. One snapshot, one notify, for the whole batch.
  ///
  /// FLUID -> SHARP: tension = 0.0, explicit handles wiped, and any corner
  /// pulley cleared (a round or miter pulley is a live constraint that REPLACES
  /// the corner with a wrap -- contradictory with "as sharp as possible", so S
  /// dissolves it; this also makes S a handy one-tap pulley remover). Width
  /// profile and pins are untouched: sharpness is about the centerline's
  /// tangent, not the ribbon.
  ///
  /// SHARP -> FLUID: tension restored to 1.0 (the standard fluid Catmull-Rom
  /// state). Handles stay null so the vertex re-enters fluid mode cleanly
  /// rather than resurrecting stale explicit geometry.
  ///
  /// MIXED BATCHES: if ANY targeted node is currently fluid, the whole batch is
  /// sharpened; only when EVERY targeted node is already sharp does the batch
  /// flip back to fluid. This matches how multi-select toggles usually behave
  /// (Blender's own shade-smooth/flat included): "make these sharp" shouldn't
  /// un-sharpen the ones that already were.
  ///
  /// Points that belong to no spline node (mesh nodes, circle centers, anchors,
  /// loose points) are simply ignored, so a mixed selection is safe. Locked
  /// layers are skipped, mirroring every other vertex-editing action.
  void toggleSharpVertices(Iterable<CompassPoint> targets) {
    final targetSet = targets.toSet();
    if (targetSet.isEmpty) return;

    // Pass 1: collect every targeted spline node (skipping locked layers) and
    // decide the batch direction.
    final hitNodes = <CompassSplineNode>[];
    bool anyFluid = false;

    for (var layer in layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is! CompassXSpline) continue;
        for (var node in shape.nodes) {
          if (!targetSet.contains(node.point)) continue;
          hitNodes.add(node);
          if (!isNodeSharp(node)) anyFluid = true;
        }
      }
    }

    if (hitNodes.isEmpty) return;

    bool changed = false;

    if (anyFluid) {
      // Sharpen the whole batch.
      for (var node in hitNodes) {
        if (isNodeSharp(node) &&
            node.cornerRadius.value < 0.01 &&
            node.miterSize.value < 0.01) {
          continue; // already fully sharp, nothing to do
        }
        node.tension.value = 0.0;
        node.handleIn = null;
        node.handleOut = null;
        // A pulley wraps the corner -- the opposite of sharp. Clear both kinds.
        if (node.cornerRadius.value > 0.0) node.cornerRadius.value = 0.0;
        if (node.miterSize.value > 0.0) node.miterSize.value = 0.0;
        changed = true;
      }
    } else {
      // Every node already sharp: restore the batch to fluid.
      for (var node in hitNodes) {
        node.tension.value = 1.0;
        changed = true;
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

    // Hard GC: the fillet REPLACED this corner, so the point must go even if a
    // past Q-splice left a cohesion attach edge on it (which the soft
    // checkAndGCPoint reads as a reason to keep it, stranding the old corner
    // on the canvas). Shared/structural points still survive -- see the guard
    // inside _gcPointHardIfUnused.
    _gcPointHardIfUnused(node.point);

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

  /// Single-point deletion: a thin delegate onto the batch primitive so the two
  /// paths can never drift. All semantics live in removePoints.
  void removePoint(CompassPoint p) {
    removePoints([p]);
  }

  /// Batch point deletion -- THE deletion primitive. One shape sweep against the
  /// whole target set, one constraint sweep, one combined GC batch, one selection
  /// prune, ONE undo snapshot, one notify.
  ///
  /// Exists because the Delete-key handler used to loop removePoint over the
  /// selection: N points deleted minted N undo states (Ctrl+Z resurrected them
  /// one at a time and large deletes flushed the 50-deep stack), and cascade
  /// deletions (a shape destroyed by point A dragging its other SELECTED points
  /// down with it) made later iterations run full no-op removals -- shape scan,
  /// constraint sweep, another snapshot -- against already-dead points.
  ///
  /// Shape-death rules, matching the old removePoint exactly, applied per shape
  /// against the whole set:
  ///   * line / circle / spiral / rectangle: dies if ANY defining
  ///     point is a target.
  ///   * mesh: dies if ANY grid node or its anchor is a target (whole-mesh
  ///     death, as before).
  ///   * xspline: target nodes are removed from the spline; the spline dies if
  ///     fewer than 2 nodes remain. NEW (deliberate fix): the spline also dies
  ///     if its ANCHOR is a target -- previously the anchor fell through this
  ///     sweep entirely, so the point was force-removed from the pool while the
  ///     spline kept referencing it: a dangling rotation pivot carrying ghost
  ///     attach edges on a dead object, self-healing only on save/reload. This
  ///     mirrors what the mesh case has always done with its anchor.
  ///
  /// GRADIENT STOPS are NOT shape geometry: a targeted stop point never kills a
  /// shape. Before the sweep we strip targeted stops from every gradient (and
  /// null a gradient emptied of its last stop). The stop points themselves are in
  /// [targets] and get force-removed by the normal pool sweep below, with their
  /// cohesion edges stripped -- so deleting a selected stop dot cleanly removes
  /// that stop without touching the shape.
  void removePoints(Iterable<CompassPoint> targetsIn) {
    // Ignore points already gone (double-delete, cascade leftovers, stale UI).
    final targets = targetsIn.where(points.contains).toSet();
    if (targets.isEmpty) return;

    // Sever gradient stops FIRST, so the force-remove below leaves no dangling
    // stop reference. (The stop points remain in `targets` and are dropped by
    // the normal pool + edge sweep; this only detaches the gradient's link.)
    _detachGradientStopsInTargets(targets);

    // Points of shapes destroyed as a SIDE EFFECT (a dead line's other endpoint,
    // a collapsed spline's surviving nodes + anchor) -- collected and batch-GC'd
    // below instead of left floating in the pool.
    final orphanCandidates = <CompassPoint>{};
    final deadShapes = <CompassShape>[];

    for (var layer in layers) {
      layer.shapes.removeWhere((shape) {
        bool remove = false;
        if (shape is CompassLine) {
          remove = targets.contains(shape.start) || targets.contains(shape.end);
        } else if (shape is CompassCircle) {
          remove = targets.contains(shape.center) ||
              (shape.radiusPoint != null && targets.contains(shape.radiusPoint));
        } else if (shape is CompassSpiral) {
          remove = targets.contains(shape.center) || targets.contains(shape.startPoint);
        } else if (shape is CompassRectangle) {
          remove = targets.contains(shape.p1) || targets.contains(shape.p2);
        } else if (shape is CompassImage) {
          remove = targets.contains(shape.origin) ||
              targets.contains(shape.xHandle) ||
              targets.contains(shape.yHandle);
        } else if (shape is CompassMesh) {
          // Whole-mesh death on any node/anchor hit (was a removeShape delegate
          // in the old removePoint; now handled uniformly in this sweep).
          remove = (shape.anchorPoint != null && targets.contains(shape.anchorPoint)) ||
              shape.nodes.any((n) => targets.contains(n.point));
        } else if (shape is CompassXSpline) {
          if (shape.anchorPoint != null && targets.contains(shape.anchorPoint)) {
            // Anchor death is fatal (see doc comment above).
            remove = true;
          } else {
            shape.nodes.removeWhere((n) => targets.contains(n.point));
            if (shape.nodes.length < 2) {
              if (shape.anchorPoint != null) {
                for (var n in shape.nodes) shape.anchorPoint!.detach(n.point);
              }
              remove = true;
            }
          }
        }

        if (remove) {
          if (shape is CompassImage) shape.image?.dispose();
          deadShapes.add(shape);
          orphanCandidates.addAll(_pointsOfShape(shape));
        }
        return remove;
      });
    }

    // Riders of constraints hosted by dead shapes are GC candidates too,
    // exactly as in removeShape.
    for (var c in constraints) {
      for (var s in deadShapes) {
        if (_constraintHasShape(c, s)) {
          final rider = _constraintRider(c);
          if (rider != null) orphanCandidates.add(rider);
          break;
        }
      }
    }

    if (_selectedShape != null && deadShapes.contains(_selectedShape)) {
      _selectedShape = null;
    }

    // Force-remove every target from the pool and strip attach edges pointing
    // at them from every survivor.
    for (final p in targets) {
      points.remove(p);
    }
    for (var remainingPoint in points) {
      remainingPoint.attachedPoints.removeWhere(targets.contains);
    }

    // ONE unbind-aware constraint sweep for the whole batch: anything hosted by
    // a dead shape OR touching a deleted point must stop listening, not just
    // leave the list.
    _removeConstraintsWhere((c) =>
        deadShapes.any((s) => _constraintHasShape(c, s)) ||
        targets.any((p) => _constraintHasPoint(c, p)));

    // Batch-GC the side-effect orphans. The targets are already force-removed
    // and included in the batch so edges among the dead group can't block each
    // other (anchor -> nodes, center -> satellites, spliced cohesion links).
    orphanCandidates.removeWhere(targets.contains);
    if (orphanCandidates.isNotEmpty) {
      final batch = {...orphanCandidates, ...targets};
      for (var candidate in orphanCandidates) {
        checkAndGCPoint(candidate, batch: batch);
      }
    }

    _pruneSelection();

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
    // DistanceRadius carries no shape reference -- match by the radius notifier's
    // identity, which is unique per circle. Without this, deleting a circle whose
    // center survives (shared point) left the constraint alive, forever updating
    // a dead notifier.
    if (c is DistanceRadiusConstraint) {
      return shape is CompassCircle && identical(c.targetRadius, shape.radius);
    }
    if (c is SquareConstraint) return c.rect == shape;
    return false;
  }

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
    if (c is DistanceRadiusConstraint) {
      return c.p1 == p || c.p2 == p;
    }
    if (c is SquareConstraint) {
      return c.rect.p1 == p || c.rect.p2 == p;
    }
    if (c is ParallelogramConstraint) {
      return c.p1 == p || c.p2 == p || c.p3 == p || c.p4 == p;
    }
    return false;
  }

  void finalizePointDrag() {
    saveSnapshot();
    // Drag-quality spline outlines are intentionally coarse while any point is
    // flagged as active. The gesture handler clears those flags immediately
    // before finalizing, so schedule one exact final repaint here.
    notifyListeners();
  }

  String toProjectData() {
    return ProjectSerializer.serialize(this);
  }

  void loadProjectData(String data) {
    for (final layer in layers) {
      for (final shape in layer.shapes) {
        if (shape is CompassImage) shape.image?.dispose();
      }
    }

    // A load (file open OR undo) replaces the entire point pool; anything still
    // selected is a dead object from the previous world. Clear before load so no
    // interaction can touch stale points mid-rebuild, and prune after in case a
    // listener repopulated anything.
    selectedPoints.clear();
    ProjectSerializer.deserialize(this, data, notifyListeners);
    _pruneSelection();
  }

  String toSVG() {
    return SVGExporter.toSVG(this);
  }

  Future<Uint8List?> toPNG({
    double scale = 2.0,
    PngExportStyle style = PngExportStyle.standard,
    bool grayscale = false,
    double bubbleSize = 8.0,
  }) {
    return PNGExporter.toPNG(
      this,
      scale: scale,
      style: style,
      grayscale: grayscale,
      bubbleSize: bubbleSize,
    );
  }

  String toOBJ(
    CompassLayer layer, {
    double samplingSpacing = 2.0,
    bool gridMode = false,
    int gridCount = 48,
    bool delaunayMode = false,
    double delaunaySpacing = 25.0,
    bool skeletonMode = false,
    double skeletonLambda = 20.0,
  }) {
    return OBJExporter.toOBJ(
      layer,
      samplingSpacing: samplingSpacing,
      gridMode: gridMode,
      gridCount: gridCount,
      delaunayMode: delaunayMode,
      delaunaySpacing: delaunaySpacing,
      skeletonMode: skeletonMode,
      skeletonLambda: skeletonLambda,
    );
  }
  
  OBJTextureExport toTexturedOBJ(
    CompassLayer layer,
    CompassImage image, {
    required String materialLibraryFileName,
    required String textureFileName,
    double samplingSpacing = 2.0,
    bool gridMode = false,
    int gridCount = 48,
    bool delaunayMode = false,
    double delaunaySpacing = 25.0,
    bool skeletonMode = false,
  }) {
    return OBJExporter.toTexturedOBJ(
      layer,
      image,
      materialLibraryFileName: materialLibraryFileName,
      textureFileName: textureFileName,
      samplingSpacing: samplingSpacing,
      gridMode: gridMode,
      gridCount: gridCount,
      delaunayMode: delaunayMode,
      delaunaySpacing: delaunaySpacing,
      skeletonMode: skeletonMode,
    );
  }

  Future<String?> toASCII({int columns = 100, bool invert = false, bool dither = false}) {
    return ASCIIExporter.toASCII(this, columns: columns, invert: invert, dither: dither);
  }
}