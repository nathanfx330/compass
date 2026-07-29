// lib/models/geometry/circle.dart

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
    super.strokeRegions,
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

  /// The circle's stroke as a filled ANNULUS forming ONE band of the outward stack.
  /// The band spans radii [r + innerOffset .. r + innerOffset + width], so:
  ///   * region 0 (layer passes innerOffset = 0) begins at the circumference and
  ///     expands outward -- inner r, outer r + w;
  ///   * each later region (layer passes the previous band's OUTER edge as
  ///     innerOffset) butts outward from the last band with no gap or overlap.
  ///
  /// Fed to the layer's boolean walk per region, this is what lets an orbiting
  /// circle carve a curved gap out of the geometry beneath it (the Ubuntu rim
  /// break), and lets several stacked regions form concentric tree-rings.
  ///
  /// Built as outer oval + inner oval under the even-odd rule, so the inner contour
  /// reads as a hole. Path.combine honors this path's fillType when it is used as a
  /// boolean operand, so the ring -- not the filled outer disk -- is what gets
  /// unioned/subtracted/intersected. If the inner radius is <= 0 (a band wide enough
  /// to reach past the center) the hole is omitted and the region is a solid disk of
  /// the outer radius.
  @override
  Path getStrokeOutlinePath(double width, double innerOffset) {
    final path = Path()..fillType = PathFillType.evenOdd;
    final r = radius.value;
    if (r <= 0 || width <= 0) return path;

    final inner = r + innerOffset;
    final outer = inner + width;
    if (outer <= 0) return path; // entire band is at/under the center -> nothing
    final c = Offset(center.x.value, center.y.value);

    path.addOval(Rect.fromCircle(center: c, radius: outer));

    // Omit the hole when the inner edge is at or past the center (degenerate or
    // inverted inner oval) -- the region is then a solid disk of the outer radius.
    if (inner > 0) {
      path.addOval(Rect.fromCircle(center: c, radius: inner));
    }
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