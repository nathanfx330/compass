// /lib/shape_converter.dart

import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';

import 'engine.dart';
import 'constraints.dart'; 
import 'models/geometry/point.dart';
import 'models/geometry/shape.dart';
import 'models/geometry/circle.dart';
import 'models/geometry/rectangle.dart';
import 'models/geometry/spline.dart';
import 'models/geometry/mesh.dart'; 
import 'models/geometry/gradient.dart'; // <--- NEW: carry a lifted fill gradient onto the bake
import 'models/layer.dart';
import 'path_baker.dart';

class ShapeConverter {
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

    final orphanedRiders = <CompassPoint>[];
    for (final c in engine.constraints) {
      if (c is PointOnCircleConstraint && c.circle == circle) {
        orphanedRiders.add(c.point);
      }
    }

    _unbindAndRemoveWhere(
        engine,
        (c) =>
            (c is DistanceRadiusConstraint &&
                identical(c.targetRadius, circle.radius)) ||
            (c is PointOnCircleConstraint && c.circle == circle));

    final spline = CompassXSpline(isClosed: true, anchorPoint: circle.center)
      ..operation = circle.operation
      ..strokeRegions = circle.strokeRegions.map((region) => region.copy()).toList()
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
      ..strokeRegions = rect.strokeRegions.map((region) => region.copy()).toList()
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
        Offset(left, top), Offset(right, top),
        Offset(right, bottom), Offset(left, bottom),
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
    if (engine.selectedShape == rect) engine.selectShape(spline);

    engine.checkAndGCPoint(rect.p1);
    engine.checkAndGCPoint(rect.p2);

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  /// Converts a rectangle into a Coons gradient mesh.
  ///
  /// A MESH OWNS ITS LAYER, always. The mesh is moved to a NEW layer inserted
  /// directly above the source, and if that leaves the source empty it is
  /// dropped. One path, no special cases.
  ///
  /// WHY ISOLATION IS THE MODEL, not a Z-order fix:
  ///
  /// A mesh is not a shape among shapes -- it is a layer's APPEARANCE, closer
  /// to the layer fill color than to a circle. Three facts in the existing
  /// engine already say so:
  ///
  ///   * every boolean walk skips meshes (`if (shape is CompassMesh) continue`
  ///     in getLayerFillPath, getLayerPath, getLayerMeshExportPath), so a mesh
  ///     has never contributed a silhouette;
  ///   * CompassMesh.operation is dead weight -- getLayerMeshClipPath never
  ///     reads the mesh's own op, so setting a mesh to Subtract has always been
  ///     a no-op;
  ///   * the renderer paints meshes LAST within a layer (pass 1d, after fills,
  ///     stroke areas, and colored bands).
  ///
  /// That last point is what made an ADD shape stacked "above" a mesh vanish
  /// beneath it: getLayerMeshClipPath applies subtract and intersect from every
  /// shape in the layer, but never removes a later ADD occluder -- unlike
  /// getLayerSelfPaintedClipPath (gradients) and _applyImageForegroundOcclusion
  /// (IMG), which both do. Rather than teach the mesh clip about Z-order,
  /// isolation removes the question: alone in its layer, a mesh has nothing to
  /// order itself against, and cross-layer stacking is already well-defined and
  /// draggable in the hierarchy panel.
  ///
  /// Z-ORDER IS PRESERVED across the split. The mesh already painted last in
  /// the source layer, so promoting it to a layer immediately above renders
  /// identically -- the conversion changes structure, not appearance.
  ///
  /// The new layer inherits the source's fill/stroke colors, so the mesh's seed
  /// color (which reads the layer fill) and any later shapes added to the mesh
  /// layer behave as they did before the split.
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

    _unbindAndRemoveWhere(
        engine, (c) => c is SquareConstraint && c.rect == rect);

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
      // operation is deliberately NOT carried over from the rectangle. A mesh's
      // own op is never read by any walk, and leaving a stale `subtract` on it
      // would show a misleading badge in the hierarchy panel. `add` is the
      // honest default: it is what a mesh has always effectively been.
      ..isVisible = rect.isVisible;

