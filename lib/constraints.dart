// /lib/constraints.dart

import 'dart:math';
import 'package:flutter/foundation.dart';

// --- IMPORT MODELS ---
import 'models/geometry/point.dart';
import 'models/geometry/line.dart';
import 'models/geometry/circle.dart';
import 'models/geometry/spiral.dart';
import 'models/geometry/rectangle.dart';

/// The base class for all rules in the system.
///
/// LIFECYCLE CONTRACT: every concrete constraint calls bind() + enforce() in its
/// constructor, and MUST be unbind()-ed before it is dropped. bind() registers a
/// single listener closure on every ValueNotifier the rule watches; until
/// unbind() removes that closure, the notifiers hold the constraint alive and it
/// KEEPS ENFORCING -- a "zombie" that re-projects surviving points onto deleted
/// host geometry (the notifier's listener list is a strong reference, so Dart GC
/// never collects it either). This is why nothing may ever bare-remove a
/// constraint from a list: unbind first, then drop the reference.
abstract class CompassConstraint {
  /// Calculates and applies the mathematical rule
  void enforce();
  
  /// Sets up the listeners so the rule is enforced automatically when points move
  void bind();

  /// Removes every listener bind() registered. After this the constraint is
  /// inert: nothing fires it, and nothing holds it alive. Idempotent -- a second
  /// call is a no-op, so overlapping cleanup paths (shape delete + point GC)
  /// can both call it safely.
  void unbind();
}

/// A rule that forces a target radius to always equal the exact distance 
/// between two points.
class DistanceRadiusConstraint extends CompassConstraint {
  final CompassPoint p1;
  final CompassPoint p2;
  final ValueNotifier<double> targetRadius;

  VoidCallback? _boundListener;

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
    // Whenever any of these coordinates change, enforce the rule again.
    // The closure is captured in _boundListener so unbind() can remove the
    // EXACT same object addListener registered -- removeListener matches by
    // identity, so a freshly-created identical closure would remove nothing.
    void listener() => enforce();
    _boundListener = listener;
    
    p1.x.addListener(listener);
    p1.y.addListener(listener);
    p2.x.addListener(listener);
    p2.y.addListener(listener);
  }

  @override
  void unbind() {
    final listener = _boundListener;
    if (listener == null) return;

    p1.x.removeListener(listener);
    p1.y.removeListener(listener);
    p2.x.removeListener(listener);
    p2.y.removeListener(listener);

    _boundListener = null;
  }
}

/// A rule that forces a point to always remain on a given line segment.
class PointOnLineConstraint extends CompassConstraint {
  final CompassPoint point;
  final CompassLine line;
  bool _isEnforcing = false; 

  VoidCallback? _boundListener;

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

    // RIGID-BODY GUARD: if this point AND one of the line's endpoints are both
    // being dragged, the line and the point are moving together as a single rigid
    // body (a global rotation or translation). The transform has already placed the
    // point at its correct position on the equally-rotated line, so a projection
    // here would only act on a half-written intermediate line and slide the point to
    // a wrong spot. There is no locked reference to refresh -- the projection is
    // recomputed fresh whenever the constraint runs normally -- so we simply skip.
    // (Dragging the point alone still slides it along the line; dragging an endpoint
    // alone still re-projects the point, because in both those cases only one side
    // is being dragged and this guard does not trigger.)
    if (point.isBeingDragged && (line.start.isBeingDragged || line.end.isBeingDragged)) {
      _isEnforcing = false;
      return;
    }

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
    _boundListener = listener;
    
    line.start.x.addListener(listener);
    line.start.y.addListener(listener);
    line.end.x.addListener(listener);
    line.end.y.addListener(listener);
    
    point.x.addListener(listener);
    point.y.addListener(listener);
  }

  @override
  void unbind() {
    final listener = _boundListener;
    if (listener == null) return;

    line.start.x.removeListener(listener);
    line.start.y.removeListener(listener);
    line.end.x.removeListener(listener);
    line.end.y.removeListener(listener);

    point.x.removeListener(listener);
    point.y.removeListener(listener);

    _boundListener = null;
  }
}

/// A rule that forces a point to always remain on the circumference of a circle.
class PointOnCircleConstraint extends CompassConstraint {
  final CompassPoint point;
  final CompassCircle circle;
  bool _isEnforcing = false;
  
