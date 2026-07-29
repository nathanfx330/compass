// lib/models/geometry/rectangle.dart

import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';

/// A rectangle defined by two opposite corner points and a corner radius.
class CompassRectangle extends CompassShape {
  final CompassPoint p1;
  final CompassPoint p2;
  final ValueNotifier<double> cornerRadius;
  
  bool isSquare; // <--- ADDED

  CompassRectangle({
    required this.p1,
    required this.p2,
    double radius = 0.0,
    this.isSquare = false, // <--- ADDED
    super.operation,
    super.strokeRegions,
    super.isVisible,
  }) : cornerRadius = ValueNotifier(radius);

  Rect get rect => Rect.fromPoints(
        Offset(p1.x.value, p1.y.value),
        Offset(p2.x.value, p2.y.value),
      );

  double _clampedRadius(Rect targetRect, double requested) {
    final maxRadius = targetRect.shortestSide / 2.0;
    return requested.clamp(0.0, maxRadius).toDouble();
  }

  RRect _expandedRRect(double distance) {
    final base = rect;
    final expanded = base.inflate(distance);
    final baseRadius = _clampedRadius(base, cornerRadius.value);
    final radius = _clampedRadius(expanded, baseRadius + distance);
    return RRect.fromRectAndRadius(expanded, Radius.circular(radius));
  }

  @override
  Path getPath() {
    final targetRect = rect;
    if (targetRect.width <= 0 || targetRect.height <= 0) return Path();

    return Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          targetRect,
          Radius.circular(_clampedRadius(targetRect, cornerRadius.value)),
        ),
      );
  }

  /// One exact outward rectangle stroke region. Both contours are rounded
  /// rectangles derived from the same source geometry, so stacked bands butt
  /// together without gaps. Expanding the corner radius by the same amount as
  /// the bounds preserves a true parallel offset around rounded corners.
  @override
  Path getStrokeOutlinePath(double width, double innerOffset) {
    final path = Path()..fillType = PathFillType.evenOdd;
    if (width <= 0 || rect.width <= 0 || rect.height <= 0) return path;

    final innerDistance = innerOffset < 0 ? 0.0 : innerOffset;
    final outerDistance = innerDistance + width;

    path.addRRect(_expandedRRect(outerDistance));
    path.addRRect(_expandedRRect(innerDistance));
    return path;
  }

  @override
  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false}) {
    canvas.drawPath(getPath(), paint);

    if (showScaffolding && isSelected) {
      final scaffoldPaint = Paint()
        ..color = Colors.blue.withOpacity(0.5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      // Draw a dashed scaffolding diagonal between the two defining points
      _drawDashedLine(
        canvas, 
        Offset(p1.x.value, p1.y.value), 
        Offset(p2.x.value, p2.y.value), 
        scaffoldPaint
      );
    }
  }

  void _drawDashedLine(Canvas canvas, Offset pA, Offset pB, Paint paint) {
    const double dashWidth = 6.0;
    const double dashSpace = 6.0;
    double distance = (pB - pA).distance;
    if (distance == 0) return; 

    double dx = (pB.dx - pA.dx) / distance;
    double dy = (pB.dy - pA.dy) / distance;
    
    double currentDistance = 0;
    while (currentDistance < distance) {
      double nextDistance = currentDistance + dashWidth;
      if (nextDistance > distance) nextDistance = distance;
      canvas.drawLine(
        Offset(pA.dx + dx * currentDistance, pA.dy + dy * currentDistance),
        Offset(pA.dx + dx * nextDistance, pA.dy + dy * nextDistance),
        paint,
      );
      currentDistance += dashWidth + dashSpace;
    }
  }
}