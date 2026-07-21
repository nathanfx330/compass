// /lib/io/svg_exporter.dart

import 'dart:math';
import 'package:flutter/material.dart';

import '../engine.dart';
import '../models/layer.dart';           
import '../models/geometry/shape.dart';
import '../models/geometry/line.dart';
import '../models/geometry/circle.dart';
import '../models/geometry/spiral.dart';
import '../models/geometry/spline.dart';
import '../models/geometry/rectangle.dart';
import '../models/geometry/rhombus.dart'; 
import '../models/geometry/mesh.dart'; 
import '../models/geometry/gradient.dart'; // <--- NEW: Import gradient model

class SVGExporter {
  static String sanitizeId(String rawId) {
    return rawId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
  }

  // Number of sub-cells per patch edge when faceting a mesh to flat polygons.
  // Higher than the canvas/PNG drawVertices default (8): there, each sub-quad is
  // Gouraud-interpolated, so 8 already looks smooth; HERE each sub-quad is a SINGLE
  // FLAT color, so smoothness comes only from making the facets smaller. 16 keeps
  // the file reasonable while reading as a smooth gradient at typical sizes.
  static const int _meshSvgSubdivisions = 16;

  // The mirror modifier as an SVG transform string, applied to a <use> that
  // instantiates the layer's rendered content group. This is the SVG counterpart
  // of CompassLayer.mirrorMatrix, and reproduces the SAME reflection the renderer
  // replays through canvas.transform(mirrorMatrix.storage): because the whole
  // content group is reflected as a unit, masks (mask="url(#..)", userSpaceOnUse),
  // linearGradients (userSpaceOnUse), and mesh clip paths all reflect WITH the
  // geometry -- the clip/shader axis maps together exactly as on the raster side.
  //
  //   vertical axis at x=p:   x' = 2p - x  -> matrix(-1 0 0 1 2p 0)
  //   horizontal axis at y=p: y' = 2p - y  -> matrix(1 0 0 -1 0 2p)
  //
  // Derived straight from mirrorAxis + mirrorPosition; no Matrix4 needed. The
  // reflected half can extend past the viewBox and be clipped there -- this
  // matches the PNG exporter, whose bbox likewise doesn't account for the mirror,
  // so the two raster/vector outputs stay consistent. (Widening the frame for the
  // mirror is a separate, cross-exporter change if ever wanted.)
  static String _mirrorTransform(CompassLayer layer) {
    final p = layer.mirrorPosition;
    if (layer.mirrorAxis == MirrorAxis.vertical) {
      return 'matrix(-1 0 0 1 ${2 * p} 0)';
    } else {
      return 'matrix(1 0 0 -1 0 ${2 * p})';
    }
  }

  // Flatten an arbitrary Path to an SVG path `d` string by walking its metrics.
  // Used for a mesh's boolean-carve clipPath, where the carved silhouette is an
  // opaque combined Path with no algebraic SVG form. 2.0-unit sampling matches the
  // spiral exporter's stepping.
  static String _pathToSvgData(Path path) {
    final sb = StringBuffer();
    for (final metric in path.computeMetrics()) {
      bool first = true;
      for (double d = 0.0; d < metric.length; d += 2.0) {
        final pos = metric.getTangentForOffset(d)?.position;
        if (pos == null) continue;
        if (first) {
          sb.write('M ${pos.dx} ${pos.dy} ');
          first = false;
        } else {
          sb.write('L ${pos.dx} ${pos.dy} ');
        }
      }
      if (!first) sb.write('Z ');
    }
    return sb.toString().trim();
  }

