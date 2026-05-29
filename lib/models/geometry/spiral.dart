import 'dart:math';
import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';

/// A logarithmic spiral that grows by the Golden Ratio (phi) every 90 degrees.
class CompassSpiral extends CompassShape {
  final CompassPoint center;
  final CompassPoint startPoint;
  
  bool isClockwise;
  double revolutions;

  static const double phi = 1.618033988749895;

  CompassSpiral({
    required this.center,
    required this.startPoint,
    this.isClockwise = false,
    this.revolutions = 4.0,
    super.operation = CompassBooleanOp.none, 
    super.isVisible,
  });

  @override
  Path getPath() {
    final path = Path();
    
    final cx = center.x.value;
    final cy = center.y.value;
    final sx = startPoint.x.value;
    final sy = startPoint.y.value;

    final initialRadius = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));
    if (initialRadius <= 0) return path;

    final initialAngle = atan2(sy - cy, sx - cx);

    final b = (2 * log(phi)) / pi;

    path.moveTo(sx, sy);

    final maxTheta = revolutions * 2 * pi; 
    const step = pi / 30; 

    for (double theta = step; theta <= maxTheta; theta += step) {
      final r = initialRadius * exp(b * theta);
      final currentAngle = isClockwise ? initialAngle - theta : initialAngle + theta;
      
      final px = cx + r * cos(currentAngle);
      final py = cy + r * sin(currentAngle);
      
      path.lineTo(px, py);
    }

    return path;
  }

  @override
  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false}) {
    final spiralPaint = Paint()
      ..color = paint.color
      ..strokeWidth = paint.strokeWidth
      ..style = PaintingStyle.stroke;

    canvas.drawPath(getPath(), spiralPaint);

    if (showScaffolding && isSelected) {
      final cOffset = Offset(center.x.value, center.y.value);
      final sOffset = Offset(startPoint.x.value, startPoint.y.value);
      
      final scaffoldPaint = Paint()
        ..color = Colors.blue.withOpacity(0.5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      canvas.drawLine(cOffset, sOffset, scaffoldPaint);
    }
  }
}