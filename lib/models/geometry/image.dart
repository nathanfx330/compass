// lib/models/geometry/image.dart

import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'point.dart';
import 'shape.dart';

/// A raster-backed layer object.
///
/// The image itself remains raster data, while [origin], [xHandle], and [yHandle]
/// define a live affine frame in Compass's point graph. Its path is the four-sided
/// image footprint and therefore participates in the ordinary layer Boolean walk.
///
/// Source pixel (0, 0) maps to [origin], (image.width, 0) maps to [xHandle], and
/// (0, image.height) maps to [yHandle]. The fourth corner is derived, so the frame
/// can translate, rotate, scale, and skew without introducing a redundant point.
class CompassImage extends CompassShape {
  String imagePath;

  final CompassPoint origin;
  final CompassPoint xHandle;
  final CompassPoint yHandle;

  /// Decoded runtime pixels. Project persistence stores [imagePath], not this
  /// engine object; the engine reloads it asynchronously after deserialization.
  ui.Image? image;

  double opacity;

  CompassImage({
    required this.imagePath,
    required this.origin,
    required this.xHandle,
    required this.yHandle,
    this.image,
    this.opacity = 1.0,
    super.operation,
    super.isVisible,
  });

  String get displayName {
    final normalized = imagePath.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty || parts.last.isEmpty ? 'Image' : parts.last;
  }

  Offset get originOffset => Offset(origin.x.value, origin.y.value);
  Offset get xHandleOffset => Offset(xHandle.x.value, xHandle.y.value);
  Offset get yHandleOffset => Offset(yHandle.x.value, yHandle.y.value);

  Offset get xAxis => xHandleOffset - originOffset;
  Offset get yAxis => yHandleOffset - originOffset;
  Offset get fourthCorner => originOffset + xAxis + yAxis;

  @override
  Path getPath() {
    final path = Path()
      ..moveTo(originOffset.dx, originOffset.dy)
      ..lineTo(xHandleOffset.dx, xHandleOffset.dy)
      ..lineTo(fourthCorner.dx, fourthCorner.dy)
      ..lineTo(yHandleOffset.dx, yHandleOffset.dy)
      ..close();
    return path;
  }

  /// Maps source-image pixel coordinates into Compass world coordinates.
  Matrix4? get imageToWorldMatrix {
    final source = image;
    if (source == null || source.width <= 0 || source.height <= 0) {
      return null;
    }

    final x = xAxis / source.width.toDouble();
    final y = yAxis / source.height.toDouble();
    final o = originOffset;

    final matrix = Matrix4.identity();
    matrix.setEntry(0, 0, x.dx);
    matrix.setEntry(1, 0, x.dy);
    matrix.setEntry(0, 1, y.dx);
    matrix.setEntry(1, 1, y.dy);
    matrix.setEntry(0, 3, o.dx);
    matrix.setEntry(1, 3, o.dy);
    return matrix;
  }

  /// Maps a Compass world-space point into normalized image UV coordinates.
  ///
  /// The affine frame itself is enough for this calculation; decoded pixels are
  /// not required. The returned convention matches OBJ texture coordinates:
  /// [origin] is (0, 1), [xHandle] is (1, 1), and [yHandle] is (0, 0).
  /// Returns null when the frame is degenerate and cannot be inverted.
  Offset? worldToUv(Offset worldPoint) {
    final x = xAxis;
    final y = yAxis;
    final delta = worldPoint - originOffset;
    final determinant = x.dx * y.dy - x.dy * y.dx;

    if (determinant.abs() < 1e-9) {
      return null;
    }

    final u =
        (delta.dx * y.dy - delta.dy * y.dx) / determinant;
    final frameV =
        (x.dx * delta.dy - x.dy * delta.dx) / determinant;

    // Numerical noise from Path.combine/tessellation can leave boundary points
    // a hair outside the frame. Clamp those tiny excursions for portable UVs.
    return Offset(
      u.clamp(0.0, 1.0).toDouble(),
      (1.0 - frameV).clamp(0.0, 1.0).toDouble(),
    );
  }

  /// Draws the raster pixels through [clipPath]. The caller owns z-order and any
  /// layer-level mirror transform; applying the mirror to the canvas reflects the
  /// frame, clip, and pixels together.
  void drawPixels(Canvas canvas, Path clipPath) {
    final source = image;
    final transform = imageToWorldMatrix;
    if (source == null || transform == null) return;
    if (clipPath.computeMetrics().isEmpty) return;

    canvas.save();
    canvas.clipPath(clipPath);
    canvas.transform(transform.storage);
    canvas.drawImage(
      source,
      Offset.zero,
      Paint()
        ..isAntiAlias = true
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withOpacity(opacity.clamp(0.0, 1.0).toDouble()),
    );
    canvas.restore();
  }

  @override
  void paint(
    Canvas canvas,
    Paint paint, {
    bool showScaffolding = false,
    bool isSelected = false,
  }) {
    canvas.drawPath(getPath(), paint);
  }
}
