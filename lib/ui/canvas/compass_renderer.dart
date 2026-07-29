// /lib/ui/canvas/compass_renderer.dart

import 'dart:math';
import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/mesh.dart';
import '../../models/geometry/image.dart';
import '../../models/geometry/gradient.dart'; // <--- NEW: per-shape linear fill gradient (stop dots + axis)
import '../../models/layer.dart'; // <--- NEW: MirrorAxis + hasLiftedGradientFill predicate

// Import CompassTool from the canvas controller
import 'canvas_controller.dart';
import 'canvas_hit_tester.dart';
import 'renderer_helpers.dart'; 

enum CompassRendererPass { document, overlay }

class CompassRenderer extends CustomPainter {
  static bool _isPathEmpty(Path path) {
    if (path.getBounds() != Rect.zero) return false;
    return path.computeMetrics().isEmpty;
  }

  Set<CompassPoint> _cachedGradientStops = const <CompassPoint>{};
  Set<CompassPoint> _cachedUnlockedPoints = const <CompassPoint>{};

  final CompassEngine engine;
  final CompassRendererPass renderPass;
  final CompassPoint? selectedPoint; 
  final Set<CompassPoint>? selectedPoints; 
  final Offset? rotationPivotOffset;
  final bool isRPressed;
  final bool isShiftRPressed;
  final bool isCtrlRPressed; 
  final bool isAPressed; 
  
  final CompassSplineNode? activeFilletNode;
  final CompassXSpline? activeFilletSpline;
  final double activeFilletRadius;
  final bool isFPressed;

  final bool isWPressed;
  final CompassSplineNode? activeWidthNode;
  final bool activeWidthIsLeft;

  final Offset? addVertexPreviewPos;
  final CompassXSpline? addVertexSpline;
  final int addVertexSegmentIndex;

  // --- X-KEY MESH SLICE PREVIEW ---
  // When set, draw a dotted line between these two endpoints showing where an
  // X-key slice will cut. sliceIsRow tints it (a horizontal row-insert vs a
  // vertical column-insert) so the direction reads at a glance.
  final bool sliceIsRow;
  final Offset? slicePreviewA;
  final Offset? slicePreviewB;

  final CompassPoint? tensionTargetPoint; 
  final CompassPoint? shapeStartPoint;
  final CompassPoint? hoveredPoint;
  final Offset? hoverPosition;
  final CompassTool currentTool;
  final bool showScaffolding;
  final bool showHandles; 

  // --- GHOST VERTICES ---
  // Display-only suppression of the vertex DOTS: the point-dot pass, the
  // per-node tension boxes, and the Bézier/width handle dots are skipped, but
  // NOTHING interactive changes -- hit-testing lives in the controller and
  // never reads this flag, so hidden points remain clickable, draggable, and
  // box-selectable. The hover ring, selection highlight, and every live tool
  // preview (fillet, tension line, slice line, rubber-banding) STILL paint,
  // which is what makes the mode workable: sweep the cursor along a wireframe
  // and the invisible vertices announce themselves the moment you find them.
  final bool ghostVertices;

  final Offset panOffset;
  final double canvasScale;
  final Color pointBorderColor;

  final CompassSplineNode? activeHandleNode;
  final bool activeHandleIsOut;

  final Rect? selectionBounds; 

