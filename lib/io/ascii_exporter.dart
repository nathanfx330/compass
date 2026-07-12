// /lib/io/ascii_exporter.dart

import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../engine.dart';
import '../models/geometry/shape.dart';
import '../models/geometry/line.dart';
import '../models/geometry/circle.dart';
import '../models/geometry/spiral.dart'; // <--- FIXED: Added missing import
import '../models/geometry/rectangle.dart';
import '../models/geometry/rhombus.dart';
import '../models/geometry/spline.dart';
import '../models/geometry/mesh.dart';

class ASCIIExporter {
  // <--- CHANGED: High-fidelity 70-character ASCII ramp for better shading --->
  static const String _ramp = " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@\$";

  static double _circleStrokeOuterRadius(CompassCircle circle) {
    double offset = 0.0;
    for (final region in circle.strokeRegions) {
      if (region.width <= 0) continue;
      offset += region.width;
    }
    return circle.radius.value + offset;
  }

  static Future<String?> toASCII(
    CompassEngine engine, {
    int columns = 100,
    bool invert = false,
    double fontAspectRatio = 0.45, // <--- NEW: Dynamic Aspect Ratio
  }) async {
    // ---- 1. Compute the artwork bounding box ----
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (var p in engine.points) {
      if (p.x.value < minX) minX = p.x.value;
      if (p.y.value < minY) minY = p.y.value;
      if (p.x.value > maxX) maxX = p.x.value;
      if (p.y.value > maxY) maxY = p.y.value;
    }

    for (var layer in engine.layers) {
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;
        if (shape is CompassCircle) {
          final effR = max(shape.radius.value, _circleStrokeOuterRadius(shape));
          final cx = shape.center.x.value, cy = shape.center.y.value;
          if (cx - effR < minX) minX = cx - effR;
          if (cy - effR < minY) minY = cy - effR;
          if (cx + effR > maxX) maxX = cx + effR;
          if (cy + effR > maxY) maxY = cy + effR;
        } else if (shape is CompassRectangle) {
          final minXP = min(shape.p1.x.value, shape.p2.x.value);
          final minYP = min(shape.p1.y.value, shape.p2.y.value);
          final maxXP = max(shape.p1.x.value, shape.p2.x.value);
          final maxYP = max(shape.p1.y.value, shape.p2.y.value);
          if (minXP < minX) minX = minXP;
          if (minYP < minY) minY = minYP;
          if (maxXP > maxX) maxX = maxXP;
          if (maxYP > maxY) maxY = maxYP;
        } else if (shape is CompassRhombus) {
          final px1 = shape.p1.x.value, py1 = shape.p1.y.value;
          final px2 = shape.p2.x.value, py2 = shape.p2.y.value;
          final px3 = shape.p3.x.value, py3 = shape.p3.y.value;
          final px4 = shape.p4.x.value, py4 = shape.p4.y.value;
          if (min(min(px1, px2), min(px3, px4)) < minX) minX = min(min(px1, px2), min(px3, px4));
          if (min(min(py1, py2), min(py3, py4)) < minY) minY = min(min(py1, py2), min(py3, py4));
          if (max(max(px1, px2), max(px3, px4)) > maxX) maxX = max(max(px1, px2), max(px3, px4));
          if (max(max(py1, py2), max(py3, py4)) > maxY) maxY = max(max(py1, py2), max(py3, py4));
        } else if (shape is CompassXSpline && shape.hasWidthProfile) {
          final bounds = shape.getPath().getBounds();
          if (bounds.left < minX) minX = bounds.left;
          if (bounds.top < minY) minY = bounds.top;
          if (bounds.right > maxX) maxX = bounds.right;
          if (bounds.bottom > maxY) maxY = bounds.bottom;
        } else if (shape is CompassMesh) {
          final bounds = shape.getBounds();
          if (bounds.left < minX) minX = bounds.left;
          if (bounds.top < minY) minY = bounds.top;
          if (bounds.right > maxX) maxX = bounds.right;
          if (bounds.bottom > maxY) maxY = bounds.bottom;
        }
      }
    }

    if (minX == double.infinity) return null;

    minX -= 50; minY -= 50; maxX += 50; maxY += 50;
    final double width = maxX - minX;
    final double height = maxY - minY;
    if (width <= 0 || height <= 0) return null;

