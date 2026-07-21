// /lib/io/png_exporter.dart

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../engine.dart';
import '../models/layer.dart';    
import '../models/geometry/shape.dart';
import '../models/geometry/line.dart';
import '../models/geometry/circle.dart';
import '../models/geometry/spiral.dart';
import '../models/geometry/rectangle.dart';
import '../models/geometry/rhombus.dart'; 
import '../models/geometry/spline.dart';
import '../models/geometry/mesh.dart';
import '../models/geometry/gradient.dart'; 

enum PngExportStyle { standard, dithered, bubbleJet }

/// Rasterizes the pure artwork (no scaffolding) to a PNG by re-rendering the
/// model offscreen. Mirrors SVGExporter's philosophy: export the *design*, not
/// the editor. The bounding-box math and the per-layer fill/stroke/boolean draw
/// are kept deliberately parallel to SVGExporter and CompassRenderer so the
/// three outputs stay visually consistent.
class PNGExporter {
  /// The outermost radius reached by a circle's OUTWARD-STACKED stroke stack.
  static double _circleStrokeOuterRadius(CompassCircle circle, CompassLayer layer) {
    double offset = 0.0;
    for (final region in circle.strokeRegions) {
      if (region.width <= 0) continue;
      offset += region.width;
    }
    return circle.radius.value + offset;
  }

  /// Renders the engine to PNG bytes at the given pixel scale (1.0 = artwork's
  /// natural logical size, 2.0 = double resolution, etc).
  static Future<Uint8List?> toPNG(
    CompassEngine engine, {
    double scale = 2.0,
    PngExportStyle style = PngExportStyle.standard,
    bool grayscale = false,
    double bubbleSize = 8.0,
  }) async {
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

    // Widen the bounding box to include their full visual extent.
    for (var layer in engine.layers) {
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;
        if (shape is CompassCircle) {
          final r = shape.radius.value;
          final effR = max(r, _circleStrokeOuterRadius(shape, layer));
          final cx = shape.center.x.value;
          final cy = shape.center.y.value;
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
          final px1 = shape.p1.x.value; final py1 = shape.p1.y.value;
          final px2 = shape.p2.x.value; final py2 = shape.p2.y.value;
          final px3 = shape.p3.x.value; final py3 = shape.p3.y.value;
          final px4 = shape.p4.x.value; final py4 = shape.p4.y.value;
          
          if (min(min(px1, px2), min(px3, px4)) < minX) minX = min(min(px1, px2), min(px3, px4));
          if (min(min(py1, py2), min(py3, py4)) < minY) minY = min(min(py1, py2), min(py3, py4));
          if (max(max(px1, px2), max(px3, px4)) > maxX) maxX = max(max(px1, px2), max(px3, px4));
          if (max(max(py1, py2), max(py3, py4)) > maxY) maxY = max(max(py1, py2), max(py3, py4));
        } else if (shape is CompassXSpline) {
          if (shape.hasWidthProfile) {
            final bounds = shape.getPath().getBounds();
            if (bounds.left < minX) minX = bounds.left;
            if (bounds.top < minY) minY = bounds.top;
            if (bounds.right > maxX) maxX = bounds.right;
            if (bounds.bottom > maxY) maxY = bounds.bottom;
          }
        } else if (shape is CompassMesh) {
          final bounds = shape.getBounds();
          if (bounds.left < minX) minX = bounds.left;
          if (bounds.top < minY) minY = bounds.top;
          if (bounds.right > maxX) maxX = bounds.right;
          if (bounds.bottom > maxY) maxY = bounds.bottom;
        }
      }
    }

