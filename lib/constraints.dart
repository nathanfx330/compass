// lib/constraints.dart

import 'dart:math';
import 'package:flutter/foundation.dart';
import 'engine.dart'; // Keep this, as it might be needed for anything that touches Engine state directly

// --- IMPORT MODELS ---
import 'models/geometry/point.dart';
import 'models/geometry/line.dart';
import 'models/geometry/circle.dart';
import 'models/geometry/spiral.dart';
import 'models/geometry/rectangle.dart'; // <--- ADDED

/// The base class for all rules in the system.
abstract class CompassConstraint {
  /// Calculates and applies the mathematical rule
  void enforce();
  
  /// Sets up the listeners so the rule is enforced automatically when points move
  void bind();
}

/// A rule that forces a target radius to always equal the exact distance 
/// between two points.
class DistanceRadiusConstraint extends CompassConstraint {
  final CompassPoint p1;
  final CompassPoint p2;
  final ValueNotifier<double> targetRadius;

  DistanceRadiusConstraint({
    required this.p1,
    required this.p2,
    required this.targetRadius,
  }) {
    bind();
    enforce(); // Enforce immediately upon creation so it snaps to truth
  }

  @override
  void enforce() {
    // Pythagorean theorem to find the exact distance between the two points
    final dx = p2.x.value - p1.x.value;
    final dy = p2.y.value - p1.y.value;
    targetRadius.value = sqrt(dx * dx + dy * dy);
  }

  @override
  void bind() {
    // Whenever any of these coordinates change, enforce the rule again
    void listener() => enforce();
    
    p1.x.addListener(listener);
    p1.y.addListener(listener);
    p2.x.addListener(listener);
    p2.y.addListener(listener);
  }
}

/// A rule that forces a point to always remain on a given line segment.
class PointOnLineConstraint extends CompassConstraint {
  final CompassPoint point;
  final CompassLine line;
  bool _isEnforcing = false; 

  PointOnLineConstraint({
    required this.point,
    required this.line,
  }) {
    bind();
    enforce();
  }

  @override
  void enforce() {
    if (_isEnforcing) return;
    _isEnforcing = true;

    final start = line.start;
    final end = line.end;

    final l2 = pow(end.x.value - start.x.value, 2) + pow(end.y.value - start.y.value, 2);
    
    double targetX, targetY;

    if (l2 == 0) {
      targetX = start.x.value;
      targetY = start.y.value;
    } else {
      final dx = end.x.value - start.x.value;
      final dy = end.y.value - start.y.value;

      final px = point.x.value - start.x.value;
      final py = point.y.value - start.y.value;

      double t = (px * dx + py * dy) / l2;
      t = max(0, min(1, t));

      targetX = start.x.value + t * dx;
      targetY = start.y.value + t * dy;
    }

    // FIX: Calculate the delta, and push it through the hierarchy using moveBy
    final dx = targetX - point.x.value;
    final dy = targetY - point.y.value;

    if (dx.abs() > 0.0001 || dy.abs() > 0.0001) {
      point.moveBy(dx, dy);
    }

    _isEnforcing = false;
  }

  @override
  void bind() {
    void listener() => enforce();
    
    line.start.x.addListener(listener);
    line.start.y.addListener(listener);
    line.end.x.addListener(listener);
    line.end.y.addListener(listener);
    
    point.x.addListener(listener);
    point.y.addListener(listener);
  }
}

/// A rule that forces a point to always remain on the circumference of a circle.
class PointOnCircleConstraint extends CompassConstraint {
  final CompassPoint point;
  final CompassCircle circle;
  bool _isEnforcing = false;
  
  double _lockedAngle = 0.0; 

  PointOnCircleConstraint({
    required this.point,
    required this.circle,
  }) {
    _calculateCurrentAngle();
    bind();
    enforce();
  }

  void _calculateCurrentAngle() {
    final cx = circle.center.x.value;
    final cy = circle.center.y.value;
    final px = point.x.value;
    final py = point.y.value;
    
    _lockedAngle = atan2(py - cy, px - cx);
  }

  @override
  void enforce() {
    if (_isEnforcing) return;
    _isEnforcing = true;

    final cx = circle.center.x.value;
    final cy = circle.center.y.value;
    final r = circle.radius.value;

    if (point.isBeingDragged) {
      _calculateCurrentAngle();
    }

    final targetX = cx + r * cos(_lockedAngle);
    final targetY = cy + r * sin(_lockedAngle);

    final dx = targetX - point.x.value;
    final dy = targetY - point.y.value;

    if (dx.abs() > 0.0001 || dy.abs() > 0.0001) {
      point.moveBy(dx, dy);
    }

    _isEnforcing = false;
  }

  @override
  void bind() {
    void listener() => enforce();
    
    circle.center.x.addListener(listener);
    circle.center.y.addListener(listener);
    circle.radius.addListener(listener);
    
    point.x.addListener(listener);
    point.y.addListener(listener);
  }
}

/// A rule that forces a point to always remain on the logarithmic curve of a Golden Spiral.
class PointOnSpiralConstraint extends CompassConstraint {
  final CompassPoint point;
  final CompassSpiral spiral;
  bool _isEnforcing = false;
  
  // Tracks the absolute mathematical angle (including 2*Pi wraps) along the infinite spiral curve
  double _lockedTheta = 0.0;

  PointOnSpiralConstraint({
    required this.point,
    required this.spiral,
  }) {
    _calculateCurrentTheta();
    bind();
    enforce();
  }

