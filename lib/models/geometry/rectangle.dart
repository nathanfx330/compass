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
    super.isVisible,
  }) : cornerRadius = ValueNotifier(radius);

  @override
  Path getPath() {
    final rect = Rect.fromPoints(
      Offset(p1.x.value, p1.y.value),
      Offset(p2.x.value, p2.y.value),
    );
    final path = Path();
    path.addRRect(RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius.value)));
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