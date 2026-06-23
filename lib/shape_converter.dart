// lib/shape_converter.dart

import 'dart:math';
import 'dart:ui';

import 'engine.dart';
import 'models/geometry/point.dart';
import 'models/geometry/shape.dart';
import 'models/geometry/circle.dart';
import 'models/geometry/rectangle.dart';
import 'models/geometry/spline.dart';
import 'models/layer.dart';
import 'path_baker.dart';

class ShapeConverter {
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