    // ---- 2. Map coordinates to a text grid ----
    // Font characters are typically roughly twice as tall as they are wide.
    // <--- CHANGED: Use the user-defined aspect ratio instead of a hardcoded 0.45 --->
    final int rows = (height / width * columns * fontAspectRatio).ceil();
    if (rows <= 0) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Fill with solid white background to make luminance calculations reliable
    canvas.drawRect(Rect.fromLTWH(0, 0, columns.toDouble(), rows.toDouble()), Paint()..color = Colors.white);

    // Apply independent X and Y scales so the vector math squishes into the font grid perfectly
    canvas.scale(columns / width, rows / height);
    canvas.translate(-minX, -minY);

    // ---- 3. Draw Geometry ----
    for (var layer in engine.layers) {
      if (!layer.isVisible) continue;

      final fillPath = layer.getLayerFillPath();
      final layerPath = layer.getLayerPath();
      final strokeAreaPath = layer.getLayerStrokeAreaPath();

      if (layer.color != Colors.transparent) {
        canvas.drawPath(fillPath, Paint()..color = layer.color..style = PaintingStyle.fill..isAntiAlias = false);
      }
      if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
        canvas.drawPath(layerPath, Paint()..color = layer.strokeColor..strokeWidth = layer.strokeWidth..style = PaintingStyle.stroke..isAntiAlias = false);
      }
      if (layer.strokeColor != Colors.transparent) {
        canvas.drawPath(strokeAreaPath, Paint()..color = layer.strokeColor..style = PaintingStyle.fill..isAntiAlias = false);
      }
      if (layer.color != Colors.transparent) {
        final overpaints = layer.getStrokeAddBandOverpaints(fillPath);
        for (final (bandPath, bandColor) in overpaints) {
          canvas.drawPath(bandPath, Paint()..color = bandColor..style = PaintingStyle.fill..isAntiAlias = false);
        }
      }
      
      for (var shape in layer.shapes) {
        if (shape is! CompassMesh || !shape.isVisible || shape.rows < 2 || shape.cols < 2) continue;
        final clip = layer.getLayerMeshClipPath(shape);
        if (clip.computeMetrics().isEmpty) continue;
        canvas.save();
        canvas.clipPath(clip);
        canvas.drawVertices(shape.buildVertices(), BlendMode.modulate, Paint()..color = Colors.white..isAntiAlias = false);
        canvas.restore();
      }
      
      if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
        final extraStroke = Paint()..color = layer.strokeColor..strokeWidth = layer.strokeWidth..style = PaintingStyle.stroke..isAntiAlias = false;
        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue;
          if (shape is CompassLine && shape.operation == CompassBooleanOp.add) {
            canvas.drawLine(Offset(shape.start.x.value, shape.start.y.value), Offset(shape.end.x.value, shape.end.y.value), extraStroke);
          } else if (shape is CompassSpiral) {
            canvas.drawPath(shape.getPath(), extraStroke);
          }
        }
      }
    }

    // ---- 4. Convert pixels to ASCII ----
    final picture = recorder.endRecording();
    final image = await picture.toImage(columns, rows);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba); // <--- FIXED: rawRgba
    image.dispose();
    picture.dispose();
    
    if (byteData == null) return null;
    final bytes = byteData.buffer.asUint8List();
    
    final StringBuffer sb = StringBuffer();
    final List<String> rampChars = invert ? _ramp.split('').reversed.toList() : _ramp.split('');
    final int rampMax = rampChars.length - 1;

    for (int y = 0; y < rows; y++) {
      for (int x = 0; x < columns; x++) {
        final int i = (y * columns + x) * 4;
        final int r = bytes[i];
        final int g = bytes[i + 1];
        final int b = bytes[i + 2];
        
        // Luminance formula (0 = black, 255 = white)
        final double lum = (0.299 * r + 0.587 * g + 0.114 * b);
        
        // Map brightness to the ASCII ramp (0 maps to thickest character, 255 to blank)
        final int charIndex = ((255.0 - lum) / 255.0 * rampMax).round().clamp(0, rampMax);
        sb.write(rampChars[charIndex]);
      }
      sb.writeln(); // Newline at the end of each row
    }

    return sb.toString();
  }
}