  double _lockedAngle = 0.0; 

  VoidCallback? _boundListener;

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

    // RIGID-BODY GUARD: when the circle's center is being dragged AND this point is
    // also being dragged, the whole circle is moving as one rigid body (a global
    // rotation or translation). The point has already been placed at its correct
    // rigid position by the transform; issuing a circumference correction here would
    // act on a half-written intermediate state -- center moved, radius momentarily
    // recomputed from a partially-rotated circle -- and snap the point to a wrong
    // angle/radius. If this point ALSO defines another circle's radius (one circle
    // linked onto another), that wrong placement rescales the partner circle, and
    // the error compounds every tick. So we keep the locked angle synced to the live
    // geometry and skip the correction. The final listener fire of the tick reads
    // fully-settled coordinates, so _lockedAngle lands correct.
    //
    // This guard only triggers when the host circle is itself moving. Dragging the
    // point alone (center stationary) still slides it around the circumference, and
    // resizing the circle (center stationary, radius point dragged) still drags the
    // point along -- both fall through to the normal logic below.
    if (point.isBeingDragged && circle.center.isBeingDragged) {
      _calculateCurrentAngle();
      _isEnforcing = false;
      return;
    }

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
    _boundListener = listener;
    
    circle.center.x.addListener(listener);
    circle.center.y.addListener(listener);
    circle.radius.addListener(listener);
    
    point.x.addListener(listener);
    point.y.addListener(listener);
  }

  @override
  void unbind() {
    final listener = _boundListener;
    if (listener == null) return;

    circle.center.x.removeListener(listener);
    circle.center.y.removeListener(listener);
    circle.radius.removeListener(listener);

    point.x.removeListener(listener);
    point.y.removeListener(listener);

    _boundListener = null;
  }
}

/// A rule that forces a point to always remain on the logarithmic curve of a Golden Spiral.
class PointOnSpiralConstraint extends CompassConstraint {
  final CompassPoint point;
  final CompassSpiral spiral;
  bool _isEnforcing = false;
  
  // Tracks the absolute mathematical angle (including 2*Pi wraps) along the infinite spiral curve
  double _lockedTheta = 0.0;

  VoidCallback? _boundListener;

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

    // RIGID-BODY GUARD: see PointOnCircleConstraint. When the spiral is being moved
    // as a rigid body (its center is being dragged) and this point rides along, the
    // point is already correctly placed -- skip the correction, which would act on a
    // half-written spiral, and only keep _lockedTheta synced to the live geometry.
    // Dragging the point alone (center stationary) still walks it along the curve.
    if (point.isBeingDragged && spiral.center.isBeingDragged) {
      _calculateCurrentTheta();
      _isEnforcing = false;
      return;
    }

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
    _boundListener = listener;
    
    spiral.center.x.addListener(listener);
    spiral.center.y.addListener(listener);
    spiral.startPoint.x.addListener(listener);
    spiral.startPoint.y.addListener(listener);
    
    point.x.addListener(listener);
    point.y.addListener(listener);
  }

  @override
  void unbind() {
    final listener = _boundListener;
    if (listener == null) return;

    spiral.center.x.removeListener(listener);
    spiral.center.y.removeListener(listener);
    spiral.startPoint.x.removeListener(listener);
    spiral.startPoint.y.removeListener(listener);

    point.x.removeListener(listener);
    point.y.removeListener(listener);

    _boundListener = null;
  }
}

/// A rule that forces the diagonal of a rectangle to always be a perfect 45 degrees,
/// maintaining a 1:1 aspect ratio (a square) no matter which point is dragged.
class SquareConstraint extends CompassConstraint {
  final CompassRectangle rect;
  bool _isEnforcing = false;

  VoidCallback? _boundListener;

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
    _boundListener = listener;
    
    rect.p1.x.addListener(listener);
    rect.p1.y.addListener(listener);
    rect.p2.x.addListener(listener);
    rect.p2.y.addListener(listener);
  }

  @override
  void unbind() {
    final listener = _boundListener;
    if (listener == null) return;

    rect.p1.x.removeListener(listener);
    rect.p1.y.removeListener(listener);
    rect.p2.x.removeListener(listener);
    rect.p2.y.removeListener(listener);

    _boundListener = null;
  }
}