    // ALWAYS ITS OWN LAYER. One path, no special cases: the mesh leaves the
    // source layer and lands in a fresh one directly above it.
    //
    // Directly above is the position that renders identically to before the
    // split, because a mesh already painted last within its layer (renderer
    // pass 1d, after fills, stroke areas, and colored bands). The conversion
    // changes structure, not appearance.
    targetLayer.shapes.removeAt(shapeIndex);

    final meshLayer = CompassLayer(
      name: '${targetLayer.name} Mesh',
      color: targetLayer.color,
      strokeColor: targetLayer.strokeColor,
      strokeWidth: targetLayer.strokeWidth,
      fillMode: targetLayer.fillMode,
      hatchPattern: targetLayer.hatchPattern.copyWith(),
    );
    meshLayer.shapes.add(mesh);
    meshLayer.isExpanded = true;

    final srcIndex = engine.layers.indexOf(targetLayer);
    engine.layers.insert(srcIndex + 1, meshLayer);
    engine.activeLayer = meshLayer;

    // If the rectangle was the source layer's only occupant, that layer is now
    // an empty husk -- drop it rather than leaving one behind on every
    // conversion. Removed inline, not through engine.removeLayer: there is no
    // geometry left to garbage-collect, and removeLayer would take its own undo
    // snapshot and re-seed a replacement layer mid-conversion. The guard is
    // belt-and-braces; meshLayer was just inserted, so the list cannot be empty.
    if (targetLayer.shapes.isEmpty && engine.layers.length > 1) {
      engine.layers.remove(targetLayer);
    }

    if (engine.selectedShape == rect) engine.selectShape(mesh);

    engine.checkAndGCPoint(rect.p1);
    engine.checkAndGCPoint(rect.p2);

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  static void bakeLayer(CompassEngine engine, CompassLayer layer) {
    final int srcIndex = engine.layers.indexOf(layer);
    if (srcIndex == -1) return;

    Path masterPath = layer.getLayerMeshExportPath();
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
      fillMode: layer.fillMode,
      hatchPattern: layer.hatchPattern.copyWith(),
    );

    // --- GRADIENT TO CARRY ONTO THE BAKE ---
    // The bake fused every shape (flat + gradient + mirror reflection) into ONE
    // world-space silhouette. A linear fill gradient is a WORLD-SPACE ramp (its
    // axis is the line between two world-positioned stop points), so the SAME
    // axis + stops shade the baked silhouette identically to how they shaded the
    // borg -- the gradient "carries out as if the shape simply extended." We take
    // the first visible lifted-gradient shape's fill as the source (the borg case
    // has exactly one); it's cloned per ADD spline below. Null => nothing to carry
    // (a purely flat layer bakes exactly as before).
    LinearGradientFill? sourceGradient;
    for (final shape in layer.shapes) {
      if (!shape.isVisible) continue;
      if (!CompassLayer.hasLiftedGradientFill(shape)) continue;
      sourceGradient = shape.gradient;
      break;
    }

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

      // --- CARRY THE GRADIENT (ADD splines only) ---
      // Holes are boolean carves, not fills, so they get no gradient. For a real
      // ADD contour we CLONE the source gradient with FRESH stop points at the
      // same world coordinates -- each registered in engine.points, listener-
      // wired, and anchored to this bake's anchor exactly like the node points
      // above. That reuses the same drag/rotate/cohere/serialize/undo machinery
      // every other point uses (per GradientStop's contract), and -- crucially --
      // the baked gradient shares NOTHING mutable with the now-hidden source
      // layer, so hiding or later deleting that source can't pull the ramp's stops
      // out from under the bake. Same world coords => identical shading. A fresh
      // clone PER add spline (not a shared object) keeps each independently
      // editable.
      if (!contour.isHole && sourceGradient != null) {
        final clonedStops = <GradientStop>[];
        for (final s in sourceGradient.stops) {
          final gp = CompassPoint(x: s.point.x.value, y: s.point.y.value);
          engine.points.add(gp);
          gp.x.addListener(engine.notifyListeners);
          gp.y.addListener(engine.notifyListeners);
          anchor.attach(gp);
          clonedStops.add(GradientStop(point: gp, color: s.color));
        }
        spline.gradient = LinearGradientFill(stops: clonedStops);
      }