  // ONE band of a circle's stroke stack as an even-odd two-circle SVG path `d`
  // string: outer ring r + innerOffset + width, inner hole r + innerOffset (inner
  // omitted if the band reaches the center, matching
  // CompassCircle.getStrokeOutlinePath(width, innerOffset)). Used in BOTH roles --
  // black-fill geometry inside a subtract mask, and colored-fill geometry in the
  // add pass -- so the ring shape for a given band is defined once.
  static String _circleBandSvgData(
      CompassCircle circle, double width, double innerOffset) {
    final r = circle.radius.value;
    if (r <= 0 || width <= 0) return '';

    final cx = circle.center.x.value;
    final cy = circle.center.y.value;
    final inner = r + innerOffset;
    final outer = inner + width;
    if (outer <= 0) return '';

    // Two full circles via arc commands; even-odd makes the inner one a hole.
    final sb = StringBuffer();
    sb.write('M ${cx - outer} $cy ');
    sb.write('a $outer $outer 0 1 0 ${outer * 2} 0 ');
    sb.write('a $outer $outer 0 1 0 ${-outer * 2} 0 ');
    sb.write('Z ');
    if (inner > 0) {
      sb.write('M ${cx - inner} $cy ');
      sb.write('a $inner $inner 0 1 0 ${inner * 2} 0 ');
      sb.write('a $inner $inner 0 1 0 ${-inner * 2} 0 ');
      sb.write('Z ');
    }
    return sb.toString().trim();
  }

  // Walks a circle's OUTWARD-STACKED stroke stack, yielding (region, width,
  // innerOffset) for each region in order -- the single source of the stacking
  // geometry for the SVG exporter, mirroring CompassLayer's walk. Region 0 starts
  // exactly at the shape's boundary (0.0); each later region's inner edge is the 
  // previous band's outer edge. Zero-width regions are skipped.
  static List<({StrokeRegion region, double width, double innerOffset})>
      _circleStrokeBands(CompassCircle circle) {
    final out = <({StrokeRegion region, double width, double innerOffset})>[];
    double offset = 0.0;
    for (final region in circle.strokeRegions) {
      final w = region.width;
      if (w <= 0) continue;
      out.add((region: region, width: w, innerOffset: offset));
      offset += w;
    }
    return out;
  }

