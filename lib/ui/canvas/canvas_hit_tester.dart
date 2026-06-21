// ./lib/ui/canvas/canvas_hit_tester.dart

import 'dart:math';
import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/rectangle.dart';

class CanvasHitTester {
  /// Checks if a point is strictly locked (used exclusively by locked layers)
  static bool isPointLocked(CompassEngine engine, CompassPoint p) {
    bool usedInUnlocked = false;
    bool usedInLocked = false;

    for (var layer in engine.layers) {
      if (!layer.isVisible) continue; 
      
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;

        bool hasPoint = false;
        if (shape is CompassLine && (shape.start == p || shape.end == p)) hasPoint = true;
        else if (shape is CompassCircle && (shape.center == p || shape.radiusPoint == p)) hasPoint = true;
        else if (shape is CompassSpiral && (shape.center == p || shape.startPoint == p)) hasPoint = true;
        else if (shape is CompassRectangle && (shape.p1 == p || shape.p2 == p)) hasPoint = true; 
        else if (shape is CompassXSpline && (shape.nodes.any((n) => n.point == p) || shape.anchorPoint == p)) hasPoint = true;

        if (hasPoint) {
          if (layer.isLocked) {
            usedInLocked = true;
          } else {
            usedInUnlocked = true;
          }
        }
      }
    }

    if (!usedInLocked && !usedInUnlocked) return false;
    return usedInLocked && !usedInUnlocked;
  }

  /// Finds the nearest unlocked point within a scaled hit threshold
  static CompassPoint? hitTestPoint(CompassEngine engine, Offset logicalPosition, double threshold) {
    for (var point in engine.points) {
      if (isPointLocked(engine, point)) continue; 

      final distance = sqrt(
        pow(point.x.value - logicalPosition.dx, 2) +
        pow(point.y.value - logicalPosition.dy, 2),
      );

      if (distance < threshold) {
        return point;
      }
    }
    return null;
  }
}