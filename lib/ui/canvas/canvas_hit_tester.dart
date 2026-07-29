// /lib/ui/canvas/canvas_hit_tester.dart

import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/mesh.dart';
import '../../models/geometry/image.dart';

class _InteractivePointIndex {
  final int renderRevision;
  final CompassShape? selectedShape;
  final Set<CompassPoint> interactivePoints;
  final Set<CompassPoint> gradientStops;
  final Map<(int, int), List<CompassPoint>> cells;
  final Map<CompassPoint, int> zOrder;

  const _InteractivePointIndex({
    required this.renderRevision,
    required this.selectedShape,
    required this.interactivePoints,
    required this.gradientStops,
    required this.cells,
    required this.zOrder,
  });
}

class CanvasHitTester {
  static const double _cellSize = 64.0;
  static final Expando<_InteractivePointIndex> _indices =
      Expando<_InteractivePointIndex>('compassInteractivePointIndex');

  static Iterable<CompassPoint> _structuralPoints(CompassShape shape) sync* {
    if (shape is CompassLine) {
      yield shape.start;
      yield shape.end;
    } else if (shape is CompassCircle) {
      yield shape.center;
      final radiusPoint = shape.radiusPoint;
      if (radiusPoint != null) yield radiusPoint;
    } else if (shape is CompassSpiral) {
      yield shape.center;
      yield shape.startPoint;
    } else if (shape is CompassRectangle) {
      yield shape.p1;
      yield shape.p2;
    } else if (shape is CompassImage) {
      yield shape.origin;
      yield shape.xHandle;
      yield shape.yHandle;
    } else if (shape is CompassXSpline) {
      for (final node in shape.nodes) {
        yield node.point;
      }
      final anchor = shape.anchorPoint;
      if (anchor != null) yield anchor;
    } else if (shape is CompassMesh) {
      for (final node in shape.nodes) {
        yield node.point;
      }
      final anchor = shape.anchorPoint;
      if (anchor != null) yield anchor;
    }
  }

  static (int, int) _cellFor(Offset point) => (
        (point.dx / _cellSize).floor(),
        (point.dy / _cellSize).floor(),
      );

  static _InteractivePointIndex _indexFor(CompassEngine engine) {
    final cached = _indices[engine];
    if (cached != null &&
        cached.renderRevision == engine.renderRevision &&
        identical(cached.selectedShape, engine.selectedShape)) {
      return cached;
    }

    final usedAnywhere = <CompassPoint>{};
    final interactive = <CompassPoint>{};
    final gradientStops = <CompassPoint>{};

    for (final layer in engine.layers) {
      for (final shape in layer.shapes) {
        final editable = layer.isVisible && !layer.isLocked && shape.isVisible;

        for (final point in _structuralPoints(shape)) {
          usedAnywhere.add(point);
          if (editable) interactive.add(point);
        }

        final gradient = shape.gradient;
        if (gradient != null) {
          for (final stop in gradient.stops) {
            gradientStops.add(stop.point);
            usedAnywhere.add(stop.point);
            if (editable && identical(shape, engine.selectedShape)) {
              interactive.add(stop.point);
            }
          }
        }
      }
    }

    // Loose points remain directly editable.
    for (final point in engine.points) {
      if (!usedAnywhere.contains(point)) interactive.add(point);
    }

    final cells = <(int, int), List<CompassPoint>>{};
    final zOrder = <CompassPoint, int>{};
    for (var index = 0; index < engine.points.length; index++) {
      final point = engine.points[index];
      zOrder[point] = index;
      if (!interactive.contains(point)) continue;
      final key = _cellFor(Offset(point.x.value, point.y.value));
      cells.putIfAbsent(key, () => <CompassPoint>[]).add(point);
    }

    final built = _InteractivePointIndex(
      renderRevision: engine.renderRevision,
      selectedShape: engine.selectedShape,
      interactivePoints: interactive,
      gradientStops: gradientStops,
      cells: cells,
      zOrder: zOrder,
    );
    _indices[engine] = built;
    return built;
  }

  /// Points currently available to ordinary canvas interaction. This is shared
  /// with the overlay painter so point visibility and hit testing use one
  /// topology walk rather than independent document scans.
  static Set<CompassPoint> interactivePoints(CompassEngine engine) =>
      _indexFor(engine).interactivePoints;

  /// Every gradient-stop point in the document. The overlay paints selected
  /// stops in their dedicated pass and excludes them from generic blue dots.
  static Set<CompassPoint> gradientStopPoints(CompassEngine engine) =>
      _indexFor(engine).gradientStops;

  static bool isPointLocked(
    CompassEngine engine,
    CompassPoint point,
  ) =>
      !_indexFor(engine).interactivePoints.contains(point);

  /// Finds the topmost interactive point within [threshold] world-space units.
  /// A uniform spatial grid limits the distance checks to nearby cells; z-order
  /// still follows engine.points so newer overlapping points win as before.
  static CompassPoint? hitTestPoint(
    CompassEngine engine,
    Offset logicalPosition,
    double threshold,
  ) {
    final index = _indexFor(engine);
    final thresholdSquared = threshold * threshold;
    final minCellX = ((logicalPosition.dx - threshold) / _cellSize).floor();
    final maxCellX = ((logicalPosition.dx + threshold) / _cellSize).floor();
    final minCellY = ((logicalPosition.dy - threshold) / _cellSize).floor();
    final maxCellY = ((logicalPosition.dy + threshold) / _cellSize).floor();

    CompassPoint? best;
    var bestOrder = -1;

    for (var cellX = minCellX; cellX <= maxCellX; cellX++) {
      for (var cellY = minCellY; cellY <= maxCellY; cellY++) {
        final candidates = index.cells[(cellX, cellY)];
        if (candidates == null) continue;

        for (final point in candidates) {
          final dx = point.x.value - logicalPosition.dx;
          final dy = point.y.value - logicalPosition.dy;
          if (dx * dx + dy * dy >= thresholdSquared) continue;

          final order = index.zOrder[point] ?? -1;
          if (order > bestOrder) {
            best = point;
            bestOrder = order;
          }
        }
      }
    }

    return best;
  }
}
