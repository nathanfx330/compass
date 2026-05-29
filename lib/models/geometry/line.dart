import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';

/// A line defined purely by the relationship between two CompassPoints.
class CompassLine extends CompassShape {
  final CompassPoint start;
  final CompassPoint end;

  CompassLine({
    required this.start, 
    required this.end,
    super.operation,
    super.isVisible,
  });

  @override
  Path getPath() {
    return Path(); 
  }

  @override
  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false}) {
    canvas.drawLine(
      Offset(start.x.value, start.y.value),
      Offset(end.x.value, end.y.value),
      paint,
    );
  }
}