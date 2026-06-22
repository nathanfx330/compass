// lib/ui/canvas/compass_renderer.dart

import 'dart:math';
import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/rectangle.dart';

// Import CompassTool from the canvas controller
import 'canvas_controller.dart';

class CompassRenderer extends CustomPainter {
  final CompassEngine engine;
  final CompassPoint? selectedPoint; 
  final Set<CompassPoint>? selectedPoints; 
  final Offset? rotationPivotOffset;
  final bool isRPressed;
  final bool isShiftRPressed;
  final bool isCtrlRPressed; // <--- NEW
  final bool isAPressed; 
  
  // --- NEW: Receive the active fillet state from the controller
  final CompassSplineNode? activeFilletNode;
  final CompassXSpline? activeFilletSpline;
  final double activeFilletRadius;
  final bool isFPressed;

  // --- NEW: Width Tool (W Key) State
  final bool isWPressed;
  final CompassSplineNode? activeWidthNode;
  final bool activeWidthIsLeft;

  // --- NEW: Shift-hover "Add Resolution" preview ---
  // addVertexPreviewPos is the exact on-curve center of the segment under the
  // cursor (t=0.5 on its cubic). The spline + segment index are carried for
  // context/future use; the marker itself is drawn purely from the preview pos.
  final Offset? addVertexPreviewPos;
  final CompassXSpline? addVertexSpline;
  final int addVertexSegmentIndex;

  final CompassPoint? tensionTargetPoint; 
  final CompassPoint? shapeStartPoint;
  final CompassPoint? hoveredPoint;
  final Offset? hoverPosition;
  final CompassTool currentTool;
  final bool showScaffolding;
  final bool showHandles; // <--- NEW ARGUMENT
  final Offset panOffset;
  final double canvasScale;
  final Color pointBorderColor;

  final CompassSplineNode? activeHandleNode;
  final bool activeHandleIsOut;

  // --- NEW: bounding box of the active 2+ selection (logical space), or null. ---
  // Drawn as a dashed, corner-ticked box framing the highlighted group -- the
  // visible affordance for "grab anywhere in here to move the whole selection."
  // Orange to match the rigid-body/centroid visual language and stay distinct from
  // the blue transient marquee. Null (and thus undrawn) for 0- or 1-point selections.
  final Rect? selectionBounds;

  CompassRenderer({
    required this.engine, 
    this.selectedPoint,
    this.selectedPoints,
    this.rotationPivotOffset,
    this.isRPressed = false,
    this.isShiftRPressed = false,
    this.isCtrlRPressed = false, // <--- NEW
    this.isAPressed = false, 
    this.activeFilletNode,
    this.activeFilletSpline,
    this.activeFilletRadius = 0.0,
    this.isFPressed = false,
    this.isWPressed = false, // <--- Added W Key
    this.activeWidthNode,    // <--- Added Width Node
    this.activeWidthIsLeft = false, // <--- Added Width Side
    this.addVertexPreviewPos,
    this.addVertexSpline,
    this.addVertexSegmentIndex = -1,
    this.tensionTargetPoint, 
    this.shapeStartPoint,
    this.hoveredPoint,
    this.hoverPosition,
    required this.currentTool,
    required this.showScaffolding,
    required this.showHandles, // <--- NEW ARGUMENT
    required this.panOffset,
    required this.canvasScale,
    required this.pointBorderColor,
    this.activeHandleNode,
    this.activeHandleIsOut = false,
    this.selectionBounds, // <--- NEW ARGUMENT
  }) : super(repaint: engine);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    
    // Apply Global Transformations (Pan and Scale)
    canvas.translate(panOffset.dx, panOffset.dy);
    canvas.scale(canvasScale);
    
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
        // fillPath: fillable geometry PLUS closed width-spline centerlines. This is
        //   what makes an area stroke a first-class stroke -- the centerline is the
        //   fill, so a closed width spline can carry an inner fill and a ribbon at
        //   once. Open width splines enclose no area and contribute nothing here.
        // layerPath: unchanged -- excludes width splines, so the uniform stroke pass
        //   (1b) never paints a hairline along the ribbon's inner edge.
        // strokeAreaPath: the variable-width ribbon (1c), unchanged.
        final fillPath = layer.getLayerFillPath();
        final layerPath = layer.getLayerPath();
        final strokeAreaPath = layer.getLayerStrokeAreaPath();

