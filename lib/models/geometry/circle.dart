import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';

/// A circle defined by a center CompassPoint and a reactive radius.
class CompassCircle extends CompassShape {
  final CompassPoint center;
  final CompassPoint? radiusPoint; 
  final ValueNotifier<double> radius;

  CompassCircle({
    required this.center, 
    required double radius, 
    this.radiusPoint,
    super.operation,
    super.isVisible,
  }) : radius = ValueNotifier(radius);

  @override
  Path getPath() {
    final path = Path();
    if (radius.value <= 0) return path; 
    
    path.addOval(Rect.fromCircle(
      center: Offset(center.x.value, center.y.value),
      radius: radius.value,
    ));
    return path;
  }

  @override
  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false}) {
    final cOffset = Offset(center.x.value, center.y.value);

    canvas.drawCircle(cOffset, radius.value, paint);

    if (showScaffolding && isSelected && radiusPoint != null) {
      final rOffset = Offset(radiusPoint!.x.value, radiusPoint!.y.value);
      
      final scaffoldPaint = Paint()
        ..color = Colors.blue.withOpacity(0.5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      _drawDashedLine(canvas, cOffset, rOffset, scaffoldPaint);
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const double dashWidth = 6.0;
    const double dashSpace = 6.0;
    double distance = (p2 - p1).distance;
    if (distance == 0) return; 

    double dx = (p2.dx - p1.dx) / distance;
    double dy = (p2.dy - p1.dy) / distance;
    
    double currentDistance = 0;
    while (currentDistance < distance) {
      double nextDistance = currentDistance + dashWidth;
      if (nextDistance > distance) nextDistance = distance;
      canvas.drawLine(
        Offset(p1.dx + dx * currentDistance, p1.dy + dy * currentDistance),
        Offset(p1.dx + dx * nextDistance, p1.dy + dy * nextDistance),
        paint,
      );
      currentDistance += dashWidth + dashSpace;
    }
  }
}