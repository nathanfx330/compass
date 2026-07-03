// /lib/shape_converter.dart

import 'dart:math';
import 'dart:ui';

import 'engine.dart';
import 'constraints.dart'; // <--- NEW: converter must unbind constraints it orphans
import 'models/geometry/point.dart';
import 'models/geometry/shape.dart';
import 'models/geometry/circle.dart';
import 'models/geometry/rectangle.dart';
import 'models/geometry/spline.dart';
import 'models/geometry/mesh.dart'; // <--- NEW: gradient mesh conversion target
import 'models/layer.dart';
import 'path_baker.dart';

class ShapeConverter {
  /// The converters replace shapes IN-PLACE (layer.shapes[i] = newShape) to
  /// preserve Z-order, which means they bypass engine.removeShape -- and with it
  /// the engine's unbind-before-drop constraint cleanup. Any constraint hosted by
  /// the replaced shape must therefore be unbound HERE, or it lives on as a
  /// zombie: still bound to the surviving points' notifiers, still enforcing
  /// against a shape that is no longer in any layer. The engine's own removal
  /// chokepoint (_removeConstraintsWhere) is private, so this is the converter's
  /// local equivalent with the same contract: unbind first, then drop.
  static void _unbindAndRemoveWhere(
      CompassEngine engine, bool Function(CompassConstraint) test) {
    for (final c in engine.constraints) {
      if (test(c)) c.unbind();
    }
    engine.constraints.removeWhere(test);
  }

  static void convertCircleToSpline(CompassEngine engine, CompassCircle circle) {
    CompassLayer? targetLayer;
    int shapeIndex = -1;
    for (var layer in engine.layers) {
      shapeIndex = layer.shapes.indexOf(circle);
      if (shapeIndex != -1) {
        targetLayer = layer;
        break;
      }
    }
    
    if (targetLayer == null) return;

    // Riders about to lose their host: collect BEFORE dropping the constraints,
    // so we can offer each one to GC afterward. A rider that is structural
    // elsewhere (spline start, line endpoint...) survives checkAndGCPoint;
    // a bare rider whose only reason to exist was sitting on this circle goes.
    final orphanedRiders = <CompassPoint>[];
    for (final c in engine.constraints) {
      if (c is PointOnCircleConstraint && c.circle == circle) {
        orphanedRiders.add(c.point);
      }
    }

    // Drop every constraint hosted by this circle:
    //   * its DistanceRadiusConstraint (matched by radius-notifier identity --
    //     the constraint carries no shape reference). Left alive, it keeps
    //     recomputing the dead circle's radius on every center/radiusPoint move
    //     whenever the radiusPoint survives as a shared point.
    //   * any PointOnCircleConstraint riders -- left alive, they visibly snap
    //     their points back onto the now-invisible circle on every drag.
    // The spline replacing the circle has no equivalent constraint concept, so
    // dropping (not migrating) is the correct semantic.
    _unbindAndRemoveWhere(
        engine,
        (c) =>
            (c is DistanceRadiusConstraint &&
                identical(c.targetRadius, circle.radius)) ||
            (c is PointOnCircleConstraint && c.circle == circle));

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
      engine.points.add(p);
      p.x.addListener(engine.notifyListeners);
      p.y.addListener(engine.notifyListeners);
      
      circle.center.attach(p);

      final node = CompassSplineNode(point: p, tension: circleTension);
      node.tension.addListener(engine.notifyListeners);
      spline.addNode(node);
    }

    targetLayer.shapes[shapeIndex] = spline;
    
    if (engine.selectedShape == circle) {
      engine.selectShape(spline);
    }

    if (circle.radiusPoint != null) {
      circle.center.detach(circle.radiusPoint!);
      engine.checkAndGCPoint(circle.radiusPoint!);
    }

