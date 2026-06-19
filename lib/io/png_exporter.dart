// lib/io/png_exporter.dart

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../engine.dart';
import '../models/geometry/shape.dart';
import '../models/geometry/line.dart';
import '../models/geometry/circle.dart';
import '../models/geometry/spiral.dart';
import '../models/geometry/rectangle.dart';

/// Rasterizes the pure artwork (no scaffolding) to a PNG by re-rendering the
/// model offscreen. Mirrors SVGExporter's philosophy: export the *design*, not
/// the editor. The bounding-box math and the per-layer fill/stroke/boolean draw
/// are kept deliberately parallel to SVGExporter and CompassRenderer so the
/// three outputs stay visually consistent.
class PNGExporter {
  /// Renders the engine to PNG bytes at the given pixel scale (1.0 = artwork's
  /// natural logical size, 2.0 = double resolution, etc). Background is left
  /// fully transparent, matching the SVG export's no-background behavior, so
  /// boolean subtractions read as transparency.
  static Future<Uint8List?> toPNG(CompassEngine engine, {double scale = 2.0}) async {
    // ---- 1. Compute the artwork bounding box (parallel to SVGExporter) ----
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (var p in engine.points) {
      if (p.x.value < minX) minX = p.x.value;
      if (p.y.value < minY) minY = p.y.value;
      if (p.x.value > maxX) maxX = p.x.value;
      if (p.y.value > maxY) maxY = p.y.value;
    }

    // Circles and rectangles can extend past their defining points, so widen
    // the box to include their full visual extent (matches SVGExporter).
    for (var layer in engine.layers) {
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;
        if (shape is CompassCircle) {
          final r = shape.radius.value;
          final cx = shape.center.x.value;
          final cy = shape.center.y.value;
          if (cx - r < minX) minX = cx - r;
          if (cy - r < minY) minY = cy - r;
          if (cx + r > maxX) maxX = cx + r;
          if (cy + r > maxY) maxY = cy + r;
        } else if (shape is CompassRectangle) {
          final minXP = min(shape.p1.x.value, shape.p2.x.value);
          final minYP = min(shape.p1.y.value, shape.p2.y.value);
          final maxXP = max(shape.p1.x.value, shape.p2.x.value);
          final maxYP = max(shape.p1.y.value, shape.p2.y.value);
          if (minXP < minX) minX = minXP;
          if (minYP < minY) minY = minYP;
          if (maxXP > maxX) maxX = maxXP;
          if (maxYP > maxY) maxY = maxYP;
        }
      }
    }

    if (minX == double.infinity) {
      // Nothing to draw -- fall back to a default frame.
      minX = 0;
      minY = 0;
      maxX = 1920;
      maxY = 1080;
    } else {
      // Same 200-unit padding the SVG exporter applies.
      minX -= 200;
      minY -= 200;
      maxX += 200;
      maxY += 200;
    }

    final double width = maxX - minX;
    final double height = maxY - minY;

    if (width <= 0 || height <= 0) return null;

    final int pixelW = (width * scale).ceil();
    final int pixelH = (height * scale).ceil();

    // ---- 2. Record the artwork into an offscreen picture ----
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Map artwork space -> pixel space: scale up, then shift the bbox origin to 0.
    canvas.scale(scale);
    canvas.translate(-minX, -minY);

    // Draw each visible layer exactly as CompassRenderer does for the master
    // boolean fill/stroke, minus all scaffolding.
    for (var layer in engine.layers) {
      if (!layer.isVisible) continue;

      final layerPath = layer.getLayerPath();

      if (layer.color != Colors.transparent) {
        final fillPaint = Paint()
          ..color = layer.color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
        canvas.drawPath(layerPath, fillPaint);
      }

      if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
        final strokePaint = Paint()
          ..color = layer.strokeColor
          ..strokeWidth = layer.strokeWidth
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true;
        canvas.drawPath(layerPath, strokePaint);
      }

      // getLayerPath() skips shapes with no fill area or operation == none, so
      // pure stroke geometry (lines, and spirals which default to `none`) must
      // be stroked separately to keep PNG parity with the SVG export. We draw
      // only the `add` shapes here, matching the SVG add-shapes loop.
      if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
        final extraStroke = Paint()
          ..color = layer.strokeColor
          ..strokeWidth = layer.strokeWidth
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true;

        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue;
          if (shape is CompassLine && shape.operation == CompassBooleanOp.add) {
            canvas.drawLine(
              Offset(shape.start.x.value, shape.start.y.value),
              Offset(shape.end.x.value, shape.end.y.value),
              extraStroke,
            );
          } else if (shape is CompassSpiral) {
            // Spirals are construction-style (operation defaults to none) and
            // are never part of the boolean fill, so always stroke them.
            canvas.drawPath(shape.getPath(), extraStroke);
          }
        }
      }
    }

    // ---- 3. Rasterize and PNG-encode ----
    final picture = recorder.endRecording();
    final image = await picture.toImage(pixelW, pixelH);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    image.dispose();
    picture.dispose();

    return byteData?.buffer.asUint8List();
  }
}