  CompassRenderer({
    required this.engine,
    this.renderPass = CompassRendererPass.document,
    Listenable? repaint,
    this.selectedPoint,
    this.selectedPoints,
    this.rotationPivotOffset,
    this.isRPressed = false,
    this.isShiftRPressed = false,
    this.isCtrlRPressed = false, 
    this.isAPressed = false, 
    this.activeFilletNode,
    this.activeFilletSpline,
    this.activeFilletRadius = 0.0,
    this.isFPressed = false,
    this.isWPressed = false, 
    this.activeWidthNode,    
    this.activeWidthIsLeft = false, 
    this.addVertexPreviewPos,
    this.addVertexSpline,
    this.addVertexSegmentIndex = -1,
    this.sliceIsRow = false,
    this.slicePreviewA,
    this.slicePreviewB,
    this.tensionTargetPoint, 
    this.shapeStartPoint,
    this.hoveredPoint,
    this.hoverPosition,
    required this.currentTool,
    required this.showScaffolding,
    required this.showHandles, 
    this.ghostVertices = false, // <--- NEW
    required this.panOffset,
    required this.canvasScale,
    required this.pointBorderColor,
    this.activeHandleNode,
    this.activeHandleIsOut = false,
    this.selectionBounds, 
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final safeScale = canvasScale.abs() < 1e-9 ? 1.0 : canvasScale;
    final visibleWorldRect = Rect.fromLTRB(
      -panOffset.dx / safeScale,
      -panOffset.dy / safeScale,
      (size.width - panOffset.dx) / safeScale,
      (size.height - panOffset.dy) / safeScale,
    );

    canvas.save();
    
    // Apply Global Transformations (Pan and Scale)
    canvas.translate(panOffset.dx, panOffset.dy);
    canvas.scale(canvasScale);
    
    if (renderPass != CompassRendererPass.overlay) {
    // ==========================================
    // 0. DRAW REFERENCE IMAGE (BOTTOM Z-INDEX)
    // ==========================================
    if (engine.referenceLayer != null && engine.referenceLayer!.isVisible && engine.referenceLayer!.image != null) {
      final ref = engine.referenceLayer!;
      
      canvas.save();
      canvas.translate(ref.offset.dx, ref.offset.dy);
      final imgCenter = Offset(ref.image!.width / 2, ref.image!.height / 2);
      canvas.translate(imgCenter.dx, imgCenter.dy);
      canvas.rotate(ref.rotation);
      canvas.scale(ref.scale);
      canvas.translate(-imgCenter.dx, -imgCenter.dy);
      canvas.drawImage(ref.image!, Offset.zero, Paint()..color = Colors.white.withOpacity(0.5));
      canvas.restore();
    }

    // ==========================================
    // 1. DRAW MASTER BOOLEAN FILL AND STROKE (PER LAYER)
    // ==========================================
    for (var layer in engine.layers) {
      if (layer.isVisible) {
        final layerSignature = layer.geometrySignature;
        final resolvedGeometry = layer.getRenderGeometry(
          signature: layerSignature,
        );
        final fillPath = resolvedGeometry.fillPath;
        final layerPath = resolvedGeometry.outlinePath;
        final strokeAreaPath = resolvedGeometry.strokeAreaPath;

        // Resolved bounds now include visible mesh boundaries, so every layer can
        // be culled uniformly before any fill, clip, or Vertices work.
        final layerBounds = resolvedGeometry.bounds;
        if (layerBounds != Rect.zero) {
          final paintPadding = max(layer.strokeWidth, 12.0) / safeScale;
          if (!layerBounds.inflate(paintPadding).overlaps(visibleWorldRect)) {
            continue;
          }
        }

        // 1a. Fill Standard Geometry 
        if (layer.color != Colors.transparent) {
          final fillPaint = Paint()
            ..color = layer.color
            ..style = PaintingStyle.fill;
          canvas.drawPath(fillPath, fillPaint);
        }

        // 1a'. Per-shape LINEAR FILL GRADIENTS (their own self-painted,
        // boolean-clipped category -- the exact structure of the mesh pass at
        // 1d, but a shader fill instead of drawVertices).
        //
        // Each such shape was SKIPPED in the flat fill union above
        // (CompassLayer.hasLiftedGradientFill -> getLayerFillPath's continue),
        // so its interior is currently unpainted; we fill it here with the
        // linear shader (>=2 stops) or a solid of the single stop color (1 stop),
        // masked to the shape's boolean-carved silhouette (getLayerGradientClipPath).
        //
        // WHY THE FILL SLOT, not the mesh slot (1d): unlike a mesh, a gradient
        // shape STILL contributes its outline to layerPath, so it keeps the
        // uniform hairline. Painting the fill BEFORE 1b lets that hairline land
        // on top of the shader edge and stay full-width; painting it at 1d would
        // bury the inner half of the hairline under the shader. Its stroke RINGS
        // are already in the flat fill (the stroke stack ran in getLayerFillPath),
        // so only the interior is (re)painted here.
        //
        // NOT gated on layer.color: the whole point is a fill the flat layer
        // color can't express, so a gradient shows even on a transparent layer.
        // No explicit clipPath needed (unlike the mesh, whose drawVertices spans
        // a whole rect): filling the clip path directly bounds the shader to
        // exactly that region.
        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue;

          // IMG objects use the same ordered Boolean clip semantics as lifted
          // gradients, but paint decoded raster pixels through that path.
          if (shape is CompassImage &&
              CompassLayer.hasLiftedImageFill(shape)) {
            final clip = layer.getCachedImagePaintClipPath(shape, layerSignature);
            if (_isPathEmpty(clip)) continue;

            shape.drawPixels(canvas, clip);

            // Raster content is glued to its affine point frame, so the layer
            // mirror must transform the clip and pixels together.
            if (layer.mirrorEnabled) {
              canvas.save();
              canvas.transform(layer.mirrorMatrix.storage);
              shape.drawPixels(canvas, clip);
              canvas.restore();
            }
            continue;
          }

          if (!CompassLayer.hasLiftedGradientFill(shape)) continue;

          final g = shape.gradient!;
          final clip = layer.getCachedSelfPaintedClipPath(shape, layerSignature);
          if (_isPathEmpty(clip)) continue;

          final gradPaint = Paint()
            ..isAntiAlias = true
            ..style = PaintingStyle.fill;

          final shader = g.buildShader();
          if (shader != null) {
            gradPaint.shader = shader; // >=2 stops: real linear ramp
          } else {
            final solid = g.solidColor; // <2 stops: solid of the seed color
            if (solid == null) continue; // 0 stops -> not renderable (shouldn't occur)
            gradPaint.color = solid;
          }

          canvas.drawPath(clip, gradPaint);

          // --- MIRROR MODIFIER: extend the gradient into the reflected half ---
          // The mirror fuses the master half and its reflection into ONE shape
          // (the "borg"), and the gradient must shade that whole fused silhouette
          // COHESIVELY -- as if the shape simply grew into the new area, sampling
          // the SAME world-space ramp across the seam. It is NOT a second,
          // reflected gradient.
          //
          // So we reflect ONLY the clip PATH (clip.transform), and fill it with
          // the SAME untransformed gradPaint. The shader keeps its original
          // world-space axis, so the ramp continues in the same direction into
          // the reflected region and the color flows straight across the seam.
          //
          // Contrast with the mesh pass at 1d, which DOES transform the whole
          // canvas: a mesh's color field is glued to its own moving vertices, so
          // its reflection must carry the vertices (and thus the field) through
          // the mirror. A linear gradient is a world-space ramp, not vertex-glued,
          // so mirroring its axis would wrongly fold the color at the seam --
          // exactly the duplicate-gradient artifact we're avoiding here.
          if (layer.mirrorEnabled) {
            final reflectedClip = clip.transform(layer.mirrorMatrix.storage);
            canvas.drawPath(reflectedClip, gradPaint);
          }
        }

        // 1b. Stroke Standard Geometry
        if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
          final strokePaint = Paint()
            ..color = layer.strokeColor
            ..strokeWidth = layer.strokeWidth
            ..style = PaintingStyle.stroke;
          canvas.drawPath(layerPath, strokePaint);
        }

        // 1c. Area Strokes 
        if (layer.strokeColor != Colors.transparent) {
          final areaStrokePaint = Paint()
            ..color = layer.strokeColor
            ..style = PaintingStyle.fill;
          canvas.drawPath(strokeAreaPath, areaStrokePaint);
        }

        // 1c'. Colored stroke ADD-band overpaints. A stroke-add region with its own
        // color was unioned into fillPath above and thus painted in the LAYER fill
        // color in 1a; here we repaint each such band in its OWN color, on top, in
        // stack order. The band paths come back already intersected with fillPath,
        // so a band carved by a shape above it paints only where it survives and
        // color can't bleed into a gap. Null-color add bands are NOT in this list
        // (they're meant to ride the layer color), so nothing is double-painted.
        // Done AFTER the flat fill/stroke but BEFORE the mesh pass, so a gradient
        // mesh still sits above its layer's solid geometry as before.
        if (layer.color != Colors.transparent) {
          for (final (bandPath, bandColor)
              in resolvedGeometry.strokeOverpaints) {
            final bandPaint = Paint()
              ..color = bandColor
              ..style = PaintingStyle.fill
              ..isAntiAlias = true;
            canvas.drawPath(bandPath, bandPaint);
          }
        }

        // 1d. Gradient Meshes (their own self-painted, boolean-clipped category).
        // Each mesh paints its interpolated color field via drawVertices, clipped
        // to its boolean-carved silhouette (getLayerMeshClipPath). Done per-mesh
        // and AFTER the flat fills of this layer so a mesh sits above its layer's
        // solid geometry, matching how the model excludes it from the flat union.
        // The clip is save/restore-scoped so it never leaks onto the next mesh,
        // the next layer, or the scaffolding pass.
        for (var shape in layer.shapes) {
          if (shape is! CompassMesh) continue;
          if (!shape.isVisible) continue;
          if (shape.rows < 2 || shape.cols < 2) continue;

          final clip = layer.getCachedMeshClipPath(shape, layerSignature);
          if (_isPathEmpty(clip)) continue;

          canvas.save();
          canvas.clipPath(clip);
          // Vertices already carry per-vertex colors. drawVertices with
          // BlendMode.modulate combines the vertex colors with the paint color;
          // white paint is the identity, so the authored vertex colors render
          // exactly. A Paint is still required even though its color is the
          // identity. AntiAlias smooths the patch triangles.
          final meshPaint = Paint()
            ..isAntiAlias = true
            ..color = Colors.white;
          canvas.drawVertices(
            shape.buildVertices(),
            BlendMode.modulate,
            meshPaint,
          );
          canvas.restore();

          // --- MIRROR MODIFIER: second mesh pass ---
          // A mesh can't ride the layer's path-union mirror (it paints via
          // drawVertices, not a Path), so its reflection is a REPLAY: the same
          // clip + drawVertices inside canvas.transform(mirrorMatrix), which
          // maps clip and vertices together. Unlike the linear gradient above,
          // a mesh's color field is glued to its vertices, so the field MUST
          // travel through the mirror with them. This is exactly why
          // getLayerMeshClipPath stays unmirrored. Save/restore-scoped so the
          // reflection transform never leaks into the next mesh or layer.
          if (layer.mirrorEnabled) {
            canvas.save();
            canvas.transform(layer.mirrorMatrix.storage);
            canvas.clipPath(clip);
            canvas.drawVertices(
              shape.buildVertices(),
              BlendMode.modulate,
              meshPaint,
            );
            canvas.restore();
          }
        }
      }
    }

    }

