// lib/io/svg_exporter.dart

import 'dart:math';
import 'package:flutter/material.dart';

import '../engine.dart';
import '../models/geometry/shape.dart';
import '../models/geometry/line.dart';
import '../models/geometry/circle.dart';
import '../models/geometry/spiral.dart';
import '../models/geometry/spline.dart';
import '../models/geometry/rectangle.dart';

class SVGExporter {
  static String sanitizeId(String rawId) {
    return rawId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
  }

  static String toSVG(CompassEngine engine) {
    final buffer = StringBuffer();

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

    for (var layer in engine.layers) {
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;
        if (shape is CompassCircle) {
           double r = shape.radius.value;
           double cx = shape.center.x.value;
           double cy = shape.center.y.value;
           if (cx - r < minX) minX = cx - r;
           if (cy - r < minY) minY = cy - r;
           if (cx + r > maxX) maxX = cx + r;
           if (cy + r > maxY) maxY = cy + r;
        } else if (shape is CompassRectangle) { 
           double minXP = min(shape.p1.x.value, shape.p2.x.value);
           double minYP = min(shape.p1.y.value, shape.p2.y.value);
           double maxXP = max(shape.p1.x.value, shape.p2.x.value);
           double maxYP = max(shape.p1.y.value, shape.p2.y.value);
           if (minXP < minX) minX = minXP;
           if (minYP < minY) minY = minYP;
           if (maxXP > maxX) maxX = maxXP;
           if (maxYP > maxY) maxY = maxYP;
        } else if (shape is CompassXSpline) {
           // A variable-width ribbon bulges past its node points; include its full
           // visual extent so the viewBox can't clip it. Mirrors the PNG exporter.
           // (A non-width spline is bounded by its points, already covered above.)
           if (shape.hasWidthProfile) {
             final bounds = shape.getPath().getBounds();
             if (bounds.left < minX) minX = bounds.left;
             if (bounds.top < minY) minY = bounds.top;
             if (bounds.right > maxX) maxX = bounds.right;
             if (bounds.bottom > maxY) maxY = bounds.bottom;
           }
        }
      }
    }

    if (minX == double.infinity) {
      minX = 0; minY = 0; maxX = 1920; maxY = 1080;
    } else {
      minX -= 200; minY -= 200; maxX += 200; maxY += 200;
    }

    double width = maxX - minX;
    double height = maxY - minY;

    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buffer.writeln('<svg xmlns="http://www.w3.org/2000/svg" viewBox="$minX $minY $width $height">');

    String toHex(Color c) {
      if (c == Colors.transparent) return 'none';
      return '#${c.value.toRadixString(16).substring(2, 8).toUpperCase()}';
    }