    if (minX == double.infinity) {
      minX = 0; minY = 0; maxX = 1920; maxY = 1080;
    } else {
      minX -= 200; minY -= 200; maxX += 200; maxY += 200;
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

    for (var layer in engine.layers) {
      if (!layer.isVisible) continue;

      final fillPath = layer.getLayerFillPath();
      final layerPath = layer.getLayerPath();
      final strokeAreaPath = layer.getLayerStrokeAreaPath();

      // 1a. Fill Standard Geometry
      if (layer.color != Colors.transparent) {
        final fillPaint = Paint()
          ..color = layer.color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
        canvas.drawPath(fillPath, fillPaint);
      }

      // 1a'. Per-shape LINEAR FILL GRADIENTS
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;
        if (!CompassLayer.hasLiftedGradientFill(shape)) continue;

        final g = shape.gradient!;
        final clip = layer.getLayerGradientClipPath(shape);
        if (clip.computeMetrics().isEmpty) continue;

        final gradPaint = Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.fill;

        final shader = g.buildShader();
        if (shader != null) {
          gradPaint.shader = shader; 
        } else {
          final solid = g.solidColor; 
          if (solid == null) continue; 
          gradPaint.color = solid;
        }

        canvas.drawPath(clip, gradPaint);

        if (layer.mirrorEnabled) {
          canvas.save();
          canvas.transform(layer.mirrorMatrix.storage);
          canvas.drawPath(clip, gradPaint);
          canvas.restore();
        }
      }

      // 1b. Stroke Standard Geometry
      if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
        final strokePaint = Paint()
          ..color = layer.strokeColor
          ..strokeWidth = layer.strokeWidth
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true;
          
        canvas.drawPath(layerPath, strokePaint);
      }

      // 1c. Area Strokes
      if (layer.strokeColor != Colors.transparent) {
        final areaStrokePaint = Paint()
          ..color = layer.strokeColor
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
        canvas.drawPath(strokeAreaPath, areaStrokePaint);
      }

      // 1c'. Colored stroke ADD-band overpaints
      if (layer.color != Colors.transparent) {
        final overpaints = layer.getStrokeAddBandOverpaints(fillPath);
        for (final (bandPath, bandColor) in overpaints) {
          final bandPaint = Paint()
            ..color = bandColor
            ..style = PaintingStyle.fill
            ..isAntiAlias = true;
          canvas.drawPath(bandPath, bandPaint);
        }
      }