    // Ex-riders: keep if structural anywhere else, GC if their only purpose
    // was riding this circle.
    for (final rider in orphanedRiders) {
      engine.checkAndGCPoint(rider);
    }

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  static void convertRectangleToSpline(CompassEngine engine, CompassRectangle rect) {
    CompassLayer? targetLayer;
    int shapeIndex = -1;
    for (var layer in engine.layers) {
      shapeIndex = layer.shapes.indexOf(rect);
      if (shapeIndex != -1) {
        targetLayer = layer;
        break;
      }
    }
    
    if (targetLayer == null) return;

    // Drop the rect's SquareConstraint (present when isSquare was ever toggled
    // on and registered at creation/load). In-place replacement bypasses
    // removeShape, so without this the constraint survives whenever p1 or p2
    // does -- and SquareConstraint actively moveBy()s its points, so a shared
    // surviving corner gets yanked by a rectangle that no longer exists.
    _unbindAndRemoveWhere(
        engine, (c) => c is SquareConstraint && c.rect == rect);

    final cx = (rect.p1.x.value + rect.p2.x.value) / 2;
    final cy = (rect.p1.y.value + rect.p2.y.value) / 2;
    final anchor = CompassPoint(x: cx, y: cy);
    engine.points.add(anchor);
    anchor.x.addListener(engine.notifyListeners);
    anchor.y.addListener(engine.notifyListeners);

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
      engine.points.add(p);
      p.x.addListener(engine.notifyListeners);
      p.y.addListener(engine.notifyListeners);
      anchor.attach(p);

      final node = CompassSplineNode(point: p, tension: tension, handleIn: handleIn, handleOut: handleOut);
      node.tension.addListener(engine.notifyListeners);
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
        addNodeAt(pos, tension: 1.0, handleOut: hOut, handleIn: Offset(-hOut.dx, -hOut.dy));
      }
    }

    targetLayer.shapes[shapeIndex] = spline;
    
    if (engine.selectedShape == rect) {
      engine.selectShape(spline);
    }

    engine.checkAndGCPoint(rect.p1);
    engine.checkAndGCPoint(rect.p2);

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  /// Converts a rectangle into a [rows] x [cols] GRADIENT MESH. Same entry shape
  /// as convertRectangleToSpline -- in-place replacement preserving Z-order, a
  /// fresh centroid anchor, all-new grid nodes attached to that anchor, and GC of
  /// the rectangle's two defining corners afterward.
  ///
  /// UPGRADE: Instead of raw CompassPoints, it now generates CompassSplineNodes
  /// with a default tension of 1.0, allowing them to be targeted by the A key.
  static void convertRectangleToMesh(
    CompassEngine engine,
    CompassRectangle rect, {
    int rows = 3,
    int cols = 3,
  }) {
    CompassLayer? targetLayer;
    int shapeIndex = -1;
    for (var layer in engine.layers) {
      shapeIndex = layer.shapes.indexOf(rect);
      if (shapeIndex != -1) {
        targetLayer = layer;
        break;
      }
    }

    if (targetLayer == null) return;

    // Same reason as convertRectangleToSpline: in-place replacement bypasses
    // removeShape, so the SquareConstraint must be unbound here.
    _unbindAndRemoveWhere(
        engine, (c) => c is SquareConstraint && c.rect == rect);

    // A mesh needs at least one patch in each axis.
    final int gridRows = rows < 2 ? 2 : rows;
    final int gridCols = cols < 2 ? 2 : cols;

    final left = min(rect.p1.x.value, rect.p2.x.value);
    final right = max(rect.p1.x.value, rect.p2.x.value);
    final top = min(rect.p1.y.value, rect.p2.y.value);
    final bottom = max(rect.p1.y.value, rect.p2.y.value);

    final cx = (left + right) / 2;
    final cy = (top + bottom) / 2;
    final anchor = CompassPoint(x: cx, y: cy);
    engine.points.add(anchor);
    anchor.x.addListener(engine.notifyListeners);
    anchor.y.addListener(engine.notifyListeners);

    // Inherit the layer's fill as the uniform seed; neutral grey if there is none
    // (alpha 0 == transparent / "None"), so the mesh starts visible.
    final Color seed =
        targetLayer.color.alpha == 0 ? const Color(0xFFCCCCCC) : targetLayer.color;

    final nodes = <CompassSplineNode>[];
    final colors = <Color>[];

    for (int r = 0; r < gridRows; r++) {
      final fy = r / (gridRows - 1);
      final py = top + (bottom - top) * fy;
      for (int c = 0; c < gridCols; c++) {
        final fx = c / (gridCols - 1);
        final px = left + (right - left) * fx;

        final p = CompassPoint(x: px, y: py);
        engine.points.add(p);
        p.x.addListener(engine.notifyListeners);
        p.y.addListener(engine.notifyListeners);
        anchor.attach(p);

        // --- UPGRADE: Wrap in a CompassSplineNode for tension ---
        final node = CompassSplineNode(point: p, tension: 1.0);
        node.tension.addListener(engine.notifyListeners);

        nodes.add(node);
        colors.add(seed);
      }
    }

    final mesh = CompassMesh(
      rows: gridRows,
      cols: gridCols,
      nodes: nodes,
      colors: colors,
      anchorPoint: anchor,
    )
      ..operation = rect.operation
      ..isVisible = rect.isVisible;

    targetLayer.shapes[shapeIndex] = mesh;

    if (engine.selectedShape == rect) {
      engine.selectShape(mesh);
    }

    engine.checkAndGCPoint(rect.p1);
    engine.checkAndGCPoint(rect.p2);

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  static void bakeLayer(CompassEngine engine, CompassLayer layer) {
    final int srcIndex = engine.layers.indexOf(layer);
    if (srcIndex == -1) return;

    Path masterPath = layer.getLayerFillPath();
    final areaPath = layer.getLayerStrokeAreaPath();
    
    if (areaPath.computeMetrics().isNotEmpty) {
      if (masterPath.computeMetrics().isEmpty) {
        masterPath = areaPath;
      } else {
        masterPath = Path.combine(PathOperation.union, masterPath, areaPath);
      }
    }

    final contours = PathBaker.bake(masterPath);
    if (contours.isEmpty) return;

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
    engine.points.add(anchor);
    anchor.x.addListener(engine.notifyListeners);
    anchor.y.addListener(engine.notifyListeners);

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
        engine.points.add(p);
        p.x.addListener(engine.notifyListeners);
        p.y.addListener(engine.notifyListeners);
        anchor.attach(p);

        final node = CompassSplineNode(
          point: p,
          tension: 1.0,
          handleIn: bn.handleIn,
          handleOut: bn.handleOut,
        );
        node.tension.addListener(engine.notifyListeners);
        spline.addNode(node);
      }

      baked.shapes.add(spline);
    }

    engine.layers.insert(srcIndex + 1, baked);
    layer.isVisible = false;
    engine.activeLayer = baked;
    baked.isExpanded = true;
    engine.selectShape(null); // Clear selected shape

    engine.saveSnapshot();
    engine.notifyListeners();
  }
}