    for (var layer in engine.layers) {
      if (!layer.isVisible) continue;

      final fillHex = toHex(layer.color);
      final strokeHex = toHex(layer.strokeColor);
      final sWidth = layer.strokeWidth;
      final cleanLayerId = sanitizeId(layer.id);

      final addShapes = layer.shapes.where((s) => s.isVisible && s.operation == CompassBooleanOp.add).toList();
      final subShapes = layer.shapes.where((s) => s.isVisible && s.operation == CompassBooleanOp.subtract).toList();

      buffer.writeln('  <!-- Layer: ${layer.name} -->');
      
      if (subShapes.isNotEmpty) {
        final maskId = 'mask_$cleanLayerId';
        buffer.writeln('  <defs>');
        buffer.writeln('    <mask id="$maskId" maskUnits="userSpaceOnUse" x="$minX" y="$minY" width="$width" height="$height">');
        
        buffer.writeln('      <rect x="$minX" y="$minY" width="$width" height="$height" fill="white" />');
        
        for (var shape in subShapes) {
          if (shape is CompassCircle) {
            buffer.writeln('      <circle cx="${shape.center.x.value}" cy="${shape.center.y.value}" r="${shape.radius.value}" fill="black" />');
          } else if (shape is CompassRectangle) { 
            final rect = Rect.fromPoints(Offset(shape.p1.x.value, shape.p1.y.value), Offset(shape.p2.x.value, shape.p2.y.value));
            buffer.writeln('      <rect x="${rect.left}" y="${rect.top}" width="${rect.width}" height="${rect.height}" rx="${shape.cornerRadius.value}" ry="${shape.cornerRadius.value}" fill="black" />');
          } else if (shape is CompassXSpline) {
            buffer.writeln('      <path d="${shape.getSvgPathData()}" fill="black" fill-rule="evenodd" />');
          }
        }
        
        buffer.writeln('    </mask>');
        buffer.writeln('  </defs>');
        
        buffer.writeln('  <g mask="url(#$maskId)">');
      } else {
        buffer.writeln('  <g>');
      }

      for (var shape in addShapes) {
        if (shape is CompassCircle) {
          buffer.writeln('    <circle cx="${shape.center.x.value}" cy="${shape.center.y.value}" r="${shape.radius.value}" fill="$fillHex" stroke="$strokeHex" stroke-width="$sWidth" />');
        } else if (shape is CompassLine) {
          buffer.writeln('    <line x1="${shape.start.x.value}" y1="${shape.start.y.value}" x2="${shape.end.x.value}" y2="${shape.end.y.value}" stroke="$strokeHex" stroke-width="$sWidth" />');
        } else if (shape is CompassSpiral) {
          final metrics = shape.getPath().computeMetrics();
          buffer.write('    <path d="');
          for (var metric in metrics) {
             for (double d = 0.0; d < metric.length; d += 2.0) {
               final pos = metric.getTangentForOffset(d)?.position;
               if (pos != null) {
                 if (d == 0.0) buffer.write('M ${pos.dx} ${pos.dy} ');
                 else buffer.write('L ${pos.dx} ${pos.dy} ');
               }
             }
          }
          buffer.writeln('" fill="none" stroke="$strokeHex" stroke-width="$sWidth" />');
        } else if (shape is CompassRectangle) { 
          final rect = Rect.fromPoints(Offset(shape.p1.x.value, shape.p1.y.value), Offset(shape.p2.x.value, shape.p2.y.value));
          buffer.writeln('    <rect x="${rect.left}" y="${rect.top}" width="${rect.width}" height="${rect.height}" rx="${shape.cornerRadius.value}" ry="${shape.cornerRadius.value}" fill="$fillHex" stroke="$strokeHex" stroke-width="$sWidth" />');
        } else if (shape is CompassXSpline) {
          // NEW: Distinguish between standard strokes/fills and variable-width Area Strokes
          if (shape.hasWidthProfile) {
            // A CLOSED width spline is now a first-class stroke: its centerline
            // region is an inner fill (fill color), with the variable-width ribbon
            // (stroke color) drawn ON TOP. Emit the centerline fill first so the
            // ribbon paints over it, matching the renderer's z-order (fill in 1a,
            // area stroke in 1c). Gate on a real fill color, mirroring the renderer's
            // `if (layer.color != Colors.transparent)`. An OPEN width spline encloses
            // no area, so it gets only the ribbon.
            if (shape.isClosed && fillHex != 'none') {
              buffer.writeln('    <path d="${shape.getCenterSvgPathData()}" fill="$fillHex" fill-rule="evenodd" stroke="none" />');
            }
            buffer.writeln('    <path d="${shape.getSvgPathData()}" fill="$strokeHex" fill-rule="evenodd" stroke="none" />');
          } else {
            buffer.writeln('    <path d="${shape.getSvgPathData()}" fill="${shape.isClosed ? fillHex : 'none'}" fill-rule="evenodd" stroke="$strokeHex" stroke-width="$sWidth" />');
          }
        }
      }

      buffer.writeln('  </g>');
    }

    buffer.writeln('</svg>');
    return buffer.toString();
  }
}