    // ==========================================
    // 2. DRAW SCAFFOLDING (WIREFRAMES & POINTS)
    // ==========================================
    if (renderPass != CompassRendererPass.document && showScaffolding) {
      final invScale = 1.0 / canvasScale;

      // --- MIRROR MODIFIER AXIS LINES ---
      // One dashed line per visible layer with the mirror enabled, spanning the
      // whole visible viewport (computed by unprojecting the screen rect through
      // pan/scale, +margin so the ends never peek in while panning). The ACTIVE
      // layer's axis is brighter and carries a square grab handle where the axis
      // crosses the viewport center -- that handle (and the line itself) is the
      // drag target the gesture handler hit-tests to move the symmetry plane.
      // Locked layers still SHOW their axis (the mirror is part of their look)
      // but dimmer; the gesture side refuses to drag those.
      {
        final viewLeft = (0 - panOffset.dx) / canvasScale;
        final viewTop = (0 - panOffset.dy) / canvasScale;
        final viewRight = (size.width - panOffset.dx) / canvasScale;
        final viewBottom = (size.height - panOffset.dy) / canvasScale;
        final margin = 50.0 * invScale;

        for (var layer in engine.layers) {
          if (!layer.isVisible || !layer.mirrorEnabled) continue;

          final isActive = layer == engine.activeLayer && !layer.isLocked;
          final axisPaint = Paint()
            ..color = Colors.tealAccent.withOpacity(isActive ? 0.9 : 0.35)
            ..strokeWidth = (isActive ? 2.0 : 1.5) * invScale
            ..style = PaintingStyle.stroke;

          final Offset a, b;
          if (layer.mirrorAxis == MirrorAxis.vertical) {
            a = Offset(layer.mirrorPosition, viewTop - margin);
            b = Offset(layer.mirrorPosition, viewBottom + margin);
          } else {
            a = Offset(viewLeft - margin, layer.mirrorPosition);
            b = Offset(viewRight + margin, layer.mirrorPosition);
          }
          RendererHelpers.drawDashedLine(canvas, a, b, axisPaint, invScale);

          if (isActive) {
            // Grab handle at the viewport-center crossing so it's always on
            // screen and reachable regardless of where you've panned.
            final Offset handleCenter = layer.mirrorAxis == MirrorAxis.vertical
                ? Offset(layer.mirrorPosition, (viewTop + viewBottom) / 2)
                : Offset((viewLeft + viewRight) / 2, layer.mirrorPosition);

            final handleFill = Paint()
              ..color = Colors.tealAccent
              ..style = PaintingStyle.fill;
            final handleBorder = Paint()
              ..color = pointBorderColor
              ..strokeWidth = 1.5 * invScale
              ..style = PaintingStyle.stroke;

            final handleRect = Rect.fromCenter(
              center: handleCenter,
              width: 10.0 * invScale,
              height: 10.0 * invScale,
            );
            canvas.drawRect(handleRect, handleFill);
            canvas.drawRect(handleRect, handleBorder);
          }
        }
      }

      final wireframePaint = Paint()
        ..color = Colors.blue.withOpacity(0.3)
        ..strokeWidth = 1.5 * invScale 
        ..style = PaintingStyle.stroke;

      final selectedWireframePaint = Paint()
        ..color = Colors.blueAccent
        ..strokeWidth = 2.5 * invScale
        ..style = PaintingStyle.stroke;

      for (var layer in engine.layers) {
        if (!layer.isVisible || layer.isLocked) continue; 
        
        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue; 

          final isSelected = shape == engine.selectedShape;
          
          if (shape is CompassCircle) {
            canvas.drawCircle(Offset(shape.center.x.value, shape.center.y.value), shape.radius.value, isSelected ? selectedWireframePaint : wireframePaint);
            if (isSelected && shape.radiusPoint != null) {
              final scaffoldPaint = Paint()..color = Colors.blue.withOpacity(0.5)..strokeWidth = 1.5 * invScale..style = PaintingStyle.stroke;
              RendererHelpers.drawDashedLine(canvas, Offset(shape.center.x.value, shape.center.y.value), Offset(shape.radiusPoint!.x.value, shape.radiusPoint!.y.value), scaffoldPaint, invScale); 
            }
          } else if (shape is CompassRectangle) {
            shape.paint(canvas, isSelected ? selectedWireframePaint : wireframePaint, showScaffolding: true, isSelected: isSelected);
          } else if (shape is CompassImage) {
            shape.paint(canvas, isSelected ? selectedWireframePaint : wireframePaint, showScaffolding: true, isSelected: isSelected);
          } else if (shape is CompassLine) {
            canvas.drawLine(Offset(shape.start.x.value, shape.start.y.value), Offset(shape.end.x.value, shape.end.y.value), isSelected ? selectedWireframePaint : wireframePaint);
          } else if (shape is CompassSpiral) {
            canvas.drawPath(shape.getPath(), isSelected ? selectedWireframePaint : wireframePaint);
            if (isSelected) {
               final scaffoldPaint = Paint()..color = Colors.blue.withOpacity(0.5)..strokeWidth = 1.5 * invScale..style = PaintingStyle.stroke;
               canvas.drawLine(Offset(shape.center.x.value, shape.center.y.value), Offset(shape.startPoint.x.value, shape.startPoint.y.value), scaffoldPaint);
            }
          } else if (shape is CompassMesh) {
            // Mesh lattice: draw the grid lines (shape.paint draws only the
            // lattice, never the gradient surface -- that's painted clipped above).
            // A selected mesh gets the brighter wireframe + a centroid box and an
            // anchor tether, exactly like the X-Spline treatment, since a mesh also
            // carries an anchorPoint as its rigid-body / rotation pivot.
            shape.paint(canvas, isSelected ? selectedWireframePaint : wireframePaint, showScaffolding: true, isSelected: isSelected);

            if (isSelected) {
              double cx = 0, cy = 0;
              if (shape.anchorPoint != null) {
                cx = shape.anchorPoint!.x.value;
                cy = shape.anchorPoint!.y.value;
              } else if (shape.nodes.isNotEmpty) {
                for (var n in shape.nodes) {
                  cx += n.point.x.value;
                  cy += n.point.y.value;
                }
                cx /= shape.nodes.length;
                cy /= shape.nodes.length;
              }

              final centerBoxPaint = Paint()
                ..color = Colors.orangeAccent
                ..strokeWidth = 2.0 * invScale
                ..style = PaintingStyle.stroke;

              canvas.drawRect(
                Rect.fromCenter(center: Offset(cx, cy), width: 8.0 * invScale, height: 8.0 * invScale),
                centerBoxPaint,
              );

              if (shape.anchorPoint != null && shape.nodes.isNotEmpty) {
                final scaffoldPaint = Paint()..color = Colors.orangeAccent.withOpacity(0.3)..strokeWidth = 1.0 * invScale..style = PaintingStyle.stroke;
                RendererHelpers.drawDashedLine(canvas, Offset(cx, cy), Offset(shape.nodes.first.point.x.value, shape.nodes.first.point.y.value), scaffoldPaint, invScale);
              }

              // --- Tension Handles for selected Mesh nodes ---
              // Ghosted: these are per-node dot furniture, so they hide with the
              // vertex dots. (The mesh LATTICE above still draws -- that's shape
              // structure, not dot clutter.)
              if (!ghostVertices) {
                for (var node in shape.nodes) {
                  final pt = Offset(node.point.x.value, node.point.y.value);
                  
                  final handlePt = pt + const Offset(20, -30);
                  
                  final scaffoldLinePaint = Paint()
                    ..color = Colors.blue.withOpacity(0.5)
                    ..strokeWidth = 1.5 * invScale
                    ..style = PaintingStyle.stroke;

                  final boxStrokePaint = Paint()
                    ..color = Colors.blue
                    ..strokeWidth = 1.5 * invScale
                    ..style = PaintingStyle.stroke;

                  canvas.drawLine(pt, handlePt, scaffoldLinePaint);
                  
                  final handleRect = Rect.fromCenter(center: handlePt, width: 10 * invScale, height: 10 * invScale);
                  canvas.drawRect(handleRect, boxStrokePaint);
                  
                  final tensionFillPaint = Paint()
                    ..color = Colors.blue.withOpacity(node.tension.value.clamp(0.0, 1.0))
                    ..style = PaintingStyle.fill;
                  canvas.drawRect(handleRect, tensionFillPaint);
                }
              }
            }
          } else if (shape is CompassXSpline) {
             // NOTE: shape.paint draws the spline body PLUS its per-node tension
             // boxes when selected. In ghost mode we suppress those boxes by
             // passing isSelected:false to paint (the body still draws; the
             // brighter selected wireframe paint is kept so selection still
             // reads) -- the centroid box, pulleys, and vertex numbers below are
             // handled individually.
             shape.paint(
               canvas,
               isSelected ? selectedWireframePaint : wireframePaint,
               showScaffolding: true,
               isSelected: isSelected && !ghostVertices,
             );
             
             // --- Draw Centroid Box for selected X-Spline ---
             if (isSelected) {
               double cx = 0, cy = 0;
               if (shape.anchorPoint != null) {
                 cx = shape.anchorPoint!.x.value;
                 cy = shape.anchorPoint!.y.value;
               } else if (shape.nodes.isNotEmpty) {
                 for (var n in shape.nodes) {
                   cx += n.point.x.value;
                   cy += n.point.y.value;
                 }
                 cx /= shape.nodes.length;
                 cy /= shape.nodes.length;
               }
               
               final centerBoxPaint = Paint()
                 ..color = Colors.orangeAccent
                 ..strokeWidth = 2.0 * invScale
                 ..style = PaintingStyle.stroke;
                 
               canvas.drawRect(
                 Rect.fromCenter(center: Offset(cx, cy), width: 8.0 * invScale, height: 8.0 * invScale),
                 centerBoxPaint,
               );
               
               if (shape.anchorPoint != null && shape.nodes.isNotEmpty) {
                 final scaffoldPaint = Paint()..color = Colors.orangeAccent.withOpacity(0.3)..strokeWidth = 1.0 * invScale..style = PaintingStyle.stroke;
                 RendererHelpers.drawDashedLine(canvas, Offset(cx, cy), Offset(shape.nodes.first.point.x.value, shape.nodes.first.point.y.value), scaffoldPaint, invScale); 
               }

               // --- Live Corner Pulley Wireframes (round + miter) ---
               // NOT ghosted: a pulley is a live CONSTRAINT visualization (like
               // the wireframe itself), not vertex-dot furniture -- and its rim
               // dot is the drag affordance for resizing it, which must stay
               // discoverable.
               final cornerCirclePaint = Paint()
                 ..color = Colors.lightBlueAccent.withOpacity(0.8)
                 ..strokeWidth = 1.5 * invScale
                 ..style = PaintingStyle.stroke;
                 
               final cornerMiterPaint = Paint()
                 ..color = Colors.deepOrangeAccent.withOpacity(0.8)
                 ..strokeWidth = 1.5 * invScale
                 ..style = PaintingStyle.stroke;

               // Faint guide for the peg the rope wraps, shared by both pulleys.
               final pegGuidePaint = Paint()
                 ..color = Colors.deepOrangeAccent.withOpacity(0.25)
                 ..strokeWidth = 1.0 * invScale
                 ..style = PaintingStyle.stroke;
                 
               final n = shape.nodes.length;
               for (int i = 0; i < n; i++) {
                 final node = shape.nodes[i];
                 final pt = Offset(node.point.x.value, node.point.y.value);
                 
                 if (node.cornerRadius.value > 0.01) {
                   // Draw the persistent constraint circle
                   canvas.drawCircle(pt, node.cornerRadius.value, cornerCirclePaint);
                   
                   // Draw a tiny dot on the rim so the user knows they can drag it
                   final rimDotPaint = Paint()..color = Colors.lightBlueAccent..style = PaintingStyle.fill;
                   canvas.drawCircle(pt + Offset(node.cornerRadius.value, 0), 4.0 * invScale, rimDotPaint);
                 } 
                 // --- Miter pulley wireframe: trace the REAL sharp-wrap outline ---
                 // This mirrors the exact tangent construction in
                 // CompassXSpline.getResolvedNodes (thetaA/thetaC, betaA/betaC,
                 // Z/S, phiA/phiC, phiMid, mitreLen) so the wireframe equals the
                 // rendered tip. We draw the faint peg circle the rope wraps, then
                 // the two tangent rope segments meeting at the sharp apex, and we
                 // park the draggable rim dot on the apex itself (the thing being
                 // sized). The construction needs both neighbors, so an open
                 // spline's endpoints (which can't carry a pulley anyway) fall back
                 // to just the peg circle.
                 else if (node.miterSize.value > 0.01) {
                   final r = node.miterSize.value;

                   // Faint peg circle (what the rope wraps).
                   canvas.drawCircle(pt, r, pegGuidePaint);

                   final bool hasNeighbors = shape.isClosed || (i > 0 && i < n - 1);
                   if (hasNeighbors) {
                     final prevIdx = (i - 1 + n) % n;
                     final nextIdx = (i + 1) % n;
                     final pPrev = Offset(shape.nodes[prevIdx].point.x.value, shape.nodes[prevIdx].point.y.value);
                     final pNext = Offset(shape.nodes[nextIdx].point.x.value, shape.nodes[nextIdx].point.y.value);

                     final vA = pPrev - pt;
                     final vC = pNext - pt;
                     final dA = vA.distance;
                     final dC = vC.distance;

                     if (dA > 0.001 && dC > 0.001) {
                       double rr = r;
                       final maxR = min(dA, dC) * 0.99;
                       if (rr > maxR) rr = maxR;

                       final thetaA = atan2(vA.dy, vA.dx);
                       final thetaC = atan2(vC.dy, vC.dx);
                       final betaA = acos((rr / dA).clamp(-1.0, 1.0));
                       final betaC = acos((rr / dC).clamp(-1.0, 1.0));

                       final Z = vA.dx * vC.dy - vA.dy * vC.dx;
                       final S = Z > 0 ? 1.0 : -1.0;

                       final phiA = thetaA - S * betaA;
                       final phiC = thetaC + S * betaC;

                       double delta = phiC - phiA;
                       if (S > 0) {
                         while (delta > 0) delta -= 2 * pi;
                       } else {
                         while (delta < 0) delta += 2 * pi;
                       }

                       final phiMid = phiA + delta / 2.0;
                       final halfWrap = delta.abs() / 2.0;
                       final cosHalf = cos(halfWrap);
                       final mitreLen = cosHalf < 0.05 ? rr * 20.0 : rr / cosHalf;

                       final tangentA = pt + Offset(cos(phiA), sin(phiA)) * rr;
                       final tangentC = pt + Offset(cos(phiC), sin(phiC)) * rr;
                       final apex = pt + Offset(cos(phiMid), sin(phiMid)) * mitreLen;

                       final outline = Path()
                         ..moveTo(tangentA.dx, tangentA.dy)
                         ..lineTo(apex.dx, apex.dy)
                         ..lineTo(tangentC.dx, tangentC.dy);
                       canvas.drawPath(outline, cornerMiterPaint);

                       // Draggable rim dot sits on the apex (the sized point).
                       final rimDotPaint = Paint()..color = Colors.deepOrangeAccent..style = PaintingStyle.fill;
                       canvas.drawCircle(apex, 4.0 * invScale, rimDotPaint);
                     }
                   }
                 }
               }

               // --- DRAW VERTEX NUMBERS IF TOGGLED ---
               // NOT ghosted: showNodeIndices is its own explicit opt-in toggle,
               // and with the dots hidden the numbers are the one way to still
               // SEE where every vertex sits -- the two toggles compose into a
               // clean "labels only" view.
               if (engine.showNodeIndices) {
                 for (int i = 0; i < shape.nodes.length; i++) {
                   final pt = Offset(shape.nodes[i].point.x.value, shape.nodes[i].point.y.value);
                   
                   final textSpan = TextSpan(
                     text: ' $i ',
                     style: TextStyle(
                       color: Colors.white,
                       backgroundColor: Colors.blueAccent.withOpacity(0.8),
                       fontSize: 14 * invScale,
                       fontWeight: FontWeight.bold,
                     ),
                   );
                   
                   final textPainter = TextPainter(
                     text: textSpan,
                     textDirection: TextDirection.ltr,
                   );
                   textPainter.layout();
                   
                   textPainter.paint(canvas, pt + Offset(8 * invScale, 8 * invScale));
                 }
               }
             }
          }
        }
      }