      baked.shapes.add(spline);
    }

    engine.layers.insert(srcIndex + 1, baked);
    layer.isVisible = false;
    engine.activeLayer = baked;
    baked.isExpanded = true;
    engine.selectShape(null); 

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  // ===========================================================================
  // SCI-FI SKELETON (Organic Delaunay Triangulation Graph Walk)
  // ===========================================================================

  static void bakeLayerToSciFiSkeleton(CompassEngine engine, CompassLayer layer) {
    final int srcIndex = engine.layers.indexOf(layer);
    if (srcIndex == -1) return;

    Path masterPath = layer.getLayerMeshExportPath();
    final areaPath = layer.getLayerStrokeAreaPath();
    
    if (areaPath.computeMetrics().isNotEmpty) {
      if (masterPath.computeMetrics().isEmpty) {
        masterPath = areaPath;
      } else {
        masterPath = Path.combine(PathOperation.union, masterPath, areaPath);
      }
    }

    if (masterPath.computeMetrics().isEmpty) return;

    // 1. Gather points: Sparse Perimeter
    final pointCloud = <Offset>[];
    const double perimeterSpacing = 30.0; 
    
    for (final metric in masterPath.computeMetrics()) {
      if (metric.length < 1e-3) continue;
      int count = (metric.length / perimeterSpacing).floor();
      if (count < 6) count = 6; 
      
      final step = metric.length / count;
      for (int i = 0; i < count; i++) {
        final t = metric.getTangentForOffset(i * step);
        if (t != null) pointCloud.add(t.position);
      }
    }
    
    if (pointCloud.isEmpty) return;

    // 2. Gather points: Random internal scatter (Poisson-disc approximation)
    final bounds = masterPath.getBounds();
    final random = Random(42); // Seeded for deterministic beautiful results
    final targetInternalPoints = (bounds.width * bounds.height / 2500).clamp(10, 200).toInt();
    
    int added = 0;
    int attempt = 0;
    while (added < targetInternalPoints && attempt < targetInternalPoints * 15) {
      final rx = bounds.left + random.nextDouble() * bounds.width;
      final ry = bounds.top + random.nextDouble() * bounds.height;
      final pt = Offset(rx, ry);
      
      if (masterPath.contains(pt)) {
        bool tooClose = false;
        for (var p in pointCloud) {
          if ((p - pt).distanceSquared < 600.0) { // Keep them spaced out
            tooClose = true;
            break;
          }
        }
        if (!tooClose) {
          pointCloud.add(pt);
          added++;
        }
      }
      attempt++;
    }

    // 3. Compute pure Delaunay Triangulation
    final triangles = _computeDelaunay(pointCloud);

    // 4. Build Graph from edges
    final ptsList = <CompassPoint>[];
    final ptMap = <Offset, CompassPoint>{};

    CompassPoint getPoint(Offset o) {
      final rx = (o.dx * 100).round() / 100;
      final ry = (o.dy * 100).round() / 100;
      final key = Offset(rx, ry);
      
      if (ptMap.containsKey(key)) return ptMap[key]!;
      
      final p = CompassPoint(x: o.dx, y: o.dy);
      engine.points.add(p);
      p.x.addListener(engine.notifyListeners);
      p.y.addListener(engine.notifyListeners);
      
      ptsList.add(p);
      ptMap[key] = p;
      return p;
    }

    final adj = <CompassPoint, Set<CompassPoint>>{};
    
    void addEdge(CompassPoint a, CompassPoint b) {
      if (a == b) return;
      adj.putIfAbsent(a, () => {}).add(b);
      adj.putIfAbsent(b, () => {}).add(a);
    }

    // A. Always preserve the exact perimeter loops to hold the true shape
    for (final metric in masterPath.computeMetrics()) {
      if (metric.length < 1e-3) continue;
      int count = (metric.length / perimeterSpacing).floor();
      if (count < 6) count = 6;
      final step = metric.length / count;
      final loop = <CompassPoint>[];
      for (int i = 0; i < count; i++) {
        final t = metric.getTangentForOffset(i * step);
        if (t != null) loop.add(getPoint(t.position));
      }
      for (int i = 0; i < loop.length; i++) {
        addEdge(loop[i], loop[(i + 1) % loop.length]);
      }
    }

    // B. Add Internal Triangulation edges (discarding triangles outside the concave bays)
    for (final t in triangles) {
      if (masterPath.contains(t.centroid)) {
        for (final e in t.edges) {
          addEdge(getPoint(e.p1), getPoint(e.p2));
        }
      }
    }

    // 5. Traverse graph via DFS to emit ONE continuous spline
    double cx = 0, cy = 0;
    for (final p in ptsList) {
      cx += p.x.value;
      cy += p.y.value;
    }
    final anchor = CompassPoint(x: cx / ptsList.length, y: cy / ptsList.length);
    engine.points.add(anchor);
    anchor.x.addListener(engine.notifyListeners);
    anchor.y.addListener(engine.notifyListeners);
    for (final p in ptsList) anchor.attach(p);

    final spline = CompassXSpline(isClosed: false, anchorPoint: anchor)
      ..operation = CompassBooleanOp.add
      ..isVisible = true;

    final visitedEdges = <String>{};
    String edgeId(CompassPoint a, CompassPoint b) {
      return a.id.compareTo(b.id) < 0 ? '${a.id}_${b.id}' : '${b.id}_${a.id}';
    }

    void dfs(CompassPoint curr) {
      final node = CompassSplineNode(point: curr, tension: 0.0);
      node.tension.addListener(engine.notifyListeners);
      spline.addNode(node);

      for (final n in adj[curr] ?? <CompassPoint>{}) {
        final eid = edgeId(curr, n);
        if (!visitedEdges.contains(eid)) {
          visitedEdges.add(eid);
          dfs(n);
          // Backtrack to keep the single continuous line
          final backNode = CompassSplineNode(point: curr, tension: 0.0);
          backNode.tension.addListener(engine.notifyListeners);
          spline.addNode(backNode);
        }
      }
    }

    final visitedNodes = <CompassPoint>{};
    void markVisited(CompassPoint p) {
      if (visitedNodes.contains(p)) return;
      visitedNodes.add(p);
      for (final n in adj[p] ?? <CompassPoint>{}) {
        markVisited(n);
      }
    }

    for (final startNode in adj.keys) {
      if (!visitedNodes.contains(startNode)) {
        markVisited(startNode);
        dfs(startNode);
      }
    }

    // 6. Inject the layer
    final bakedLayer = CompassLayer(
      name: '${layer.name} (Sci-Fi Veins)',
      color: Colors.transparent, // No Fill
      strokeColor: const Color(0xFF00E5FF), // Cyan Stroke
      strokeWidth: 1.5,
    );

    bakedLayer.shapes.add(spline);

    engine.layers.insert(srcIndex + 1, bakedLayer);
    layer.isVisible = false;
    engine.activeLayer = bakedLayer;
    bakedLayer.isExpanded = true;
    engine.selectShape(spline);

    engine.saveSnapshot();
    engine.notifyListeners();
  }

  // --- Lightweight Bowyer-Watson Delaunay Triangulation ---
  static List<_SciFiTriangle> _computeDelaunay(List<Offset> points) {
    if (points.length < 3) return [];
    
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (var p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    
    final dx = maxX - minX;
    final dy = maxY - minY;
    final deltaMax = max(dx, dy);
    final midX = (minX + maxX) / 2;
    final midY = (minY + maxY) / 2;
    
    // Super-triangle enveloping all points
    final p1 = Offset(midX - 20 * deltaMax, midY - deltaMax);
    final p2 = Offset(midX, midY + 20 * deltaMax);
    final p3 = Offset(midX + 20 * deltaMax, midY - deltaMax);
    
    final superTri = _SciFiTriangle(p1, p2, p3);
    final triangles = <_SciFiTriangle>[superTri];
    
    for (var pt in points) {
      final badTriangles = <_SciFiTriangle>[];
      for (var t in triangles) {
        if (t.circumcircleContains(pt)) {
          badTriangles.add(t);
        }
      }
      
      final polygon = <_SciFiEdge>[];
      for (var t in badTriangles) {
        for (var e1 in t.edges) {
          bool isShared = false;
          for (var otherT in badTriangles) {
            if (t == otherT) continue;
            for (var e2 in otherT.edges) {
              if (e1.equals(e2)) {
                isShared = true;
                break;
              }
            }
            if (isShared) break;
          }
          if (!isShared) polygon.add(e1);
        }
      }
      
      triangles.removeWhere((t) => badTriangles.contains(t));
      
      for (var edge in polygon) {
        triangles.add(_SciFiTriangle(edge.p1, edge.p2, pt));
      }
    }
    
    triangles.removeWhere((t) => 
      t.a == p1 || t.a == p2 || t.a == p3 ||
      t.b == p1 || t.b == p2 || t.b == p3 ||
      t.c == p1 || t.c == p2 || t.c == p3
    );
    
    return triangles;
  }
}