  // The outermost radius reached by a circle's stroke stack (for bbox widening),
  // mirroring the PNG exporter.
  static double _circleStrokeOuterRadius(CompassCircle circle) {
    double offset = 0.0;
    for (final region in circle.strokeRegions) {
      final w = region.width;
      if (w <= 0) continue;
      offset += w;
    }
    return circle.radius.value + offset;
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
           // Widen to the stroke stack's cumulative OUTER radius (parity with the
           // PNG exporter). Each band stacks outward, so this is the sum walk in
           // _circleStrokeOuterRadius (which reduces to r for an empty stack).
           double r = max(shape.radius.value, _circleStrokeOuterRadius(shape));
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
        } else if (shape is CompassMesh) {
           // Bounded by its nodes (already in the point loop), but widen explicitly
           // for parity with the PNG exporter and robustness if that loop changes.
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

    double width = maxX - minX;
    double height = maxY - minY;

    buffer.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    // xmlns:xlink is declared so the mirror <use> can carry BOTH href and
    // xlink:href -- modern renderers read href, older viewers / print RIPs /
    // Inkscape-era tooling read xlink:href. Emitting both is the safe superset.
    buffer.writeln('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="$minX $minY $width $height">');

    String toHex(Color c) {
      if (c == Colors.transparent) return 'none';
      return '#${c.value.toRadixString(16).substring(2, 8).toUpperCase()}';
    }

    // Opaque-hex (no 'none') for a specific vertex color, used by the mesh facets
    // and by colored stroke-add bands.
    String toHexOpaque(Color c) {
      return '#${c.value.toRadixString(16).substring(2, 8).toUpperCase()}';
    }

    for (var layer in engine.layers) {
      if (!layer.isVisible) continue;

      final fillHex = toHex(layer.color);
      final strokeHex = toHex(layer.strokeColor);
      final sWidth = layer.strokeWidth;
      final cleanLayerId = sanitizeId(layer.id);

      // The id of THIS layer's rendered content group. The mirror <use> below
      // references it to reflect the whole layer as a unit.
      final contentId = 'layer_${cleanLayerId}_content';

      final addShapes = layer.shapes.where((s) => s.isVisible && s.operation == CompassBooleanOp.add).toList();
      final subShapes = layer.shapes.where((s) => s.isVisible && s.operation == CompassBooleanOp.subtract).toList();

      // --- STROKE-STACK contributors (outline-as-boolean) ---
      final strokeCircles =
          layer.shapes.where((s) => s.isVisible && s is CompassCircle).cast<CompassCircle>().toList();
      bool circleHasSubtractBand(CompassCircle c) =>
          c.strokeRegions.any((r) => r.op == CompassBooleanOp.subtract && r.width > 0);
      final strokeSubCircles = strokeCircles.where(circleHasSubtractBand).toList();

      // Meshes are `add`, but they are NOT flat-fill shapes -- they're faceted in
      // their own pass below, so pull them out of the normal add-shapes loop (which
      // would otherwise iterate them and emit nothing).
      final meshShapes = addShapes.whereType<CompassMesh>().toList();
      addShapes.removeWhere((s) => s is CompassMesh);

      // --- NEW: Identify shapes that have a native LinearGradient Fill ---
      final gradShapes = addShapes.where((s) => CompassLayer.hasLiftedGradientFill(s)).toList();

      buffer.writeln('  <!-- Layer: ${layer.name} -->');

      // The defs block is needed if ANYTHING carves this layer (masks) OR if we have gradients.
      final bool needsMask = subShapes.isNotEmpty || strokeSubCircles.isNotEmpty;

      if (needsMask || gradShapes.isNotEmpty) {
        buffer.writeln('  <defs>');
        
        // Output Subtract Masks
        if (needsMask) {
          final maskId = 'mask_$cleanLayerId';
          buffer.writeln('    <mask id="$maskId" maskUnits="userSpaceOnUse" x="$minX" y="$minY" width="$width" height="$height">');
          buffer.writeln('      <rect x="$minX" y="$minY" width="$width" height="$height" fill="white" />');
          
          for (var shape in subShapes) {
            if (shape is CompassCircle) {
              buffer.writeln('      <circle cx="${shape.center.x.value}" cy="${shape.center.y.value}" r="${shape.radius.value}" fill="black" />');
            } else if (shape is CompassRectangle) { 
              final rect = Rect.fromPoints(Offset(shape.p1.x.value, shape.p1.y.value), Offset(shape.p2.x.value, shape.p2.y.value));
              buffer.writeln('      <rect x="${rect.left}" y="${rect.top}" width="${rect.width}" height="${rect.height}" rx="${shape.cornerRadius.value}" ry="${shape.cornerRadius.value}" fill="black" />');
            } else if (shape is CompassRhombus) {
              final pts = '${shape.p1.x.value},${shape.p1.y.value} ${shape.p2.x.value},${shape.p2.y.value} ${shape.p3.x.value},${shape.p3.y.value} ${shape.p4.x.value},${shape.p4.y.value}';
              buffer.writeln('      <polygon points="$pts" fill="black" />');
            } else if (shape is CompassXSpline) {
              buffer.writeln('      <path d="${shape.getSvgPathData()}" fill="black" fill-rule="evenodd" />');
            }
          }

          // Output Circle Subtract Strokes into the Mask
          for (var circle in strokeSubCircles) {
            for (final band in _circleStrokeBands(circle)) {
              if (band.region.op != CompassBooleanOp.subtract) continue;
              final d = _circleBandSvgData(circle, band.width, band.innerOffset);
              if (d.isNotEmpty) {
                buffer.writeln('      <path d="$d" fill="black" fill-rule="evenodd" />');
              }
            }
          }
          buffer.writeln('    </mask>');
        }

        // --- Output <linearGradient> Definitions ---
        for (int i = 0; i < gradShapes.length; i++) {
          final shape = gradShapes[i];
          final g = shape.gradient!;
          final gradId = 'grad_${cleanLayerId}_$i';
          
          final axis = g.axis;
          if (axis != null) {
            final a = axis.$1;
            final b = axis.$2;
            
            // gradientUnits="userSpaceOnUse" locks the gradient to our coordinate system mathematically
            buffer.writeln('    <linearGradient id="$gradId" x1="${a.dx}" y1="${a.dy}" x2="${b.dx}" y2="${b.dy}" gradientUnits="userSpaceOnUse">');
            
            final axisVec = b - a;
            final len2 = axisVec.dx * axisVec.dx + axisVec.dy * axisVec.dy;
            
            final resolved = <(double, Color)>[];
            for (final s in g.stops) {
              double t = 0.0;
              if (len2 >= 1e-9) {
                final rel = Offset(s.point.x.value, s.point.y.value) - a;
                t = ((rel.dx * axisVec.dx + rel.dy * axisVec.dy) / len2).clamp(0.0, 1.0);
              }
              resolved.add((t, s.color));
            }
            resolved.sort((x, y) => x.$1.compareTo(y.$1));
            
            for (final r in resolved) {
              buffer.writeln('      <stop offset="${(r.$1 * 100).toStringAsFixed(2)}%" stop-color="${toHexOpaque(r.$2)}" />');
            }
            
            buffer.writeln('    </linearGradient>');
          }
        }
        
        buffer.writeln('  </defs>');
      }
      
      // Apply the layer-wide Mask if it exists. The content group is ID'd so the
      // mirror <use> below can instantiate (and reflect) the whole layer -- mask,
      // gradients, meshes and all -- in one shot.
      if (needsMask) {
        final maskId = 'mask_$cleanLayerId';
        buffer.writeln('  <g id="$contentId" mask="url(#$maskId)">');
      } else {
        buffer.writeln('  <g id="$contentId">');
      }

      for (var shape in addShapes) {
        String shapeFillHex = fillHex;
        
        // Look up our Dynamic Fills (Gradient URL vs Base Hex Color)
        if (CompassLayer.hasLiftedGradientFill(shape)) {
          final idx = gradShapes.indexOf(shape);
          shapeFillHex = 'url(#grad_${cleanLayerId}_$idx)';
        } else if (shape.gradient != null && shape.gradient!.solidColor != null) {
          shapeFillHex = toHexOpaque(shape.gradient!.solidColor!);
        }

        if (shape is CompassCircle) {
          buffer.writeln('    <circle cx="${shape.center.x.value}" cy="${shape.center.y.value}" r="${shape.radius.value}" fill="$shapeFillHex" stroke="$strokeHex" stroke-width="$sWidth" />');
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
          buffer.writeln('    <rect x="${rect.left}" y="${rect.top}" width="${rect.width}" height="${rect.height}" rx="${shape.cornerRadius.value}" ry="${shape.cornerRadius.value}" fill="$shapeFillHex" stroke="$strokeHex" stroke-width="$sWidth" />');
        } else if (shape is CompassRhombus) {
          final pts = '${shape.p1.x.value},${shape.p1.y.value} ${shape.p2.x.value},${shape.p2.y.value} ${shape.p3.x.value},${shape.p3.y.value} ${shape.p4.x.value},${shape.p4.y.value}';
          buffer.writeln('    <polygon points="$pts" fill="$shapeFillHex" stroke="$strokeHex" stroke-width="$sWidth" />');
        } else if (shape is CompassXSpline) {
          if (shape.hasWidthProfile) {
            if (shape.isClosed && shapeFillHex != 'none') {
              buffer.writeln('    <path d="${shape.getCenterSvgPathData()}" fill="$shapeFillHex" fill-rule="evenodd" stroke="none" />');
            }
            buffer.writeln('    <path d="${shape.getSvgPathData()}" fill="$strokeHex" fill-rule="evenodd" stroke="none" />');
          } else {
            buffer.writeln('    <path d="${shape.getSvgPathData()}" fill="${shape.isClosed ? shapeFillHex : 'none'}" fill-rule="evenodd" stroke="$strokeHex" stroke-width="$sWidth" />');
          }
        }
      }

      // --- STROKE-ADD bands (filled ring as standalone geometry) ---
      for (var circle in strokeCircles) {
        for (final band in _circleStrokeBands(circle)) {
          if (band.region.op != CompassBooleanOp.add) continue;
          final d = _circleBandSvgData(circle, band.width, band.innerOffset);
          if (d.isEmpty) continue;
          final bandColor = band.region.color;
          final bandFill = bandColor != null ? toHexOpaque(bandColor) : fillHex;
          buffer.writeln('    <path d="$d" fill="$bandFill" fill-rule="evenodd" stroke="none" />');
        }
      }

      // --- GRADIENT MESHES (faceted flat-polygon approximation) ---
      for (int mi = 0; mi < meshShapes.length; mi++) {
        final mesh = meshShapes[mi];
        if (mesh.rows < 2 || mesh.cols < 2) continue;

        final clipPath = layer.getLayerMeshClipPath(mesh);
        final clipData = _pathToSvgData(clipPath);
        final clipId = 'meshclip_${cleanLayerId}_$mi';

        if (clipData.isNotEmpty) {
          buffer.writeln('    <defs>');
          buffer.writeln('      <clipPath id="$clipId" clipPathUnits="userSpaceOnUse">');
          buffer.writeln('        <path d="$clipData" fill-rule="evenodd" />');
          buffer.writeln('      </clipPath>');
          buffer.writeln('    </defs>');
          buffer.writeln('    <g clip-path="url(#$clipId)">');
        } else {
          buffer.writeln('    <g>');
        }

        final int sub = _meshSvgSubdivisions;
        Offset nodeOffset(int r, int c) {
          final p = mesh.nodes[r * mesh.cols + c].point;
          return Offset(p.x.value, p.y.value);
        }

        for (int r = 0; r < mesh.rows - 1; r++) {
          for (int c = 0; c < mesh.cols - 1; c++) {
            final pTL = nodeOffset(r, c);
            final pTR = nodeOffset(r, c + 1);
            final pBL = nodeOffset(r + 1, c);
            final pBR = nodeOffset(r + 1, c + 1);

            final kTL = mesh.colorAt(r, c);
            final kTR = mesh.colorAt(r, c + 1);
            final kBL = mesh.colorAt(r + 1, c);
            final kBR = mesh.colorAt(r + 1, c + 1);

            for (int i = 0; i < sub; i++) {
              final v0 = i / sub;
              final v1 = (i + 1) / sub;
              for (int j = 0; j < sub; j++) {
                final u0 = j / sub;
                final u1 = (j + 1) / sub;

                Offset bp(double u, double v) {
                  final top = Offset.lerp(pTL, pTR, u)!;
                  final bot = Offset.lerp(pBL, pBR, u)!;
                  return Offset.lerp(top, bot, v)!;
                }

                final a = bp(u0, v0);
                final b = bp(u1, v0);
                final cc = bp(u1, v1);
                final d = bp(u0, v1);

                final uc = (u0 + u1) / 2;
                final vc = (v0 + v1) / 2;
                final topK = Color.lerp(kTL, kTR, uc)!;
                final botK = Color.lerp(kBL, kBR, uc)!;
                final cellColor = Color.lerp(topK, botK, vc)!;

                final pts =
                    '${a.dx},${a.dy} ${b.dx},${b.dy} ${cc.dx},${cc.dy} ${d.dx},${d.dy}';
                buffer.writeln(
                    '      <polygon points="$pts" fill="${toHexOpaque(cellColor)}" stroke="none" shape-rendering="crispEdges" />');
              }
            }
          }
        }

        buffer.writeln('    </g>');
      }

      buffer.writeln('  </g>');

      // --- MIRROR MODIFIER ---
      // Reflect the ENTIRE rendered layer by instantiating its content group
      // through a transformed <use>. This is the SVG analogue of the renderer's
      // "replay the whole pass through canvas.transform(mirrorMatrix)" -- the one
      // <use> transform maps flat fills, masked subtractions, userSpaceOnUse
      // gradients (axis reflects with the geometry), stroke-add bands, and mesh
      // clip+facets all together, so a subtract on the master half carves the
      // reflected half symmetrically. Emitting both href and xlink:href covers
      // modern and legacy renderers. Nothing here duplicates ids: the content is
      // written once and merely referenced.
      if (layer.mirrorEnabled) {
        final t = _mirrorTransform(layer);
        buffer.writeln('  <use xlink:href="#$contentId" href="#$contentId" transform="$t" />');
      }
    }

    buffer.writeln('</svg>');
    return buffer.toString();
  }
}