      final selForHandles = engine.selectedShape;

      // --- WIDTH HANDLES for the selected X-Spline (W KEY) ---
      // NOT ghosted while W is held: holding W is an explicit "show me the
      // width rig" request, and the diamonds are the drag targets for it.
      // Without them the W tool would be unusable in ghost mode.
      if (selForHandles is CompassXSpline && showHandles && isWPressed) {
        RendererHelpers.drawWidthHandles(canvas, selForHandles, invScale, pointBorderColor, activeWidthNode, activeWidthIsLeft); 
      }

      // --- BEZIER HANDLES for the selected X-Spline ---
      // Ghosted: the purple handle dots are exactly the per-vertex furniture
      // this mode exists to clear away. (Handle EDITING via drag needs the dots
      // as targets, so in ghost mode that entry path is dormant -- by design;
      // Ctrl+R handle rotation still works since it targets points, not dots.)
      if (selForHandles is CompassXSpline && showHandles && !isWPressed && !ghostVertices) { 
        RendererHelpers.drawBezierHandles(canvas, selForHandles, invScale, pointBorderColor, activeHandleNode, activeHandleIsOut); 
      }

      // --- GRADIENT STOP DOTS + AXIS (selected shape's linear fill gradient) ---
      //
      // Gradient stops are ordinary CompassPoints, but they are intentionally
      // suppressed from the generic blue-point pass below. The selected shape's
      // gradient is edited here as its own compact control:
      //
      //   * diamond handles are the two freely draggable axis endpoints;
      //   * round handles are interior color stops that slide along the axis;
      //   * hovering close to the dotted axis shows a small "+" insertion preview,
      //     matching the right-click "Add Gradient Stop Here" interaction.
      //
      // These controls are never ghosted. They are active editing affordances,
      // like pulley rims, rather than ordinary vertex clutter.
      final gradSel = engine.selectedShape;
      final grad = gradSel?.gradient;