        // 1a. Fill Standard Geometry (now sourced from the fill path)
        if (layer.color != Colors.transparent) {
          final fillPaint = Paint()
            ..color = layer.color
            ..style = PaintingStyle.fill;
          canvas.drawPath(fillPath, fillPaint);
        }

        // 1b. Stroke Standard Geometry (Uniform outlines)
        if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
          final strokePaint = Paint()
            ..color = layer.strokeColor
            ..strokeWidth = layer.strokeWidth
            ..style = PaintingStyle.stroke;
          canvas.drawPath(layerPath, strokePaint);
        }

        // 1c. Area Strokes (Variable-Width Geometry)
        // This is mathematically a stroke, so we color it using the Stroke Color,
        // but physically it is a 2D mesh, so we use PaintingStyle.fill.
        if (layer.strokeColor != Colors.transparent) {
          final areaStrokePaint = Paint()
            ..color = layer.strokeColor
            ..style = PaintingStyle.fill;
          canvas.drawPath(strokeAreaPath, areaStrokePaint);
        }
      }
    }

    // ==========================================
    // 2. DRAW SCAFFOLDING (WIREFRAMES & POINTS)
    // ==========================================
    if (showScaffolding) {
      final invScale = 1.0 / canvasScale;

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
              _drawDashedLine(canvas, Offset(shape.center.x.value, shape.center.y.value), Offset(shape.radiusPoint!.x.value, shape.radiusPoint!.y.value), scaffoldPaint, invScale);
            }
          } else if (shape is CompassRectangle) {
            shape.paint(canvas, isSelected ? selectedWireframePaint : wireframePaint, showScaffolding: true, isSelected: isSelected);
          } else if (shape is CompassLine) {
            canvas.drawLine(Offset(shape.start.x.value, shape.start.y.value), Offset(shape.end.x.value, shape.end.y.value), isSelected ? selectedWireframePaint : wireframePaint);
          } else if (shape is CompassSpiral) {
            canvas.drawPath(shape.getPath(), isSelected ? selectedWireframePaint : wireframePaint);
            if (isSelected) {
               final scaffoldPaint = Paint()..color = Colors.blue.withOpacity(0.5)..strokeWidth = 1.5 * invScale..style = PaintingStyle.stroke;
               canvas.drawLine(Offset(shape.center.x.value, shape.center.y.value), Offset(shape.startPoint.x.value, shape.startPoint.y.value), scaffoldPaint);
            }
          } else if (shape is CompassXSpline) {
             shape.paint(canvas, isSelected ? selectedWireframePaint : wireframePaint, showScaffolding: true, isSelected: isSelected);
             
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
                 _drawDashedLine(canvas, Offset(cx, cy), Offset(shape.nodes.first.point.x.value, shape.nodes.first.point.y.value), scaffoldPaint, invScale);
               }
             }
          }
        }
      }

      final selForHandles = engine.selectedShape;

      // --- WIDTH HANDLES for the selected X-Spline (W KEY) ---
      if (selForHandles is CompassXSpline && showHandles && isWPressed) {
        _drawWidthHandles(canvas, selForHandles, invScale);
      }

      // --- BEZIER HANDLES for the selected X-Spline ---
      if (selForHandles is CompassXSpline && showHandles && !isWPressed) { 
        _drawBezierHandles(canvas, selForHandles, invScale);
      }

      // --- NEW: MULTI-SELECTION BOUNDING BOX ---
      // Framed dashed box + corner ticks around a 2+ point selection. Drawn after the
      // wireframes (so it frames the whole group) but before the point dots (so the
      // selected dots render on top of the box edge). This is the grabbable affordance
      // that the controller's _isPressOnSelection hit-tests against.
      if (selectionBounds != null) {
        _drawSelectionBounds(canvas, selectionBounds!, invScale);
      }

      // --- EXPLICITLY SELECTED POINT(S) HIGHLIGHT ---
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
        _drawFilletPreview(canvas, activeFilletSpline!, activeFilletNode!, activeFilletRadius, invScale);
      }
      
      // --- TENSION GUIDE LINE (A KEY) ---
      else if (isAPressed && tensionTargetPoint != null && hoverPosition != null) {
        final targetOffset = Offset(tensionTargetPoint!.x.value, tensionTargetPoint!.y.value);
        
        final tensionPaint = Paint()
          ..color = Colors.orangeAccent 
          ..strokeWidth = 2.0 * invScale
          ..style = PaintingStyle.stroke;
          
        _drawDashedLine(canvas, targetOffset, hoverPosition!, tensionPaint, invScale);
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
            
          _drawDashedLine(canvas, rotationPivotOffset!, hoverPosition!, rotPaint, invScale);
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
          _drawDashedLine(canvas, startOffset, hoverPosition!, previewPaint, invScale);
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
      final pointPaint = Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.fill;

      final pointBorderPaint = Paint()
        ..color = pointBorderColor
        ..strokeWidth = 1.5 * invScale
        ..style = PaintingStyle.stroke;

      for (var point in engine.points) {
        if (_isPointUnlocked(point)) {
          final offset = Offset(point.x.value, point.y.value);
          canvas.drawCircle(offset, 5.0 * invScale, pointPaint);
          canvas.drawCircle(offset, 5.0 * invScale, pointBorderPaint);
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

      // --- NEW: Shift-hover "Add Resolution" preview marker ---
      // A green ringed "+" sitting exactly on the segment's parametric center.
      // The outer ring reads as "snapped to the curve -- click to insert a vertex
      // here," distinguishing it from the Add-Point tool's solid disc and from the
      // solid blue structural points. Drawn last so it sits on top of everything.
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

  // --- NEW: Draws the Width Handles (Diamonds) for the Width Tool ---
  void _drawWidthHandles(Canvas canvas, CompassXSpline spline, double invScale) {
    final controls = spline.getEvaluatedControls();
    int n = spline.nodes.length;
    
    final guideLinePaint = Paint()
      ..color = Colors.tealAccent.withOpacity(0.3)
      ..strokeWidth = 1.0 * invScale
      ..style = PaintingStyle.stroke;

    final linePaint = Paint()
      ..color = Colors.tealAccent.withOpacity(0.8)
      ..strokeWidth = 1.5 * invScale
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.teal
      ..style = PaintingStyle.fill;
      
    final activeFillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = pointBorderColor
      ..strokeWidth = 1.0 * invScale
      ..style = PaintingStyle.stroke;

    void drawDiamond(Offset center, bool isActive) {
      final size = isActive ? 8.0 * invScale : 6.0 * invScale;
      final path = Path()
        ..moveTo(center.dx, center.dy - size)
        ..lineTo(center.dx + size, center.dy)
        ..lineTo(center.dx, center.dy + size)
        ..lineTo(center.dx - size, center.dy)
        ..close();
      if (isActive) {
        canvas.drawPath(path, activeFillPaint);
        canvas.drawPath(path, Paint()..color = Colors.teal..strokeWidth = 2.0 * invScale..style = PaintingStyle.stroke);
      } else {
        canvas.drawPath(path, dotPaint);
        canvas.drawPath(path, borderPaint);
      }
    }

    for (int i = 0; i < n; i++) {
      final node = spline.nodes[i];
      final pt = Offset(node.point.x.value, node.point.y.value);
      
      Offset prevPt = spline.isClosed ? Offset(spline.nodes[(i - 1 + n) % n].point.x.value, spline.nodes[(i - 1 + n) % n].point.y.value) : (i > 0 ? Offset(spline.nodes[i - 1].point.x.value, spline.nodes[i - 1].point.y.value) : pt);
      Offset nextPt = spline.isClosed ? Offset(spline.nodes[(i + 1) % n].point.x.value, spline.nodes[(i + 1) % n].point.y.value) : (i < n - 1 ? Offset(spline.nodes[i + 1].point.x.value, spline.nodes[i + 1].point.y.value) : pt);

      final hOut = controls[i].$1;
      final hIn = controls[i].$2;

      Offset vOut = hOut;
      if (vOut.distance < 0.001) vOut = nextPt - pt;
      Offset vIn = Offset(-hIn.dx, -hIn.dy);
      if (vIn.distance < 0.001) vIn = pt - prevPt;

      if (!spline.isClosed) {
        if (i == 0) vIn = vOut;
        if (i == n - 1) vOut = vIn;
      }

      double lenOut = vOut.distance;
      double lenIn = vIn.distance;
      Offset tOut = lenOut > 0.001 ? vOut / lenOut : Offset.zero;
      Offset tIn = lenIn > 0.001 ? vIn / lenIn : Offset.zero;

      Offset T = tIn + tOut;
      double lenT = T.distance;
      if (lenT > 0.001) T = T / lenT; else T = tOut;
      
      Offset N = Offset(-T.dy, T.dx);

      // Faint normal guide lines extending from center (at least 30px so you can always see the axis)
      final leftGuide = pt + N * max(30.0 * invScale, node.widthLeft.value);
      final rightGuide = pt - N * max(30.0 * invScale, node.widthRight.value);
      
      canvas.drawLine(pt, leftGuide, guideLinePaint);
      canvas.drawLine(pt, rightGuide, guideLinePaint);

      final leftActual = pt + N * node.widthLeft.value;
      final rightActual = pt - N * node.widthRight.value;
      
      // Dashed line explicitly from the center outward to each handle
      if (node.widthLeft.value > 0.1) {
        _drawDashedLine(canvas, pt, leftActual, linePaint, invScale);
      }
      if (node.widthRight.value > 0.1) {
        _drawDashedLine(canvas, pt, rightActual, linePaint, invScale);
      }
      
      drawDiamond(leftActual, node == activeWidthNode && activeWidthIsLeft);
      drawDiamond(rightActual, node == activeWidthNode && !activeWidthIsLeft);
    }
  }

  // --- NEW: Draws the dashed, corner-ticked bounding box around a 2+ selection. ---
  // Padded a few px beyond the literal point extents so the outer dots sit inside the
  // frame rather than on its edge. Orange keeps it in the rigid-body visual family and
  // distinct from the blue marquee. The corner ticks are short solid right-angle marks
  // that make it read as a manipulable box ("grab me") instead of a plain outline.
  void _drawSelectionBounds(Canvas canvas, Rect bounds, double invScale) {
    final pad = 10.0 * invScale;
    final box = bounds.inflate(pad);

    final boxPaint = Paint()
      ..color = Colors.orangeAccent.withOpacity(0.9)
      ..strokeWidth = 1.5 * invScale
      ..style = PaintingStyle.stroke;

    // Dashed perimeter (reuse the dashed-line helper edge by edge).
    final tl = box.topLeft;
    final tr = box.topRight;
    final br = box.bottomRight;
    final bl = box.bottomLeft;
    _drawDashedLine(canvas, tl, tr, boxPaint, invScale);
    _drawDashedLine(canvas, tr, br, boxPaint, invScale);
    _drawDashedLine(canvas, br, bl, boxPaint, invScale);
    _drawDashedLine(canvas, bl, tl, boxPaint, invScale);

    // Solid corner ticks -- short right-angle marks at each corner.
    final tickPaint = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 2.0 * invScale
      ..style = PaintingStyle.stroke;
    final t = 8.0 * invScale; // tick arm length

    // Top-left
    canvas.drawLine(tl, tl + Offset(t, 0), tickPaint);
    canvas.drawLine(tl, tl + Offset(0, t), tickPaint);
    // Top-right
    canvas.drawLine(tr, tr + Offset(-t, 0), tickPaint);
    canvas.drawLine(tr, tr + Offset(0, t), tickPaint);
    // Bottom-right
    canvas.drawLine(br, br + Offset(-t, 0), tickPaint);
    canvas.drawLine(br, br + Offset(0, -t), tickPaint);
    // Bottom-left
    canvas.drawLine(bl, bl + Offset(t, 0), tickPaint);
    canvas.drawLine(bl, bl + Offset(0, -t), tickPaint);
  }

  // --- NEW: Draws the curve-aware preview of the fillet while F is held ---
  void _drawFilletPreview(Canvas canvas, CompassXSpline spline, CompassSplineNode node, double cutDistance, double invScale) {
    final fillet = spline.computeFillet(node, cutDistance);
    if (fillet == null) return;

    int index = spline.nodes.indexOf(node);
    int prevIndex = (index - 1 + spline.nodes.length) % spline.nodes.length;
    int nextIndex = (index + 1) % spline.nodes.length;

    final pPrev = Offset(spline.nodes[prevIndex].point.x.value, spline.nodes[prevIndex].point.y.value);
    final pCurr = Offset(node.point.x.value, node.point.y.value);
    final pNext = Offset(spline.nodes[nextIndex].point.x.value, spline.nodes[nextIndex].point.y.value);

    final previewPath = Path();
    
    // Draw from Prev to Cut1
    previewPath.moveTo(pPrev.dx, pPrev.dy);
    previewPath.cubicTo(
      pPrev.dx + fillet.prevHandleOut.dx, pPrev.dy + fillet.prevHandleOut.dy,
      fillet.cutPt1.dx + fillet.node1HandleIn.dx, fillet.cutPt1.dy + fillet.node1HandleIn.dy,
      fillet.cutPt1.dx, fillet.cutPt1.dy,
    );
    
    // Draw the Bridging Arc (Cut1 to Cut2)
    previewPath.cubicTo(
      fillet.cutPt1.dx + fillet.node1HandleOut.dx, fillet.cutPt1.dy + fillet.node1HandleOut.dy,
      fillet.cutPt2.dx + fillet.node2HandleIn.dx, fillet.cutPt2.dy + fillet.node2HandleIn.dy,
      fillet.cutPt2.dx, fillet.cutPt2.dy,
    );
    
    // Draw from Cut2 to Next
    previewPath.cubicTo(
      fillet.cutPt2.dx + fillet.node2HandleOut.dx, fillet.cutPt2.dy + fillet.node2HandleOut.dy,
      pNext.dx + fillet.nextHandleIn.dx, pNext.dy + fillet.nextHandleIn.dy,
      pNext.dx, pNext.dy,
    );

    final linePaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 3.0 * invScale
      ..style = PaintingStyle.stroke;
      
    final scissorPaint = Paint()
      ..color = Colors.redAccent.withOpacity(0.5)
      ..strokeWidth = 2.0 * invScale
      ..style = PaintingStyle.stroke;

    // Draw the new curve. Because it perfectly overlays the existing curve, 
    // it will vividly demonstrate how the fillet blends without jumping.
    canvas.drawPath(previewPath, linePaint);
    
    // Draw scissor lines showing the part of the control polygon that will be deleted
    _drawDashedLine(canvas, fillet.cutPt1, pCurr, scissorPaint, invScale);
    _drawDashedLine(canvas, pCurr, fillet.cutPt2, scissorPaint, invScale);

    // Draw preview nodes
    final nodePaint = Paint()..color = Colors.greenAccent..style = PaintingStyle.fill;
    canvas.drawCircle(fillet.cutPt1, 6.0 * invScale, nodePaint);
    canvas.drawCircle(fillet.cutPt2, 6.0 * invScale, nodePaint);
  }

  void _drawBezierHandles(Canvas canvas, CompassXSpline spline, double invScale) {
    final linePaint = Paint()
      ..color = Colors.purpleAccent.withOpacity(0.6)
      ..strokeWidth = 1.5 * invScale
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.purpleAccent
      ..style = PaintingStyle.fill;

    final dotBorderPaint = Paint()
      ..color = pointBorderColor
      ..strokeWidth = 1.0 * invScale
      ..style = PaintingStyle.stroke;

    final activeFillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final activeBorderPaint = Paint()
      ..color = Colors.purpleAccent
      ..strokeWidth = 2.0 * invScale
      ..style = PaintingStyle.stroke;

    void drawDot(Offset dot, bool isActive) {
      if (isActive) {
        canvas.drawCircle(dot, 9.0 * invScale, activeFillPaint);
        canvas.drawCircle(dot, 9.0 * invScale, activeBorderPaint);
      } else {
        canvas.drawCircle(dot, 7.0 * invScale, dotPaint);
        canvas.drawCircle(dot, 7.0 * invScale, dotBorderPaint);
      }
    }

    for (var node in spline.nodes) {
      if (node.handleIn == null && node.handleOut == null) continue;

      final anchor = Offset(node.point.x.value, node.point.y.value);
      final t = node.tension.value;

      if (node.handleOut != null) {
        final dot = Offset(
          anchor.dx + node.handleOut!.dx * t,
          anchor.dy + node.handleOut!.dy * t,
        );
        canvas.drawLine(anchor, dot, linePaint);
        drawDot(dot, node == activeHandleNode && activeHandleIsOut);
      }

      if (node.handleIn != null) {
        final dot = Offset(
          anchor.dx + node.handleIn!.dx * t,
          anchor.dy + node.handleIn!.dy * t,
        );
        canvas.drawLine(anchor, dot, linePaint);
        drawDot(dot, node == activeHandleNode && !activeHandleIsOut);
      }
    }
  }

  // Decides whether a point gets drawn as a grabbable scaffolding dot.
  //
  // Previously this returned true ONLY when the point was a *structural* member of
  // a visible, unlocked shape (a line endpoint, circle center/radius, spiral
  // center/start, or a spline node). That silently excluded constraint-attached
  // points -- the ones created by "Add Point to Shape" on a line/circle/spiral,
  // which ride the curve via a PointOnLine/Circle/Spiral constraint but are NOT
  // stored in any shape's point list. They were invisible yet still hoverable
  // (the controller's _isPointLocked treats a point belonging to no shape as
  // unlocked), producing the "highlights on mouseover but never shows" bug.
  //
  // New rule, aligned with the hover predicate: a point is drawn when the user can
  // meaningfully grab it --
  //   * it's a structural vertex of a visible shape on a visible, unlocked layer, OR
  //   * it isn't a structural member of ANY shape at all -- i.e. a constraint point
  //     riding a curve, or a free orphan point.
  // It is hidden only when every shape that structurally owns it lives on a hidden
  // or locked layer. That last clause preserves the prior behavior of not spawning
  // floating dots for geometry tucked under a hidden/locked layer (a point whose
  // only home is a hidden layer stays hidden, rather than appearing shapeless).
  bool _isPointUnlocked(CompassPoint p) {
    bool usedInVisibleUnlocked = false;
    bool usedAnywhere = false;

    for (var layer in engine.layers) {
      for (var shape in layer.shapes) {
        bool hasPoint = false;
        if (shape is CompassLine && (shape.start == p || shape.end == p)) hasPoint = true;
        else if (shape is CompassCircle && (shape.center == p || shape.radiusPoint == p)) hasPoint = true;
        else if (shape is CompassSpiral && (shape.center == p || shape.startPoint == p)) hasPoint = true;
        else if (shape is CompassRectangle && (shape.p1 == p || shape.p2 == p)) hasPoint = true;
        else if (shape is CompassXSpline && (shape.nodes.any((n) => n.point == p) || shape.anchorPoint == p)) hasPoint = true;

        if (hasPoint) {
          usedAnywhere = true;
          if (layer.isVisible && !layer.isLocked && shape.isVisible) {
            usedInVisibleUnlocked = true;
          }
        }
      }
    }

    return usedInVisibleUnlocked || !usedAnywhere;
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint, double invScale) {
    final double dashWidth = 6.0 * invScale;
    final double dashSpace = 6.0 * invScale;
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

  @override
  bool shouldRepaint(covariant CompassRenderer oldDelegate) {
    return true; 
  }
}