      // 1d. Gradient Meshes
      for (var shape in layer.shapes) {
        if (shape is! CompassMesh) continue;
        if (!shape.isVisible) continue;
        if (shape.rows < 2 || shape.cols < 2) continue;

        final clip = layer.getLayerMeshClipPath(shape);
        if (clip.computeMetrics().isEmpty) continue;

        canvas.save();
        canvas.clipPath(clip);
        final meshPaint = Paint()
          ..isAntiAlias = true
          ..color = Colors.white;
        canvas.drawVertices(shape.buildVertices(), BlendMode.modulate, meshPaint);
        canvas.restore();

        if (layer.mirrorEnabled) {
          canvas.save();
          canvas.transform(layer.mirrorMatrix.storage);
          canvas.clipPath(clip);
          canvas.drawVertices(shape.buildVertices(), BlendMode.modulate, meshPaint);
          canvas.restore();
        }
      }

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
            canvas.drawPath(shape.getPath(), extraStroke);
          }
        }
      }
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(pixelW, pixelH);

    // Fast Path: Pure vector rendering (Standard + Color)
    if (style == PngExportStyle.standard && !grayscale) {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return byteData?.buffer.asUint8List();
    }

    // ---- 3. Image Filtering Passes (Dither / BubbleJet / Grayscale) ----
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      image.dispose();
      return null;
    }
    final bytes = byteData.buffer.asUint8List();
    
    ui.Image finalImage;

    if (style == PngExportStyle.bubbleJet) {
      finalImage = await _renderBubbleJet(bytes, pixelW, pixelH, bubbleSize, grayscale);
    } else {
      final modifiedBytes = _processPixels(bytes, pixelW, pixelH, style == PngExportStyle.dithered, grayscale);
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(modifiedBytes, pixelW, pixelH, ui.PixelFormat.rgba8888, (img) {
        completer.complete(img);
      });
      finalImage = await completer.future;
    }

    final finalByteData = await finalImage.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    finalImage.dispose();

    return finalByteData?.buffer.asUint8List();
  }

  // Applies Grayscale conversion and optional Floyd-Steinberg Dithering
  // Now preserves original Alpha transparency.
  static Uint8List _processPixels(Uint8List raw, int width, int height, bool dither, bool grayscale) {
    final int len = width * height;
    final rF = Float32List(len);
    final gF = Float32List(len);
    final bF = Float32List(len);
    final aF = Float32List(len);

    for (int i = 0; i < len; i++) {
      rF[i] = raw[i * 4].toDouble();
      gF[i] = raw[i * 4 + 1].toDouble();
      bF[i] = raw[i * 4 + 2].toDouble();
      aF[i] = raw[i * 4 + 3].toDouble();

      if (grayscale && aF[i] > 0) {
        final lum = 0.299 * rF[i] + 0.587 * gF[i] + 0.114 * bF[i];
        rF[i] = gF[i] = bF[i] = lum;
      }
    }

    final out = Uint8List(len * 4);

    if (!dither) {
      for (int i = 0; i < len; i++) {
        out[i * 4] = rF[i].clamp(0, 255).toInt();
        out[i * 4 + 1] = gF[i].clamp(0, 255).toInt();
        out[i * 4 + 2] = bF[i].clamp(0, 255).toInt();
        out[i * 4 + 3] = aF[i].clamp(0, 255).toInt();
      }
      return out;
    }

    // Floyd-Steinberg Pass
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final i = y * width + x;
        final alpha = aF[i].clamp(0, 255).toInt();
        
        out[i * 4 + 3] = alpha;

        // Skip completely transparent pixels
        if (alpha == 0) {
          out[i * 4] = 0;
          out[i * 4 + 1] = 0;
          out[i * 4 + 2] = 0;
          continue;
        }

        final oldR = rF[i];
        final oldG = gF[i];
        final oldB = bF[i];

        // 1-Bit per channel quantization
        final newR = oldR < 128 ? 0.0 : 255.0;
        final newG = oldG < 128 ? 0.0 : 255.0;
        final newB = oldB < 128 ? 0.0 : 255.0;

        out[i * 4] = newR.toInt();
        out[i * 4 + 1] = newG.toInt();
        out[i * 4 + 2] = newB.toInt();

        final errR = oldR - newR;
        final errG = oldG - newG;
        final errB = oldB - newB;

        void distribute(int dx, int dy, double weight) {
          final nx = x + dx;
          final ny = y + dy;
          if (nx >= 0 && nx < width && ny >= 0 && ny < height) {
            final ni = ny * width + nx;
            // Only push error to pixels that have some opacity
            if (aF[ni] > 0) {
              rF[ni] += errR * weight;
              gF[ni] += errG * weight;
              bF[ni] += errB * weight;
            }
          }
        }

        distribute(1, 0, 7 / 16);
        distribute(-1, 1, 3 / 16);
        distribute(0, 1, 5 / 16);
        distribute(1, 1, 1 / 16);
      }
    }
    return out;
  }

  // Translates pixels into variable-sized dots (Halftone style)
  // Preserves alpha channel through weighted averaging.
  static Future<ui.Image> _renderBubbleJet(Uint8List raw, int width, int height, double bubbleSize, bool grayscale) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final int step = bubbleSize.round();

    for (int y = 0; y < height; y += step) {
      for (int x = 0; x < width; x += step) {
        int rSum = 0, gSum = 0, bSum = 0, aSum = 0, count = 0;

        // Sample the regional block
        for (int dy = 0; dy < step && y + dy < height; dy++) {
          for (int dx = 0; dx < step && x + dx < width; dx++) {
            final i = ((y + dy) * width + (x + dx)) * 4;
            final alpha = raw[i + 3];
            
            // Weight color accumulation by alpha to ignore transparent void
            rSum += raw[i] * alpha;
            gSum += raw[i + 1] * alpha;
            bSum += raw[i + 2] * alpha;
            aSum += alpha;
            count++;
          }
        }

        if (count == 0 || aSum == 0) continue;

        final aAvg = (aSum / count).round();
        // Retrieve true average color of visible pixels
        final rAvg = (rSum / aSum).round();
        final gAvg = (gSum / aSum).round();
        final bAvg = (bSum / aSum).round();
        
        final lum = 0.299 * rAvg + 0.587 * gAvg + 0.114 * bAvg;

        // Halftone math: Darker regions result in larger bubbles
        final radius = (bubbleSize / 2.0) * (1.0 - (lum / 255.0));

        if (radius > 0.3) {
          Color c = grayscale 
              ? Color.fromRGBO(0, 0, 0, aAvg / 255.0) // Black ink, regional opacity
              : Color.fromRGBO(rAvg, gAvg, bAvg, aAvg / 255.0); // Colored ink, regional opacity

          canvas.drawCircle(
            Offset(x + step / 2.0, y + step / 2.0),
            radius,
            Paint()..color = c..isAntiAlias = true
          );
        }
      }
    }

    final picture = recorder.endRecording();
    return picture.toImage(width, height);
  }
}