      if (grad != null && grad.stops.isNotEmpty) {
        final axis = grad.axis;
        Offset? axisNormal;

        if (axis != null) {
          final axisVector = axis.$2 - axis.$1;
          final axisLength = axisVector.distance;

          if (axisLength > 1e-9) {
            final axisUnit = axisVector / axisLength;
            axisNormal = Offset(-axisUnit.dy, axisUnit.dx);
          }

          // A dark underlay keeps the dotted line readable over pale gradients;
          // the narrow white pass on top keeps it crisp over dark gradients.
          final axisUnderlayPaint = Paint()
            ..color = Colors.black.withOpacity(0.45)
            ..strokeWidth = 3.5 * invScale
            ..style = PaintingStyle.stroke;

          final axisPaint = Paint()
            ..color = Colors.white.withOpacity(0.9)
            ..strokeWidth = 1.5 * invScale
            ..style = PaintingStyle.stroke;

          RendererHelpers.drawDashedLine(
            canvas,
            axis.$1,
            axis.$2,
            axisUnderlayPaint,
            invScale,
          );

          RendererHelpers.drawDashedLine(
            canvas,
            axis.$1,
            axis.$2,
            axisPaint,
            invScale,
          );

          // Right-click insertion preview. The hit radius deliberately matches
          // the context-menu axis hit test, so the marker appears exactly where
          // "Add Gradient Stop Here" is available.
          final canPreviewInsertion =
              currentTool == CompassTool.select &&
              hoverPosition != null &&
              hoveredPoint == null &&
              !isRPressed &&
              !isShiftRPressed &&
              !isCtrlRPressed &&
              !isAPressed &&
              !isFPressed &&
              !isWPressed;

          if (canPreviewInsertion) {
            final projected = grad.projectOntoAxis(hoverPosition!);
            final axisHitRadius = 12.0 * invScale;

            if ((hoverPosition! - projected).distance <= axisHitRadius) {
              final previewRadius = 8.0 * invScale;

              canvas.drawCircle(
                projected,
                previewRadius,
                Paint()
                  ..color = Colors.black.withOpacity(0.6)
                  ..style = PaintingStyle.fill,
              );

              canvas.drawCircle(
                projected,
                previewRadius,
                Paint()
                  ..color = Colors.greenAccent.withOpacity(0.9)
                  ..strokeWidth = 1.5 * invScale
                  ..style = PaintingStyle.stroke,
              );

              final plusPaint = Paint()
                ..color = Colors.greenAccent
                ..strokeWidth = 1.8 * invScale
                ..strokeCap = StrokeCap.round
                ..style = PaintingStyle.stroke;

              final plusHalf = 3.5 * invScale;

              canvas.drawLine(
                projected + Offset(-plusHalf, 0),
                projected + Offset(plusHalf, 0),
                plusPaint,
              );

              canvas.drawLine(
                projected + Offset(0, -plusHalf),
                projected + Offset(0, plusHalf),
                plusPaint,
              );
            }
          }
        }

        for (final stop in grad.stops) {
          final center = Offset(
            stop.point.x.value,
            stop.point.y.value,
          );

          final isEndpoint = grad.isEndpoint(stop);

          if (!isEndpoint && axisNormal != null) {
            // A short perpendicular tick reinforces that this round stop is a
            // slider on the line rather than a free-floating point.
            final tickHalf = 9.0 * invScale;
            final tickPaint = Paint()
              ..color = Colors.white.withOpacity(0.75)
              ..strokeWidth = 1.5 * invScale
              ..style = PaintingStyle.stroke;

            canvas.drawLine(
              center - axisNormal * tickHalf,
              center + axisNormal * tickHalf,
              tickPaint,
            );
          }

          if (isEndpoint) {
            // Axis endpoints are diamonds: they remain freely draggable and
            // therefore need to read differently from interior slider stops.
            final outerRadius = 9.5 * invScale;
            final innerRadius = 7.0 * invScale;

            Path diamond(double radius) {
              return Path()
                ..moveTo(center.dx, center.dy - radius)
                ..lineTo(center.dx + radius, center.dy)
                ..lineTo(center.dx, center.dy + radius)
                ..lineTo(center.dx - radius, center.dy)
                ..close();
            }

            canvas.drawPath(
              diamond(outerRadius),
              Paint()
                ..color = Colors.black.withOpacity(0.6)
                ..style = PaintingStyle.fill,
            );

            canvas.drawPath(
              diamond(innerRadius),
              Paint()
                ..color = stop.color
                ..style = PaintingStyle.fill,
            );

            canvas.drawPath(
              diamond(innerRadius),
              Paint()
                ..color = pointBorderColor
                ..strokeWidth = 1.5 * invScale
                ..style = PaintingStyle.stroke,
            );
          } else {
            const radius = 7.0;

            canvas.drawCircle(
              center,
              radius * invScale,
              Paint()
                ..color = Colors.black.withOpacity(0.6)
                ..strokeWidth = 3.0 * invScale
                ..style = PaintingStyle.stroke,
            );

            canvas.drawCircle(
              center,
              radius * invScale,
              Paint()
                ..color = stop.color
                ..style = PaintingStyle.fill,
            );

            canvas.drawCircle(
              center,
              radius * invScale,
              Paint()
                ..color = pointBorderColor
                ..strokeWidth = 1.5 * invScale
                ..style = PaintingStyle.stroke,
            );
          }
        }
      }