  void _calculateCurrentTheta() {
    final cx = spiral.center.x.value;
    final cy = spiral.center.y.value;
    final px = point.x.value;
    final py = point.y.value;

    final sx = spiral.startPoint.x.value;
    final sy = spiral.startPoint.y.value;

    final initialAngle = atan2(sy - cy, sx - cx);
    final currentAngle = atan2(py - cy, px - cx);
    
    // Calculate raw angle difference
    double deltaAngle = spiral.isClockwise 
        ? initialAngle - currentAngle 
        : currentAngle - initialAngle;

    // Normalize to 0 -> 2Pi
    deltaAngle = deltaAngle % (2 * pi);
    if (deltaAngle < 0) deltaAngle += 2 * pi;

    // Figure out which "wrap" or revolution of the spiral the point is currently closest to
    final distToCenter = sqrt(pow(px - cx, 2) + pow(py - cy, 2));
    final initialRadius = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));
    
    if (initialRadius <= 0) return;

    final b = (2 * log(CompassSpiral.phi)) / pi;

    // We scan through the allowed revolutions to find the radius curve closest to the user's mouse
    double closestTheta = deltaAngle;
    double minDiff = double.infinity;
    
    final maxTheta = spiral.revolutions * 2 * pi;

    for (double wraps = 0; deltaAngle + (wraps * 2 * pi) <= maxTheta; wraps++) {
      double testTheta = deltaAngle + (wraps * 2 * pi);
      double testRadius = initialRadius * exp(b * testTheta);
      
      double diff = (testRadius - distToCenter).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closestTheta = testTheta;
      }
    }

    _lockedTheta = closestTheta;
  }

  @override
  void enforce() {
    if (_isEnforcing) return;
    _isEnforcing = true;

    final cx = spiral.center.x.value;
    final cy = spiral.center.y.value;
    
    final sx = spiral.startPoint.x.value;
    final sy = spiral.startPoint.y.value;
    
    final initialRadius = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));

    if (initialRadius > 0) {
      if (point.isBeingDragged) {
        _calculateCurrentTheta();
      }

      // Clamp theta so the point can't be dragged off the end of the spiral
      final maxTheta = spiral.revolutions * 2 * pi;
      _lockedTheta = max(0.0, min(_lockedTheta, maxTheta));

      final initialAngle = atan2(sy - cy, sx - cx);
      final b = (2 * log(CompassSpiral.phi)) / pi;

      final targetRadius = initialRadius * exp(b * _lockedTheta);
      final targetAngle = spiral.isClockwise 
          ? initialAngle - _lockedTheta 
          : initialAngle + _lockedTheta;

      final targetX = cx + targetRadius * cos(targetAngle);
      final targetY = cy + targetRadius * sin(targetAngle);

      final dx = targetX - point.x.value;
      final dy = targetY - point.y.value;

      if (dx.abs() > 0.0001 || dy.abs() > 0.0001) {
        point.moveBy(dx, dy);
      }
    }

    _isEnforcing = false;
  }

  @override
  void bind() {
    void listener() => enforce();
    
    spiral.center.x.addListener(listener);
    spiral.center.y.addListener(listener);
    spiral.startPoint.x.addListener(listener);
    spiral.startPoint.y.addListener(listener);
    
    point.x.addListener(listener);
    point.y.addListener(listener);
  }
}

// --- NEW: Rectangle Square Constraint ---
/// A rule that forces the diagonal of a rectangle to always be a perfect 45 degrees,
/// maintaining a 1:1 aspect ratio (a square) no matter which point is dragged.
class SquareConstraint extends CompassConstraint {
  final CompassRectangle rect;
  bool _isEnforcing = false;

  SquareConstraint({required this.rect}) {
    bind();
    enforce();
  }

  @override
  void enforce() {
    if (_isEnforcing) return;
    if (!rect.isSquare) return; // Only enforce if the toggle is on

    _isEnforcing = true;

    final p1 = rect.p1;
    final p2 = rect.p2;

    // Calculate current width and height
    final dx = p2.x.value - p1.x.value;
    final dy = p2.y.value - p1.y.value;

    // Use the largest axis as the target size to prevent shrinking during drags
    final size = max(dx.abs(), dy.abs());

    // Preserve the current quadrant / drag direction
    final signX = dx < 0 ? -1 : 1;
    final signY = dy < 0 ? -1 : 1;

    // If P2 is actively being dragged by the user, we modify P2's coordinates to snap to P1
    if (p2.isBeingDragged) {
      final targetX = p1.x.value + (size * signX);
      final targetY = p1.y.value + (size * signY);
      
      final diffX = targetX - p2.x.value;
      final diffY = targetY - p2.y.value;
      
      if (diffX.abs() > 0.0001 || diffY.abs() > 0.0001) {
        p2.moveBy(diffX, diffY);
      }
    } 
    // If P1 is actively being dragged by the user, we modify P1's coordinates to snap to P2
    else if (p1.isBeingDragged) {
      final targetX = p2.x.value - (size * signX);
      final targetY = p2.y.value - (size * signY);
      
      final diffX = targetX - p1.x.value;
      final diffY = targetY - p1.y.value;
      
      if (diffX.abs() > 0.0001 || diffY.abs() > 0.0001) {
        p1.moveBy(diffX, diffY);
      }
    } 
    // If neither is being dragged (e.g. standard rule initialization), default to moving P2
    else {
      final targetX = p1.x.value + (size * signX);
      final targetY = p1.y.value + (size * signY);
      p2.moveBy(targetX - p2.x.value, targetY - p2.y.value);
    }

    _isEnforcing = false;
  }

  @override
  void bind() {
    void listener() => enforce();
    
    rect.p1.x.addListener(listener);
    rect.p1.y.addListener(listener);
    rect.p2.x.addListener(listener);
    rect.p2.y.addListener(listener);
  }
}