class _SciFiEdge {
  final Offset p1, p2;
  _SciFiEdge(this.p1, this.p2);

  bool equals(_SciFiEdge other) {
    return ((p1.dx - other.p1.dx).abs() < 1e-4 && (p1.dy - other.p1.dy).abs() < 1e-4 &&
            (p2.dx - other.p2.dx).abs() < 1e-4 && (p2.dy - other.p2.dy).abs() < 1e-4) ||
           ((p1.dx - other.p2.dx).abs() < 1e-4 && (p1.dy - other.p2.dy).abs() < 1e-4 &&
            (p2.dx - other.p1.dx).abs() < 1e-4 && (p2.dy - other.p1.dy).abs() < 1e-4);
  }
}

class _SciFiTriangle {
  final Offset a, b, c;
  _SciFiTriangle(this.a, this.b, this.c);

  bool circumcircleContains(Offset pt) {
    final double ax = a.dx, ay = a.dy;
    final double bx = b.dx, by = b.dy;
    final double cx = c.dx, cy = c.dy;

    final double d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
    if (d.abs() < 1e-9) return false;

    final double ux = ((ax * ax + ay * ay) * (by - cy) +
            (bx * bx + by * by) * (cy - ay) +
            (cx * cx + cy * cy) * (ay - by)) / d;
    final double uy = ((ax * ax + ay * ay) * (cx - bx) +
            (bx * bx + by * by) * (ax - cx) +
            (cx * cx + cy * cy) * (bx - ax)) / d;

    final double rSq = (ax - ux) * (ax - ux) + (ay - uy) * (ay - uy);
    final double distSq = (pt.dx - ux) * (pt.dx - ux) + (pt.dy - uy) * (pt.dy - uy);
    
    return distSq <= rSq + 1e-5; 
  }

  List<_SciFiEdge> get edges => [_SciFiEdge(a, b), _SciFiEdge(b, c), _SciFiEdge(c, a)];
  
  Offset get centroid => Offset((a.dx + b.dx + c.dx) / 3, (a.dy + b.dy + c.dy) / 3);
}