      // --- MULTI-SELECTION BOUNDING BOX ---
      if (selectionBounds != null) {
        RendererHelpers.drawSelectionBounds(canvas, selectionBounds!, invScale); 
      }

      // --- X-KEY MESH SLICE PREVIEW (dotted imposed line) ---
      // Drawn here, after the lattice and selection box, so it sits clearly on top
      // of the mesh it will cut. A row insert (horizontal line) and a column insert
      // (vertical line) get distinct tints so the cut direction is unambiguous.
      if (slicePreviewA != null && slicePreviewB != null) {
        final slicePaint = Paint()
          ..color = sliceIsRow ? Colors.cyanAccent : Colors.pinkAccent
          ..strokeWidth = 2.0 * invScale
          ..style = PaintingStyle.stroke;
        RendererHelpers.drawDashedLine(canvas, slicePreviewA!, slicePreviewB!, slicePaint, invScale);

        // Small endpoint ticks so the line's extent is obvious even over a busy
        // gradient.
        final tickPaint = Paint()
          ..color = sliceIsRow ? Colors.cyanAccent : Colors.pinkAccent
          ..style = PaintingStyle.fill;
        canvas.drawCircle(slicePreviewA!, 4.0 * invScale, tickPaint);
        canvas.drawCircle(slicePreviewB!, 4.0 * invScale, tickPaint);
      }

