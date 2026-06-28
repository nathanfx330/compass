// lib/io/png_exporter.dart

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
import '../models/geometry/rhombus.dart'; // <--- NEW: rhombus
import '../models/geometry/spline.dart';
import '../models/geometry/mesh.dart';

/// Rasterizes the pure artwork (no scaffolding) to a PNG by re-rendering the
/// model offscreen. Mirrors SVGExporter's philosophy: export the *design*, not
/// the editor. The bounding-box math and the per-layer fill/stroke/boolean draw
/// are kept deliberately parallel to SVGExporter and CompassRenderer so the
/// three outputs stay visually consistent.
class PNGExporter {
  /// The outermost radius reached by a circle's OUTWARD-STACKED stroke stack.
  /// Walks the same cursor the layer's boolean walk uses: region 0 starts exactly
  /// at the shape's boundary (0.0), and each later band butts outward, adding its 
  /// full width. Returns the bare radius when the stack is empty. Shared by the 
  /// bbox math so the frame includes a fat stack of add-rings near the artwork edge.
  static double _circleStrokeOuterRadius(CompassCircle circle, CompassLayer layer) {
    double offset = 0.0;
    for (final region in circle.strokeRegions) {
      if (region.width <= 0) continue;
      offset += region.width;
    }
    return circle.radius.value + offset;
  }

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

    // Circles, rectangles, and thick Area Strokes extend past their defining points.
    // Widen the bounding box to include their full visual extent.
    for (var layer in engine.layers) {
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;
        if (shape is CompassCircle) {
          // A stroke stack bulges OUTWARD past the disk -- each band stacks on the
          // last, so the cumulative outer radius is the sum walk in
          // _circleStrokeOuterRadius (which reduces to r for an empty stack). Use
          // the larger of the disk radius and that outer reach. Only ADD bands
          // actually paint outside the disk -- a subtract/intersect band removes
          // area already inside it -- but widening for the whole stack's extent is
          // harmless (the margin is at most the summed widths) and keeps the rule
          // simple and order-independent.
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
          // <--- NEW: Rhombus bounds math
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
          // A mesh is bounded by its nodes (all in engine.points, so already
          // covered above) -- but its nodes can be dragged anywhere, and we want
          // parity with how the renderer would show them, so widen explicitly to
          // the mesh's own bounds. Cheap and keeps the frame correct even if the
          // point loop above is ever changed.
          final bounds = shape.getBounds();
          if (bounds.left < minX) minX = bounds.left;
          if (bounds.top < minY) minY = bounds.top;
          if (bounds.right > maxX) maxX = bounds.right;
          if (bounds.bottom > maxY) maxY = bounds.bottom;
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

      // fillPath includes closed width-spline centerlines (matching the renderer's
      // step 1a); layerPath excludes width splines and remains the target of the
      // uniform stroke (1b), so no hairline runs along a ribbon's inner edge.
      // Both now also fold in each shape's whole stroke STACK (all regions, in
      // order, before the fill op), so a stroke-subtract gap -- or concentric
      // tree-rings -- is baked into fillPath here with no extra handling.
      final fillPath = layer.getLayerFillPath();
      final layerPath = layer.getLayerPath();
      final strokeAreaPath = layer.getLayerStrokeAreaPath();

      // 1a. Fill Standard Geometry (sourced from the fill path)
      if (layer.color != Colors.transparent) {
        final fillPaint = Paint()
          ..color = layer.color
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
        canvas.drawPath(fillPath, fillPaint);
      }

      // 1b. Stroke Standard Geometry (Uniform outlines)
      if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
        final strokePaint = Paint()
          ..color = layer.strokeColor
          ..strokeWidth = layer.strokeWidth
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true;
          
        canvas.drawPath(layerPath, strokePaint);
      }

      // 1c. Area Strokes (Variable-Width Geometry)
      if (layer.strokeColor != Colors.transparent) {
        final areaStrokePaint = Paint()
          ..color = layer.strokeColor
          ..style = PaintingStyle.fill
          ..isAntiAlias = true;
        canvas.drawPath(strokeAreaPath, areaStrokePaint);
      }

      // 1c'. Colored stroke ADD-band overpaints -- the exact mirror of the canvas
      // renderer's step 1c'. Each colored add band was unioned into fillPath above
      // and thus painted in the LAYER fill color in 1a; here we repaint each in its
      // OWN color, on top, in stack order. The band paths come back already
      // intersected with fillPath, so a band carved by a shape above it paints only
      // where it survives and color can't bleed into a gap. Null-color add bands are
      // NOT in this list (they ride the layer color), so nothing double-paints. Done
      // after the flat fill/stroke but before the mesh pass, keeping a gradient mesh
      // above its layer's solid geometry as on-canvas.
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

      // 1d. Gradient Meshes -- mirrors the renderer's mesh pass exactly: each mesh
      // paints its interpolated color field via drawVertices, clipped to its
      // boolean-carved silhouette, after this layer's flat fills. save/restore
      // scopes the clip so it can't leak onto the next mesh or layer. Same
      // BlendMode.modulate + white paint as on-canvas, so the authored vertex
      // colors render identically between screen and PNG.
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