// --- Parallelogram Constraint ---
/// A rule that forces four points to always form a parallelogram/skewed square.
/// If you drag one corner to skew the shape, the corresponding points
/// move automatically to keep opposite sides perfectly parallel.
class ParallelogramConstraint extends CompassConstraint {
  final CompassPoint p1; // Bottom-Left
  final CompassPoint p2; // Bottom-Right
  final CompassPoint p3; // Top-Right
  final CompassPoint p4; // Top-Left
  bool _isEnforcing = false;

  VoidCallback? _boundListener;

  ParallelogramConstraint({
    required this.p1,
    required this.p2,
    required this.p3,
    required this.p4,
  }) {
    bind();
    enforce();
  }

  @override
  void enforce() {
    if (_isEnforcing) return;
    _isEnforcing = true;

    // RIGID-BODY GUARD: If multiple points are moving together (e.g., panning 
    // the whole shape), skip enforcement so they don't fight the translation.
    int dragCount = (p1.isBeingDragged ? 1 : 0) + 
                    (p2.isBeingDragged ? 1 : 0) + 
                    (p3.isBeingDragged ? 1 : 0) + 
                    (p4.isBeingDragged ? 1 : 0);
    
    if (dragCount > 1) {
      _isEnforcing = false;
      return;
    }

    // A parallelogram mathematically requires: Vector(p1 -> p2) == Vector(p4 -> p3)
    // Therefore: p3 - p4 = p2 - p1

    if (p4.isBeingDragged) {
      // Dragging Top-Left (p4) skews the top edge. Move Top-Right (p3) to match.
      // p3 = p4 + (p2 - p1)
      final targetX = p4.x.value + (p2.x.value - p1.x.value);
      final targetY = p4.y.value + (p2.y.value - p1.y.value);
      _moveTo(p3, targetX, targetY);
    } 
    else if (p3.isBeingDragged) {
      // Dragging Top-Right (p3) skews the top edge. Move Top-Left (p4) to match.
      // p4 = p3 - (p2 - p1)
      final targetX = p3.x.value - (p2.x.value - p1.x.value);
      final targetY = p3.y.value - (p2.y.value - p1.y.value);
      _moveTo(p4, targetX, targetY);
    } 
    else if (p2.isBeingDragged) {
      // Dragging Bottom-Right (p2) changes the base. Move Top-Right (p3) to match.
      final targetX = p4.x.value + (p2.x.value - p1.x.value);
      final targetY = p4.y.value + (p2.y.value - p1.y.value);
      _moveTo(p3, targetX, targetY);
    } 
    else if (p1.isBeingDragged) {
      // Dragging Bottom-Left (p1) changes the base. Move Top-Left (p4) to match.
      final targetX = p3.x.value + (p1.x.value - p2.x.value);
      final targetY = p3.y.value + (p1.y.value - p2.y.value);
      _moveTo(p4, targetX, targetY);
    } 
    else {
      // Initialization / Default: Force p4 to snap into the correct position
      final targetX = p1.x.value + (p3.x.value - p2.x.value);
      final targetY = p1.y.value + (p3.y.value - p2.y.value);
      _moveTo(p4, targetX, targetY);
    }

    _isEnforcing = false;
  }

  void _moveTo(CompassPoint p, double targetX, double targetY) {
    final dx = targetX - p.x.value;
    final dy = targetY - p.y.value;
    if (dx.abs() > 0.0001 || dy.abs() > 0.0001) {
      p.moveBy(dx, dy);
    }
  }

  @override
  void bind() {
    void listener() => enforce();
    _boundListener = listener;

    p1.x.addListener(listener);
    p1.y.addListener(listener);
    p2.x.addListener(listener);
    p2.y.addListener(listener);
    p3.x.addListener(listener);
    p3.y.addListener(listener);
    p4.x.addListener(listener);
    p4.y.addListener(listener);
  }

  @override
  void unbind() {
    final listener = _boundListener;
    if (listener == null) return;

    p1.x.removeListener(listener);
    p1.y.removeListener(listener);
    p2.x.removeListener(listener);
    p2.y.removeListener(listener);
    p3.x.removeListener(listener);
    p3.y.removeListener(listener);
    p4.x.removeListener(listener);
    p4.y.removeListener(listener);

    _boundListener = null;
  }
}