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

  // --- NEW: Toggle to show vertex indices (0, 1, 2...) on the canvas ---
  bool showNodeIndices = false;

  CompassEngine() {
    addLayer('Layer 1');
    _saveSnapshot(); 
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
    }
    _saveSnapshot();
    notifyListeners();
  }

  void applyTaperToSpline(CompassXSpline spline, double startWidth, double endWidth) {
    final int n = spline.nodes.length;
    if (n == 0) return;

    if (n == 1) {
      spline.nodes[0].widthLeft.value = startWidth;
      spline.nodes[0].widthRight.value = startWidth;
    } else {
      for (int i = 0; i < n; i++) {
        // Calculate parametric 't' (0.0 at start, 1.0 at end)
        double t = i / (n - 1);
        double currentWidth = startWidth + (endWidth - startWidth) * t;
        
        spline.nodes[i].widthLeft.value = currentWidth;
        spline.nodes[i].widthRight.value = currentWidth;
      }
    }
    _saveSnapshot();
    notifyListeners();
  }

  void _saveSnapshot() {
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
      
      _saveSnapshot();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load reference image: $e');
    }
  }

  void removeReferenceLayer() {
    referenceLayer = null;
    _saveSnapshot();
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
    _saveSnapshot();
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

    _saveSnapshot();
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
    
    _saveSnapshot();
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
      // A deleted shape can no longer host a PointOn* constraint. Drop any whose
      // host IS this shape, so a dead constraint isn't left firing moveBy on its
      // rider every time unrelated geometry moves -- and isn't serialized into the
      // immediate post-delete snapshot only to be skipped on the way back in. The
      // rider point itself is not one of this shape's structural points, so it is
      // untouched by the GC below and simply becomes a free point.
      constraints.removeWhere((c) => _constraintHasShape(c, shape));

      // This shape's structural points are deleted together as one batch. The
      // attachment links the shape created among them (e.g. a circle's
      // center.attach(radiusPoint)) must NOT keep each other alive, or every point
      // survives as a floating orphan. Passing the batch tells the GC to treat
      // intra-batch links as dead weight and collect on out-of-batch links only.
      final batch = shapePoints.toSet();
      for (var p in shapePoints) {
        _checkAndGCPoint(p, batch: batch);
      }
      
      _saveSnapshot();
      notifyListeners();
    }
  }

  // Garbage-collects a point that may no longer be needed, aware of a deletion
  // *batch* -- the set of points being removed together as a single shape.
  //
  // The earlier version weighed attachment links against ALL points, which let a
  // shape's own points keep each other alive: a circle creates center.attach(
  // radiusPoint), so center "has a child" (radiusPoint) while radiusPoint "is a
  // child" (of center). Neither side ever cleared the other, so both leaked as
  // floating orphans on delete. Spirals (center/startPoint) and converted splines
  // (anchor/nodes) leak by the identical mechanism.
  //
  // Fix: links *inside* the batch don't count as dependencies. Only a link to a
  // point OUTSIDE the batch -- a constraint point riding this geometry, or a
  // rigidly-linked partner shape -- protects a point from collection. Callers that
  // GC a single stray point (circle/rectangle -> spline conversions, fillet corner
  // cleanup) pass no batch, so the default {p} reproduces the original behavior
  // exactly for them.
  void _checkAndGCPoint(CompassPoint p, {Set<CompassPoint>? batch}) {
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
        
        if (isUsed) break;
      }
      if (isUsed) break;
    }

    if (isUsed) return;

    // (B) Still bound -- as parent or as child -- to a point OUTSIDE the batch?
    bool hasExternalDependency = false;

    // p is the parent of a child that lives beyond this deletion batch.
    for (var child in p.attachedPoints) {
      if (!deletionBatch.contains(child)) {
        hasExternalDependency = true;
        break;
      }
    }

    // p is the child of a surviving parent that lives beyond this deletion batch.
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
      // A truly collected point can't anchor a constraint as rider OR as a host
      // vertex. removeShape usually clears the host case first, but this also covers
      // a rider collected as an orphan (e.g. via fillet corner cleanup), so no dead
      // constraint is left pointing at a point that no longer exists.
      constraints.removeWhere((c) => _constraintHasPoint(c, p));
    }
  }

  void convertCircleToSpline(CompassCircle circle) {
    CompassLayer? targetLayer;
    int shapeIndex = -1;
    for (var layer in layers) {
      shapeIndex = layer.shapes.indexOf(circle);
      if (shapeIndex != -1) {
        targetLayer = layer;
        break;
      }
    }
    
    if (targetLayer == null) return;

    final spline = CompassXSpline(isClosed: true, anchorPoint: circle.center)
      ..operation = circle.operation
      ..isVisible = circle.isVisible;

    final cx = circle.center.x.value;
    final cy = circle.center.y.value;
    final r = circle.radius.value;

    const int numNodes = 8;
    const double circleTension = 1.124; 

    for (int i = 0; i < numNodes; i++) {
      final angle = (i * 2 * pi) / numNodes;
      final px = cx + r * cos(angle);
      final py = cy + r * sin(angle);
      
      final p = CompassPoint(x: px, y: py);
      points.add(p);
      p.x.addListener(notifyListeners);
      p.y.addListener(notifyListeners);
      
      circle.center.attach(p);

      final node = CompassSplineNode(point: p, tension: circleTension);
      node.tension.addListener(notifyListeners);
      spline.addNode(node);
    }

    targetLayer.shapes[shapeIndex] = spline;
    
    if (_selectedShape == circle) {
      _selectedShape = spline;
    }

    if (circle.radiusPoint != null) {
      circle.center.detach(circle.radiusPoint!);
      _checkAndGCPoint(circle.radiusPoint!);
    }

    _saveSnapshot();
    notifyListeners();
  }

  // --- Convert Rectangle to Spline (exact circular-arc corners) ---
  void convertRectangleToSpline(CompassRectangle rect) {
    CompassLayer? targetLayer;
    int shapeIndex = -1;
    for (var layer in layers) {
      shapeIndex = layer.shapes.indexOf(rect);
      if (shapeIndex != -1) {
        targetLayer = layer;
        break;
      }
    }
    
    if (targetLayer == null) return;

    final cx = (rect.p1.x.value + rect.p2.x.value) / 2;
    final cy = (rect.p1.y.value + rect.p2.y.value) / 2;
    final anchor = CompassPoint(x: cx, y: cy);
    points.add(anchor);
    anchor.x.addListener(notifyListeners);
    anchor.y.addListener(notifyListeners);

    final spline = CompassXSpline(isClosed: true, anchorPoint: anchor)
      ..operation = rect.operation
      ..isVisible = rect.isVisible;

    final left = min(rect.p1.x.value, rect.p2.x.value);
    final right = max(rect.p1.x.value, rect.p2.x.value);
    final top = min(rect.p1.y.value, rect.p2.y.value);
    final bottom = max(rect.p1.y.value, rect.p2.y.value);
    
    final width = right - left;
    final height = bottom - top;
    final maxR = min(width / 2, height / 2);
    final r = rect.cornerRadius.value.clamp(0.0, maxR);

    void addNodeAt(Offset pos, {required double tension, Offset? handleIn, Offset? handleOut}) {
      final p = CompassPoint(x: pos.dx, y: pos.dy);
      points.add(p);
      p.x.addListener(notifyListeners);
      p.y.addListener(notifyListeners);
      anchor.attach(p);

      final node = CompassSplineNode(point: p, tension: tension, handleIn: handleIn, handleOut: handleOut);
      node.tension.addListener(notifyListeners);
      spline.addNode(node);
    }

    if (r <= 0.1) {
      final corners = [
        Offset(left, top),
        Offset(right, top),
        Offset(right, bottom),
        Offset(left, bottom),
      ];
      for (final c in corners) {
        addNodeAt(c, tension: 0.0);
      }
    } else {
      final k = 0.5522847498307936 * r; 

      final spec = <(Offset, Offset)>[
        (Offset(left + r, top),     Offset(k, 0)),   
        (Offset(right - r, top),    Offset(k, 0)),   
        (Offset(right, top + r),    Offset(0, k)),   
        (Offset(right, bottom - r), Offset(0, k)),   
        (Offset(right - r, bottom), Offset(-k, 0)),  
        (Offset(left + r, bottom),  Offset(-k, 0)),  
        (Offset(left, bottom - r),  Offset(0, -k)),  
        (Offset(left, top + r),     Offset(0, -k)),  
      ];

      for (final (pos, hOut) in spec) {
        // Because the corner arcs are perfectly symmetric, HandleIn is always -HandleOut
        addNodeAt(pos, tension: 1.0, handleOut: hOut, handleIn: Offset(-hOut.dx, -hOut.dy));
      }
    }

    targetLayer.shapes[shapeIndex] = spline;
    
    if (_selectedShape == rect) {
      _selectedShape = spline;
    }

    _checkAndGCPoint(rect.p1);
    _checkAndGCPoint(rect.p2);

    _saveSnapshot();
    notifyListeners();
  }

  // --- Bake a layer's boolean result into editable Bézier X-Splines ---
  //
  // Flattens the layer's combined boolean Path (the same master path the renderer
  // and exporters draw) into editable geometry, drops it into a fresh layer
  // directly above the source, then hides the source. Non-destructive: the source
  // layer and all its points stay intact, just invisible -- toggle it back on any
  // time.
  //
  // The combined Path is opaque (dart:ui won't hand back its curves), so PathBaker
  // samples the outline and reconstructs cubic Béziers -- see path_baker.dart. It
  // returns one BakedContour per contour, depth-sorted ascending and tagged isHole
  // by even-odd nesting. We emit one CompassXSpline per contour, outer contours as
  // Union and holes as Subtract, appended in the returned order so the boolean
  // engine on the NEW layer reproduces the identical silhouette: outers union
  // first, then holes cut, then any re-fill island unions back.
  //
  // All contours share ONE anchor at the overall centroid, with every node point
  // attached to it. That is what lets a multi-contour bake (e.g. an annulus: outer
  // ring + hole) still translate under Shift-drag and rotate under Shift+R as a
  // single rigid body, instead of the hole sliding out of its ring. Individual
  // node editing is unaffected -- a plain drag moves only the grabbed point, since
  // the anchor is each node's PARENT, not its child. The shared anchor is correctly
  // reference-counted by _checkAndGCPoint: deleting one baked spline keeps the
  // anchor alive while a sibling spline still references it.
  //
  // Baked handles arrive already in raw cubic (tension-1.0) space, so each node is
  // created at tension 1.0 -- getEvaluatedControls multiplies explicit handles by
  // tension, and 1.0 passes them through untouched, reproducing the fit exactly.
  //
  // The new layer inherits the source's fill/stroke/width so the bake looks
  // identical to what it replaced. No-op if the layer has no fillable area (only
  // strokes, `none`/construction shapes, or hidden shapes contribute nothing).
  void bakeLayer(CompassLayer layer) {
    final int srcIndex = layers.indexOf(layer);
    if (srcIndex == -1) return;

    final masterPath = layer.getLayerPath();
    final contours = PathBaker.bake(masterPath);
    if (contours.isEmpty) return;

    // Overall centroid across every contour's vertices -> shared rigid-body anchor.
    double sx = 0, sy = 0;
    int count = 0;
    for (final c in contours) {
      for (final n in c.nodes) {
        sx += n.point.dx;
        sy += n.point.dy;
        count++;
      }
    }
    final anchor = CompassPoint(x: sx / count, y: sy / count);
    points.add(anchor);
    anchor.x.addListener(notifyListeners);
    anchor.y.addListener(notifyListeners);

    final baked = CompassLayer(
      name: '${layer.name} (Baked)',
      color: layer.color,
      strokeColor: layer.strokeColor,
      strokeWidth: layer.strokeWidth,
    );

    for (final contour in contours) {
      final spline = CompassXSpline(isClosed: contour.isClosed, anchorPoint: anchor)
        ..operation = contour.isHole ? CompassBooleanOp.subtract : CompassBooleanOp.add
        ..isVisible = true;

      for (final bn in contour.nodes) {
        final p = CompassPoint(x: bn.point.dx, y: bn.point.dy);
        points.add(p);
        p.x.addListener(notifyListeners);
        p.y.addListener(notifyListeners);
        anchor.attach(p);

        final node = CompassSplineNode(
          point: p,
          tension: 1.0,
          handleIn: bn.handleIn,
          handleOut: bn.handleOut,
        );
        node.tension.addListener(notifyListeners);
        spline.addNode(node);
      }

      baked.shapes.add(spline);
    }

    // Drop the baked layer directly above the source, hide the source, focus it.
    layers.insert(srcIndex + 1, baked);
    layer.isVisible = false;
    activeLayer = baked;
    baked.isExpanded = true;
    _selectedShape = null;

    _saveSnapshot();
    notifyListeners();
  }
  
  void toggleShapeVisibility(CompassShape shape) {
    shape.isVisible = !shape.isVisible;
    if (!shape.isVisible && _selectedShape == shape) {
      _selectedShape = null; // Deselect if hidden
    }
    _saveSnapshot();
    notifyListeners();
  }

  void updateSpiral(CompassSpiral spiral, {bool? isClockwise, double? revolutions}) {
    if (isClockwise != null) spiral.isClockwise = isClockwise;
    if (revolutions != null) spiral.revolutions = revolutions;
    _saveSnapshot();
    notifyListeners();
  }

  void updateRectangleRadius(CompassRectangle rect, double radius) {
    rect.cornerRadius.value = radius;
    _saveSnapshot();
    notifyListeners();
  }

  void toggleRectangleSquare(CompassRectangle rect, bool isSquare) {
    rect.isSquare = isSquare;
    if (isSquare) {
      rect.p2.moveBy(0, 0); 
    }
    _saveSnapshot();
    notifyListeners();
  }

  void changeShapeOperation(CompassShape shape, CompassBooleanOp op) {
    shape.operation = op;
    _saveSnapshot();
    notifyListeners();
  }

  void changeLayerColor(CompassLayer layer, Color newColor) {
    layer.color = newColor;
    _saveSnapshot();
    notifyListeners();
  }

  void changeLayerStrokeColor(CompassLayer layer, Color newColor) {
    layer.strokeColor = newColor;
    _saveSnapshot();
    notifyListeners();
  }

  void changeLayerStrokeWidth(CompassLayer layer, double width) {
    layer.strokeWidth = width;
    _saveSnapshot();
    notifyListeners();
  }

  // --- SPLINE SPECIFIC ENGINE ACTIONS ---

  // Cursor-driven node insertion: figures out which segment the dropped point is
  // nearest to (chord distance), then splits that segment at the cursor's projected
  // parameter. Public entry point for the Add-Point tool and rectangle->spline
  // conversion, both of which hand us a pre-created point already added to `points`
  // and sitting at the cursor.
  void insertPointIntoSpline(CompassPoint p, CompassXSpline spline) {
    final tap = Offset(p.x.value, p.y.value);
    final details = spline.getInsertDetailsForOffset(tap);
    _spliceNodeIntoSpline(spline, p, details.$1, details.$2);

    _saveSnapshot();
    notifyListeners();
  }

  // Midpoint (or arbitrary-t) subdivision of a single segment, used by the
  // Shift-hover "add resolution" interaction. `segmentIndex` addresses the segment
  // between node[segmentIndex] and node[segmentIndex+1] (wrapping for closed
  // splines). The new vertex is created and snapped exactly onto the existing curve
  // at parameter `t`, so the silhouette never moves -- we only raise the node count.
  // Returns the freshly created point, or null if the segment index was invalid.
  //
  // `t` defaults to 0.5 (parametric center). Pass the cursor's projected parameter
  // here instead if you ever want "insert exactly where I'm pointing" semantics --
  // nothing else in this method changes.
  CompassPoint? subdivideSplineSegment(CompassXSpline spline, int segmentIndex, {double t = 0.5}) {
    final int n = spline.nodes.length;
    if (n < 2) return null;

    final int segCount = spline.isClosed ? n : n - 1;
    if (segmentIndex < 0 || segmentIndex >= segCount) return null;

    // Translate the segment index into the splice index used by the core routine:
    // the new node lands at segmentIndex + 1, except the closing segment of a closed
    // spline (node[n-1] -> node[0]), which appends at the very end of the list.
    int index = segmentIndex + 1;
    if (spline.isClosed && segmentIndex == n - 1) index = n;

    // Seed at the chord midpoint; _spliceNodeIntoSpline overwrites this with the
    // exact on-curve split point before anyone repaints.
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

    _saveSnapshot();
    notifyListeners();
    return p;
  }

  // Shared De Casteljau splice. Splits the segment terminating at `index` (between
  // node[index-1] and node[index], wrapping to node[0] when index == nodes.length on
  // a closed spline) at parameter `t`, bakes the neighbor tangents into explicit
  // handles so the curve is preserved exactly, snaps `p` onto the curve, and splices
  // in a new node carrying the asymmetric child handles. The CALLER owns adding `p`
  // to `points` and journaling the undo snapshot -- so both insertion entry points
  // stay byte-for-byte identical in their math while differing only in how they
  // choose the split parameter.
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

      // Safely divide by tension to prevent double-scaling when saving back to explicit fields.
      // (Because getEvaluatedControls() already applies the tension multiplier).
      Offset safeDivide(Offset v, double tension) {
        return tension > 0.001 ? Offset(v.dx / tension, v.dy / tension) : Offset.zero;
      }

      // Solidify and truncate neighbor handles (baking Catmull-Rom into Explicit if needed)
      prevNode.handleIn ??= safeDivide(controls[prevIdx].$2, prevNode.tension.value);
      prevNode.handleOut = safeDivide(m0 - p0, prevNode.tension.value);

      nextNode.handleOut ??= safeDivide(controls[nextIdx].$1, nextNode.tension.value);
      nextNode.handleIn = safeDivide(m2 - p3, nextNode.tension.value);

      // Assign the new asymmetric handles to the inserted node
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
    _saveSnapshot();
    notifyListeners();
  }

  // Escape hatch: clears explicit baked Bezier handles, restoring standard Catmull-Rom math.
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
      _saveSnapshot();
      notifyListeners();
    }
  }

  // Forward of resetPointHandles: freezes a node's current fluid Catmull-Rom
  // tangent into explicit, independently-editable Bezier handles. Reads the live
  // evaluated control offsets (which already include the tension multiplier) and
  // divides the tension back out before storing, so re-evaluation reproduces the
  // identical curve -- zero visual jump at the moment of conversion. Only acts on
  // nodes whose handles are still null (already-baked nodes are left untouched).
  void convertPointToBezier(CompassPoint p) {
    bool changed = false;
    for (var layer in layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is CompassXSpline) {
          // Snapshot evaluated controls ONCE per spline before mutating any node,
          // so every node in this spline bakes from the same coherent tangent field.
          List<(Offset, Offset)>? controls;
          for (int i = 0; i < shape.nodes.length; i++) {
            final node = shape.nodes[i];
            if (node.point != p) continue;
            if (node.handleIn != null || node.handleOut != null) continue;

            controls ??= shape.getEvaluatedControls();
            final t = node.tension.value;
            final hOut = controls[i].$1;
            final hIn = controls[i].$2;

            // Strip the tension multiplier so getEvaluatedControls re-applies it
            // to the exact same effective vector. Guard the near-zero case.
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
      _saveSnapshot();
      notifyListeners();
    }
  }

  // Option B commit: the instant a handle is grabbed for direct editing, fold the
  // node's tension multiplier into the stored handle vectors and pin tension to
  // 1.0. From then on the node is pure explicit Bezier -- the on-screen handle dot
  // sits exactly at point + handle, so subsequent drag deltas map 1:1 with no
  // divide-by-tension fragility, and the tension slider no longer affects it.
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

  // Per-drag-tick setter for one handle of a node. Stores the raw vector directly
  // (the node is already committed to tension 1.0 via commitNodeToBezierEdit, so no
  // tension division is needed) and repaints. The undo snapshot is deferred to drag
  // release through finalizePointDrag, matching how point drags are journaled.
  void updateNodeHandle(CompassSplineNode node, bool isOut, Offset handle) {
    if (isOut) {
      node.handleOut = handle;
    } else {
      node.handleIn = handle;
    }
    notifyListeners();
  }

  // Applies a parametric geometric fillet (circular arc corner) to a given node in a spline.
  void applyFilletToNode(CompassXSpline spline, CompassSplineNode node, double cutDistance) {
    int index = spline.nodes.indexOf(node);
    if (index == -1) return;

    final fillet = spline.computeFillet(node, cutDistance);
    if (fillet == null) return;

    int prevIndex = (index - 1 + spline.nodes.length) % spline.nodes.length;
    int nextIndex = (index + 1) % spline.nodes.length;
    
    final prevNode = spline.nodes[prevIndex];
    final nextNode = spline.nodes[nextIndex];

    // Safely divide evaluated handles by tension before storing them into explicit nodes.
    Offset safeDivide(Offset v, double tension) {
      return tension > 0.001 ? Offset(v.dx / tension, v.dy / tension) : Offset.zero;
    }

    // 1. Solidify and mutate the PREVIOUS node's outgoing handle
    final controls = spline.getEvaluatedControls();
    if (prevNode.handleIn == null && prevNode.handleOut == null) {
      prevNode.handleIn = safeDivide(controls[prevIndex].$2, prevNode.tension.value);
    }
    prevNode.handleOut = safeDivide(fillet.prevHandleOut, prevNode.tension.value);

    // 2. Solidify and mutate the NEXT node's incoming handle
    if (nextNode.handleIn == null && nextNode.handleOut == null) {
      nextNode.handleOut = safeDivide(controls[nextIndex].$1, nextNode.tension.value);
    }
    nextNode.handleIn = safeDivide(fillet.nextHandleIn, nextNode.tension.value);

    // 3. Create the two new independent points
    final pt1 = CompassPoint(x: fillet.cutPt1.dx, y: fillet.cutPt1.dy);
    final pt2 = CompassPoint(x: fillet.cutPt2.dx, y: fillet.cutPt2.dy);
    
    points.add(pt1);
    pt1.x.addListener(notifyListeners);
    pt1.y.addListener(notifyListeners);

    points.add(pt2);
    pt2.x.addListener(notifyListeners);
    pt2.y.addListener(notifyListeners);

    // Retain anchor connections if they exist
    if (spline.anchorPoint != null) {
      spline.anchorPoint!.attach(pt1);
      spline.anchorPoint!.attach(pt2);
      spline.anchorPoint!.detach(node.point);
    }

    // 4. Create the new fillet nodes mapped into explicit geometry
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

    // 5. Swap the nodes
    spline.nodes.insert(index, newNode1);
    spline.nodes.insert(index + 1, newNode2);
    spline.nodes.remove(node);

    // Automatically clean up the old orphaned corner point 
    // (Unless it's mathematically bound to a circle/line elsewhere!)
    _checkAndGCPoint(node.point);

    _saveSnapshot();
    notifyListeners();
  }

  // --- SMOOTH (Z key) ----------------------------------------------------------
  //
  // Pure function of CAPTURED ORIGINAL STATE + a 0..1 `amount`. The controller
  // captures every selected node's starting position and starting handles ONCE on
  // pan-start, then calls this each drag tick with a fresh `amount` derived from
  // drag distance. Because we always recompute FROM the originals (never from the
  // live, already-smoothed state), holding still doesn't drift and dragging back
  // un-smooths cleanly -- same reversible-within-the-drag contract as the width and
  // handle drags. The caller owns the undo snapshot at drag release
  // (finalizePointDrag); this method only mutates + notifies.
  //
  // Two behaviors, decided PER OWNING SPLINE by how many of that spline's nodes are
  // in the selection:
  //
  //   MANY (>= 2 nodes of one spline selected) -> Laplacian relax, points only.
  //     Each selected interior node moves a fraction `amount` toward the midpoint
  //     of its two neighbors (computed from ORIGINAL positions, so the smudge is a
  //     simultaneous single step, not an order-dependent cascade). Endpoints of an
  //     OPEN spline have a single neighbor and are PINNED -- relaxing them would
  //     just shorten the curve, not smooth it. Explicit handles are left untouched.
  //
  //   ONE (exactly 1 node of a spline selected) -> bake-to-Bezier + align (case b).
  //     The node is converted to explicit handles (same tension-stripping path as
  //     convertPointToBezier), then BOTH handles rotate toward colinear with the
  //     prev->next chord, blended by `amount`. Magnitudes are preserved, so the
  //     curve doesn't collapse; at amount=1 the node is a clean tangent pass-through
  //     aligned to its neighbors. A lone node with no two neighbors (e.g. an open
  //     spline endpoint) has no defined chord, so it is skipped.
  //
  // `originalPositions` and `originalHandles` are keyed by identity. A node absent
  // from the maps (shouldn't happen for a captured selection) is skipped safely.
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

        // Which of THIS spline's nodes are selected (with their indices)?
        final sel = <int>[];
        for (int i = 0; i < n; i++) {
          if (selected.contains(spline.nodes[i].point)) sel.add(i);
        }
        if (sel.isEmpty) continue;

        // Original position of node i, falling back to live if somehow uncaptured.
        Offset origPos(int i) {
          final p = spline.nodes[i].point;
          return originalPositions[p] ?? Offset(p.x.value, p.y.value);
        }

        if (sel.length >= 2) {
          // --- MANY: Laplacian relax toward neighbor midpoint, points only. ---
          for (final i in sel) {
            // Endpoint of an open spline -> pinned (only one neighbor).
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
          // --- ONE: bake to Bezier, rotate handles toward the prev->next chord. ---
          final i = sel.first;

          // A lone open-spline endpoint has no two-sided chord -> nothing to align.
          if (!spline.isClosed && (i == 0 || i == n - 1)) continue;

          final node = spline.nodes[i];

          // Baseline handles: prefer the captured originals; if this node wasn't
          // explicit at capture, bake its fluid tangent now (tension-stripped, so
          // re-evaluation reproduces the same curve) and use that as the baseline.
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

          // Chord direction through the (original) neighbors.
          final prev = origPos((i - 1 + n) % n);
          final next = origPos((i + 1) % n);
          final chord = next - prev;
          final chordLen = chord.distance;
          if (chordLen < 1e-6) continue; // neighbors coincide -> no defined tangent

          final dir = Offset(chord.dx / chordLen, chord.dy / chordLen);

          // handleOut should point ALONG +dir, handleIn along -dir, each keeping its
          // own original magnitude. Rotate from the baseline toward that aligned
          // target by `amount` (slerp-ish via vector lerp + renormalize-to-original-
          // length; good enough and stable for handle visuals).
          Offset alignTo(Offset base, Offset unitTarget) {
            final len = base.distance;
            if (len < 1e-6) return base; // zero handle stays zero
            final aligned = Offset(unitTarget.dx * len, unitTarget.dy * len);
            final blended = Offset.lerp(base, aligned, a)!;
            // Renormalize to the ORIGINAL length so magnitude is preserved across
            // the rotation (pure lerp would shrink the vector mid-arc).
            final bl = blended.distance;
            if (bl < 1e-6) return aligned;
            return Offset(blended.dx / bl * len, blended.dy / bl * len);
          }

          final newOut = alignTo(baseOut, dir);
          final newIn = alignTo(baseIn, Offset(-dir.dx, -dir.dy));

          // Commit the node to explicit tension-1.0 space (mirrors how a handle grab
          // commits), then store the rotated handles directly.
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

  // --- WIDTH SMOOTH (SHIFT + Z key) --------------------------------------------
  //
  // Applies a Laplacian relax specifically to the width properties (widthLeft and
  // widthRight) of the selected nodes. Recomputed from the original widths each tick.
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

        // Which of THIS spline's nodes are selected?
        final sel = <int>[];
        for (int i = 0; i < n; i++) {
          if (selected.contains(spline.nodes[i].point)) sel.add(i);
        }
        if (sel.isEmpty) continue;

        // Fallback to live width if somehow uncaptured
        (double, double) origW(int i) {
          final node = spline.nodes[i];
          return originalWidths[node] ?? (node.widthLeft.value, node.widthRight.value);
        }

        for (final i in sel) {
          // Endpoints of an open spline -> pinned (only one neighbor).
          if (!spline.isClosed && (i == 0 || i == n - 1)) continue;

          final prev = origW((i - 1 + n) % n);
          final next = origW((i + 1) % n);

          // Target is the average of the two neighbors' original widths
          final targetL = (prev.$1 + next.$1) / 2.0;
          final targetR = (prev.$2 + next.$2) / 2.0;

          final startW = origW(i);

          // Standard lerp towards the target
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
    _saveSnapshot();
    notifyListeners();
  }

  void removePoint(CompassPoint p) {
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

    // Deleting a point dissolves any constraint it anchored -- whether as the rider
    // OR as a defining vertex of the host shape. (Deleting a line endpoint also
    // removes the line in the loop above, leaving a point that was riding it now
    // hostless; _constraintHasPoint checks host vertices too, so that case is caught
    // here as well.)
    constraints.removeWhere((c) => _constraintHasPoint(c, p));

    _saveSnapshot();
    notifyListeners();
  }

  void addShape(CompassShape s) {
    if (activeLayer != null) {
      activeLayer!.shapes.add(s);
      _selectedShape = s;
      activeLayer!.isExpanded = true;
      _saveSnapshot();
      notifyListeners();
    }
  }

  // --- CONSTRAINT MANAGEMENT ---------------------------------------------------
  //
  // The canvas controller routes every PointOn* creation through these so the
  // constraint lands in `constraints` the instant it is born. The snapshot in each
  // is load-bearing: it puts the new constraint into the undo stack immediately.
  // Without it, undoing a LATER edit would pop back to a snapshot taken before the
  // constraint existed and silently strip a constraint the user never meant to
  // touch. (The rider point itself was already added + snapshotted via addPoint;
  // this extra snapshot is benign and simply makes a subsequent undo peel the
  // constraint off one step before the point.)

  void addPointOnLine(CompassPoint point, CompassLine line) {
    constraints.add(PointOnLineConstraint(point: point, line: line));
    _saveSnapshot();
    notifyListeners();
  }

  void addPointOnCircle(CompassPoint point, CompassCircle circle) {
    constraints.add(PointOnCircleConstraint(point: point, circle: circle));
    _saveSnapshot();
    notifyListeners();
  }

  void addPointOnSpiral(CompassPoint point, CompassSpiral spiral) {
    constraints.add(PointOnSpiralConstraint(point: point, spiral: spiral));
    _saveSnapshot();
    notifyListeners();
  }

  // True when `shape` is the host of constraint `c` -- used to purge a constraint
  // when its host shape is deleted.
  bool _constraintHasShape(CompassConstraint c, CompassShape shape) {
    if (c is PointOnLineConstraint) return c.line == shape;
    if (c is PointOnCircleConstraint) return c.circle == shape;
    if (c is PointOnSpiralConstraint) return c.spiral == shape;
    return false;
  }

  // True when point `p` participates in constraint `c` -- either as the rider, or
  // as one of the host shape's defining points -- used to purge a constraint when a
  // point is deleted or garbage-collected.
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
    _saveSnapshot();
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

  // Layer-to-object export: serializes ONE layer's resolved boolean fill to a
  // Wavefront .obj mesh, flat on Z=0. Unlike toSVG/toPNG (whole-document), this is
  // scoped to the chosen layer -- the "what a shot turns into" unit. Returns an
  // empty string when the layer has no fillable area, so the caller can report
  // "nothing to export" rather than writing a junk file.
  //
  // [gridMode] false (default) = scanline tessellation (robust, follows the curve,
  //   many thin bands). true = uniform quad grid (clean workable topology, blocky
  //   silhouette at cell resolution). [gridCount] (grid mode only) = number of
  //   cells across the longest bounding-box side; higher = finer + smoother edge.
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