      // --- EXPLICITLY SELECTED POINT(S) HIGHLIGHT ---
      // NOT ghosted: with the dots hidden, this halo IS the visual for "you have
      // this vertex" -- removing it would leave selection with no feedback.
      final highlightSet = <CompassPoint>{};
      if (selectedPoint != null) highlightSet.add(selectedPoint!);
      if (selectedPoints != null) highlightSet.addAll(selectedPoints!);

      if (highlightSet.isNotEmpty) {
        final highlightPaint = Paint()
          ..color = Colors.blueAccent.withOpacity(0.4)
          ..style = PaintingStyle.fill;
          
        for (var pt in highlightSet) {
          canvas.drawCircle(
            Offset(pt.x.value, pt.y.value),
            14.0 * invScale,
            highlightPaint,
          );
        }
      }

      // --- F KEY LIVE FILLET PREVIEW ---
      if (isFPressed && activeFilletNode != null && activeFilletSpline != null && activeFilletRadius > 0) {
        RendererHelpers.drawFilletPreview(canvas, activeFilletSpline!, activeFilletNode!, activeFilletRadius, invScale); 
      }
      
      // --- TENSION GUIDE LINE (A KEY) ---
      else if (isAPressed && tensionTargetPoint != null && hoverPosition != null) {
        final targetOffset = Offset(tensionTargetPoint!.x.value, tensionTargetPoint!.y.value);
        
        final tensionPaint = Paint()
          ..color = Colors.orangeAccent 
          ..strokeWidth = 2.0 * invScale
          ..style = PaintingStyle.stroke;
          
        RendererHelpers.drawDashedLine(canvas, targetOffset, hoverPosition!, tensionPaint, invScale); 
        canvas.drawCircle(targetOffset, 10.0 * invScale, tensionPaint);
      }
      
      // --- ROTATION GUIDE LINE (R KEY & CTRL+R KEY) ---
      else if ((isRPressed || isShiftRPressed || isCtrlRPressed) && hoverPosition != null) {
        if (rotationPivotOffset != null) {
          final rotPaint = Paint()
            ..color = isCtrlRPressed 
                ? Colors.purpleAccent 
                : (isShiftRPressed ? Colors.deepOrangeAccent : Colors.orangeAccent)
            ..strokeWidth = 2.0 * invScale
            ..style = PaintingStyle.stroke;
            
          RendererHelpers.drawDashedLine(canvas, rotationPivotOffset!, hoverPosition!, rotPaint, invScale); 
          canvas.drawCircle(rotationPivotOffset!, 8.0 * invScale, rotPaint..style = PaintingStyle.fill);
        }
      }

      // Live Previews (Rubber-banding)
      if (shapeStartPoint != null && hoverPosition != null) {
        final startOffset = Offset(shapeStartPoint!.x.value, shapeStartPoint!.y.value);
        
        final previewPaint = Paint()
          ..color = Colors.blue.withOpacity(0.4)
          ..strokeWidth = 2.0 * invScale
          ..style = PaintingStyle.stroke;

        if (currentTool == CompassTool.addLine) {
          canvas.drawLine(startOffset, hoverPosition!, previewPaint);
        } else if (currentTool == CompassTool.addCircle) {
          final radius = (hoverPosition! - startOffset).distance;
          canvas.drawCircle(startOffset, radius, previewPaint);
          RendererHelpers.drawDashedLine(canvas, startOffset, hoverPosition!, previewPaint, invScale); 
        } else if (currentTool == CompassTool.addSpiral) {
          final dummyPoint = CompassPoint(x: hoverPosition!.dx, y: hoverPosition!.dy);
          final dummySpiral = CompassSpiral(center: shapeStartPoint!, startPoint: dummyPoint);
          canvas.drawPath(dummySpiral.getPath(), previewPaint);
          canvas.drawLine(startOffset, hoverPosition!, previewPaint);
        } else if (currentTool == CompassTool.addRect) { 
          final rect = Rect.fromPoints(startOffset, hoverPosition!);
          canvas.drawRect(rect, previewPaint);
          canvas.drawLine(startOffset, hoverPosition!, previewPaint); 
        }
      }

