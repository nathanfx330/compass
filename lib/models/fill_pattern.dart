// /lib/models/fill_pattern.dart

import 'dart:math';
import 'package:flutter/material.dart';

/// The paint used for the ordinary resolved fill of a layer.
///
/// Self-painted shapes (gradients, IMG objects, and gradient meshes) keep their
/// existing paint passes; this mode only replaces the layer's flat-color pass.
enum CompassFillMode { solid, hatch }

/// World-space settings for Compass's classic drafting hatch.
///
/// Positive angles read counter-clockwise on screen, so the default 45° makes
/// a traditional rising-right slash (/). Measurements are document units,
/// which means the pattern scales naturally with the artwork and remains stable
/// while panning or zooming.
class CompassHatchPattern {
  double angleDegrees;
  double spacing;
  double strokeWidth;
  double dashLength;
  double gapLength;

  CompassHatchPattern({
    this.angleDegrees = 45.0,
    this.spacing = 12.0,
    this.strokeWidth = 1.5,
    this.dashLength = 8.0,
    this.gapLength = 5.0,
  });

  CompassHatchPattern copyWith({
    double? angleDegrees,
    double? spacing,
    double? strokeWidth,
    double? dashLength,
    double? gapLength,
  }) {
    return CompassHatchPattern(
      angleDegrees: angleDegrees ?? this.angleDegrees,
      spacing: spacing ?? this.spacing,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      dashLength: dashLength ?? this.dashLength,
      gapLength: gapLength ?? this.gapLength,
    );
  }
}

/// Paints [path] using either a normal solid fill or a clipped world-space
/// drafting hatch. [visibleBounds] may be supplied by the live canvas to avoid
/// generating off-screen dash segments; exporters omit it to render the whole
/// artwork.
void paintCompassLayerFill(
  Canvas canvas,
  Path path, {
  required Color color,
  required CompassFillMode mode,
  required CompassHatchPattern hatch,
  Rect? visibleBounds,
  bool isAntiAlias = true,
}) {
  if (color.alpha == 0) return;

  if (mode == CompassFillMode.solid) {
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill
        ..isAntiAlias = isAntiAlias,
    );
    return;
  }

  paintCompassHatch(
    canvas,
    path,
    color: color,
    pattern: hatch,
    visibleBounds: visibleBounds,
    isAntiAlias: isAntiAlias,
  );
}

/// Draws a dashed family of parallel lines and clips it to [clipPath].
///
/// Both line placement and dash phase are anchored to the world origin. Two
/// disjoint islands therefore share one coherent pattern, and a layer mirror
/// does not fold or restart the hatch at the seam.
void paintCompassHatch(
  Canvas canvas,
  Path clipPath, {
  required Color color,
  required CompassHatchPattern pattern,
  Rect? visibleBounds,
  bool isAntiAlias = true,
}) {
  var bounds = clipPath.getBounds();
  if (visibleBounds != null) {
    bounds = bounds.intersect(visibleBounds);
  }
  if (bounds.isEmpty) return;

  final spacing = max(0.5, pattern.spacing.abs());
  final strokeWidth = max(0.05, pattern.strokeWidth.abs());
  final dashLength = max(0.1, pattern.dashLength.abs());
  final gapLength = max(0.0, pattern.gapLength);
  final period = max(0.1, dashLength + gapLength);

  final radians = pattern.angleDegrees * pi / 180.0;
  // Flutter's canvas has +Y downward. Negating sin makes a positive 45° angle
  // read as the conventional rising-right drafting slash (/).
  final direction = Offset(cos(radians), -sin(radians));
  final normal = Offset(-direction.dy, direction.dx);

  double dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

  final corners = <Offset>[
    bounds.topLeft,
    bounds.topRight,
    bounds.bottomRight,
    bounds.bottomLeft,
  ];

  var minNormal = double.infinity;
  var maxNormal = double.negativeInfinity;
  var minAlong = double.infinity;
  var maxAlong = double.negativeInfinity;

  for (final corner in corners) {
    final n = dot(corner, normal);
    final t = dot(corner, direction);
    minNormal = min(minNormal, n);
    maxNormal = max(maxNormal, n);
    minAlong = min(minAlong, t);
    maxAlong = max(maxAlong, t);
  }

  // Small padding prevents anti-aliased edges from exposing an unpainted sliver
  // at the clip boundary.
  minNormal -= spacing;
  maxNormal += spacing;
  minAlong -= period;
  maxAlong += period;

  final firstNormal = (minNormal / spacing).floor() * spacing;
  final firstDash = (minAlong / period).floor() * period;

  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = strokeWidth
    ..strokeCap = StrokeCap.butt
    ..isAntiAlias = isAntiAlias;

  canvas.save();
  canvas.clipRect(bounds.inflate(strokeWidth + 1.0));
  canvas.clipPath(clipPath);

  for (double n = firstNormal; n <= maxNormal; n += spacing) {
    final lineOrigin = normal * n;
    for (double t = firstDash; t <= maxAlong; t += period) {
      final startT = max(t, minAlong);
      final endT = min(t + dashLength, maxAlong);
      if (endT <= startT) continue;

      canvas.drawLine(
        lineOrigin + direction * startT,
        lineOrigin + direction * endT,
        paint,
      );
    }
  }

  canvas.restore();
}
