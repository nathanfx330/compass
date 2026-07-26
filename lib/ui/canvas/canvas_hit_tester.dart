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
import '../../models/geometry/rhombus.dart';
import '../../models/geometry/mesh.dart';

class CanvasHitTester {
  /// Whether [shape] uses [point] as part of its ordinary editable geometry.
  ///
  /// Gradient stops are intentionally handled separately. Their visibility is
  /// contextual: only stops belonging to the selected shape are drawn and
  /// therefore only those stops should be interactive.
  static bool _isStructuralPoint(
    CompassShape shape,
    CompassPoint point,
  ) {
    if (shape is CompassLine) {
      return shape.start == point || shape.end == point;
    }

    if (shape is CompassCircle) {
      return shape.center == point || shape.radiusPoint == point;
    }

    if (shape is CompassSpiral) {
      return shape.center == point || shape.startPoint == point;
    }

    if (shape is CompassRectangle) {
      return shape.p1 == point || shape.p2 == point;
    }

    if (shape is CompassRhombus) {
      return shape.p1 == point ||
          shape.p2 == point ||
          shape.p3 == point ||
          shape.p4 == point;
    }

    if (shape is CompassXSpline) {
      return shape.anchorPoint == point ||
          shape.nodes.any((node) => node.point == point);
    }

    if (shape is CompassMesh) {
      return shape.anchorPoint == point || shape.containsNode(point);
    }

    return false;
  }

  /// Whether [point] is a linear-gradient stop owned by [shape].
  static bool _isGradientStop(
    CompassShape shape,
    CompassPoint point,
  ) {
    final gradient = shape.gradient;

    if (gradient == null) {
      return false;
    }

    return gradient.stops.any((stop) => stop.point == point);
  }

  /// Returns whether [point] must be excluded from direct canvas interaction.
  ///
  /// This includes more than literal layer locking:
  ///
  /// - points used only by locked geometry;
  /// - points used only by hidden layers or hidden shapes;
  /// - gradient stops belonging to an unselected shape.
  ///
  /// Gradient-stop dots are drawn only for the selected shape. Treating every
  /// stop in `engine.points` as interactive would allow invisible stops to steal
  /// hover, click, drag, context-menu, and selection-box input.
  ///
  /// A point shared with visible, unlocked structural geometry remains
  /// interactive even if it is also referenced by locked or hidden geometry.
  /// A genuinely loose point that belongs to no shape also remains interactive.
  static bool isPointLocked(
    CompassEngine engine,
    CompassPoint point,
  ) {
    var hasDocumentUse = false;
    var hasVisibleUnlockedStructuralUse = false;
    var hasVisibleSelectedUnlockedGradientUse = false;

    for (final layer in engine.layers) {
      for (final shape in layer.shapes) {
        final isStructural = _isStructuralPoint(shape, point);
        final isGradientStop = _isGradientStop(shape, point);

        if (!isStructural && !isGradientStop) {
          continue;
        }

        hasDocumentUse = true;

        if (!layer.isVisible || !shape.isVisible) {
          continue;
        }

        if (isStructural && !layer.isLocked) {
          hasVisibleUnlockedStructuralUse = true;
        }

        if (isGradientStop &&
            !layer.isLocked &&
            identical(shape, engine.selectedShape)) {
          hasVisibleSelectedUnlockedGradientUse = true;
        }

        if (hasVisibleUnlockedStructuralUse ||
            hasVisibleSelectedUnlockedGradientUse) {
          return false;
        }
      }
    }

    // Loose points are still ordinary editable points. Any point owned by the
    // document but lacking a visible, unlocked interaction surface is excluded.
    return hasDocumentUse;
  }

  /// Finds the topmost interactive point within [threshold] world-space units.
  ///
  /// Points are checked from newest to oldest so visually foregrounded points,
  /// such as gradient stops and mesh nodes, win over older structural anchors
  /// when they occupy the same position.
  static CompassPoint? hitTestPoint(
    CompassEngine engine,
    Offset logicalPosition,
    double threshold,
  ) {
    final thresholdSquared = threshold * threshold;

    for (final point in engine.points.reversed) {
      if (isPointLocked(engine, point)) {
        continue;
      }

      final dx = point.x.value - logicalPosition.dx;
      final dy = point.y.value - logicalPosition.dy;
      final distanceSquared = dx * dx + dy * dy;

      if (distanceSquared < thresholdSquared) {
        return point;
      }
    }

    return null;
  }
}