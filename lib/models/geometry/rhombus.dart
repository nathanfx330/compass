// lib/models/geometry/rhombus.dart

import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';

/// A polygon defined by 4 corner points. When bound by a ParallelogramConstraint,
/// these points behave as a perfectly skewed square/rhombus.
class CompassRhombus extends CompassShape {
  final CompassPoint p1; // Bottom-Left
  final CompassPoint p2; // Bottom-Right
  final CompassPoint p3; // Top-Right
  final CompassPoint p4; // Top-Left

  CompassRhombus({
    required this.p1,
    required this.p2,
    required this.p3,
    required this.p4,
    super.operation,
    super.isVisible,
  });

  @override
  Path getPath() {
    final path = Path();
    path.addPolygon([
      Offset(p1.x.value, p1.y.value),
      Offset(p2.x.value, p2.y.value),
      Offset(p3.x.value, p3.y.value),
      Offset(p4.x.value, p4.y.value),
    ], true);
    return path;
  }

  @override
  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false}) {
    // Draw the actual filled/stroked geometry
    canvas.drawPath(getPath(), paint);

    if (showScaffolding && isSelected) {
      final scaffoldPaint = Paint()
        ..color = Colors.blue.withOpacity(0.5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      // Draw dashed scaffolding diagonals so you can see the structural core
      _drawDashedLine(
        canvas, 
        Offset(p1.x.value, p1.y.value), 
        Offset(p3.x.value, p3.y.value), 
        scaffoldPaint
      );
      _drawDashedLine(
        canvas, 
        Offset(p2.x.value, p2.y.value), 
        Offset(p4.x.value, p4.y.value), 
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