      // Live rubber-banding for actively drawn X-Spline
      if (currentTool == CompassTool.addPen && hoverPosition != null) {
        CompassXSpline? active;
        for(var layer in engine.layers) {
           if (layer.isLocked) continue; 
           try {
             active = layer.shapes.firstWhere((s) => s is CompassXSpline && !s.isClosed) as CompassXSpline;
             break;
           } catch (_) {}
        }
        
        if (active != null && active.nodes.isNotEmpty) {
           final lastPt = Offset(active.nodes.last.point.x.value, active.nodes.last.point.y.value);
           final previewPaint = Paint()
            ..color = Colors.blue.withOpacity(0.4)
            ..strokeWidth = 2.0 * invScale
            ..style = PaintingStyle.stroke;
            
           canvas.drawLine(lastPt, hoverPosition!, previewPaint);
        }
      }

      // Hover Ring
      // NOT ghosted -- this is THE feedback that makes ghost mode navigable:
      // sweep the cursor along the wireframe and hidden vertices light up.
      if (hoveredPoint != null && hoveredPoint != shapeStartPoint && !highlightSet.contains(hoveredPoint)) {
        final hoverPaint = Paint()
          ..color = Colors.orangeAccent.withOpacity(0.5)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(
          Offset(hoveredPoint!.x.value, hoveredPoint!.y.value),
          14.0 * invScale,
          hoverPaint,
        );
      }

      // Start Point Ring
      if (shapeStartPoint != null) {
        final highlightPaint = Paint()
          ..color = Colors.green.withOpacity(0.4)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(
          Offset(shapeStartPoint!.x.value, shapeStartPoint!.y.value),
          14.0 * invScale,
          highlightPaint,
        );
      }

      // Points
      // GHOSTED: the core of the feature. The dot pass is skipped entirely --
      // but ONLY the painting. engine.points is untouched, the hit-tester never
      // reads this flag, and every ring/preview above still draws, so the
      // vertices remain fully live as invisible drag targets.
      if (!ghostVertices) {
        // Gradient stop points are painted as colored stop dots (for the
        // selected shape) in the gradient block above; skip them here so they
        // don't ALSO render as generic blue vertex dots, and so an unselected
        // shape's stops stay hidden -- matching how pulleys/handles only appear
        // when their shape is selected.
        _preparePointPaintCache();
        final stopPoints = _cachedGradientStops;
        final unlockedPoints = _cachedUnlockedPoints;

        final pointPaint = Paint()
          ..color = Colors.blue
          ..style = PaintingStyle.fill;

        final pointBorderPaint = Paint()
          ..color = pointBorderColor
          ..strokeWidth = 1.5 * invScale
          ..style = PaintingStyle.stroke;

        for (var point in engine.points) {
          if (stopPoints.contains(point)) continue;
          if (unlockedPoints.contains(point)) {
            final offset = Offset(point.x.value, point.y.value);
            canvas.drawCircle(offset, 5.0 * invScale, pointPaint);
            canvas.drawCircle(offset, 5.0 * invScale, pointBorderPaint);
          }
        }
      }

      // Add Point Live Preview
      if (currentTool == CompassTool.addPoint && hoverPosition != null) {
        final previewOffset = hoveredPoint != null 
          ? Offset(hoveredPoint!.x.value, hoveredPoint!.y.value) 
          : hoverPosition!;
          
        final addPointPaint = Paint()
          ..color = Colors.greenAccent
          ..style = PaintingStyle.fill;
          
        final addPointBorder = Paint()
          ..color = pointBorderColor
          ..strokeWidth = 2.0 * invScale
          ..style = PaintingStyle.stroke;
          
        canvas.drawCircle(previewOffset, 7.0 * invScale, addPointPaint);
        canvas.drawCircle(previewOffset, 7.0 * invScale, addPointBorder);
        
        final plusPaint = Paint()
          ..color = Colors.black87
          ..strokeWidth = 1.5 * invScale
          ..style = PaintingStyle.stroke;
        canvas.drawLine(previewOffset + Offset(-3.5 * invScale, 0), previewOffset + Offset(3.5 * invScale, 0), plusPaint);
        canvas.drawLine(previewOffset + Offset(0, -3.5 * invScale), previewOffset + Offset(0, 3.5 * invScale), plusPaint);
      }

      // --- Shift-hover "Add Resolution" preview marker ---
      if (addVertexPreviewPos != null) {
        final pos = addVertexPreviewPos!;

        final ringPaint = Paint()
          ..color = Colors.greenAccent.withOpacity(0.5)
          ..strokeWidth = 2.0 * invScale
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(pos, 11.0 * invScale, ringPaint);

        final fillPaint = Paint()
          ..color = Colors.greenAccent
          ..style = PaintingStyle.fill;
        final borderPaint = Paint()
          ..color = pointBorderColor
          ..strokeWidth = 2.0 * invScale
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(pos, 7.0 * invScale, fillPaint);
        canvas.drawCircle(pos, 7.0 * invScale, borderPaint);

        final plusPaint = Paint()
          ..color = Colors.black87
          ..strokeWidth = 1.5 * invScale
          ..style = PaintingStyle.stroke;
        canvas.drawLine(pos + Offset(-3.5 * invScale, 0), pos + Offset(3.5 * invScale, 0), plusPaint);
        canvas.drawLine(pos + Offset(0, -3.5 * invScale), pos + Offset(0, 3.5 * invScale), plusPaint);
      }
    }

    canvas.restore();
  }

  /// Shares the topology-derived interactive-point index with hit testing.
  /// The index is rebuilt only for document/topology changes or selected-gradient
  /// ownership changes, never for ordinary empty-space hover.
  void _preparePointPaintCache() {
    _cachedGradientStops = CanvasHitTester.gradientStopPoints(engine);
    _cachedUnlockedPoints = CanvasHitTester.interactivePoints(engine);
  }

  @override
  bool shouldRepaint(covariant CompassRenderer oldDelegate) {
    if (renderPass != oldDelegate.renderPass || engine != oldDelegate.engine) {
      return true;
    }

    if (renderPass == CompassRendererPass.document) {
      return panOffset != oldDelegate.panOffset ||
          canvasScale != oldDelegate.canvasScale;
    }

    // Overlay delegates are rebuilt only for interaction state changes. Document
    // geometry changes also repaint through the engine Listenable.
    return true;
  }
}