import 'dart:math';
import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';

// Import CompassTool from the canvas file
import 'compass_canvas.dart';

class CompassRenderer extends CustomPainter {
  final CompassEngine engine;
  final CompassPoint? selectedPoint; 
  final Offset? rotationPivotOffset;
  final bool isRPressed;
  final bool isShiftRPressed;
  final CompassPoint? shapeStartPoint;
  final CompassPoint? hoveredPoint;
  final Offset? hoverPosition;
  final CompassTool currentTool;
  final bool showScaffolding;
  final Offset panOffset;
  final double canvasScale;
  final Color pointBorderColor;

  CompassRenderer({
    required this.engine, 
    this.selectedPoint,
    this.rotationPivotOffset,
    this.isRPressed = false,
    this.isShiftRPressed = false,
    this.shapeStartPoint,
    this.hoveredPoint,
    this.hoverPosition,
    required this.currentTool,
    required this.showScaffolding,
    required this.panOffset,
    required this.canvasScale,
    required this.pointBorderColor,
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
        final layerPath = layer.getLayerPath();

        // 1a. Fill
        if (layer.color != Colors.transparent) {
          final fillPaint = Paint()
            ..color = layer.color
            ..style = PaintingStyle.fill;
          canvas.drawPath(layerPath, fillPaint);
        }

        // 1b. Stroke
        if (layer.strokeColor != Colors.transparent && layer.strokeWidth > 0) {
          final strokePaint = Paint()
            ..color = layer.strokeColor
            ..strokeWidth = layer.strokeWidth
            ..style = PaintingStyle.stroke;
          canvas.drawPath(layerPath, strokePaint);
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
        if (!layer.isVisible) continue;
        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue; 

          final isSelected = shape == engine.selectedShape;
          
          if (shape is CompassCircle) {
            canvas.drawCircle(Offset(shape.center.x.value, shape.center.y.value), shape.radius.value, isSelected ? selectedWireframePaint : wireframePaint);
            if (isSelected && shape.radiusPoint != null) {
              final scaffoldPaint = Paint()..color = Colors.blue.withOpacity(0.5)..strokeWidth = 1.5 * invScale..style = PaintingStyle.stroke;
              _drawDashedLine(canvas, Offset(shape.center.x.value, shape.center.y.value), Offset(shape.radiusPoint!.x.value, shape.radiusPoint!.y.value), scaffoldPaint, invScale);
            }
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
             
             // --- NEW: Draw Centroid Box for selected X-Spline ---
             if (isSelected) {
               double cx = 0, cy = 0;
               // Use anchorPoint visually if it exists
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
               
               // Draw a tether to show it controls the shape
               if (shape.anchorPoint != null && shape.nodes.isNotEmpty) {
                 final scaffoldPaint = Paint()..color = Colors.orangeAccent.withOpacity(0.3)..strokeWidth = 1.0 * invScale..style = PaintingStyle.stroke;
                 _drawDashedLine(canvas, Offset(cx, cy), Offset(shape.nodes.first.point.x.value, shape.nodes.first.point.y.value), scaffoldPaint, invScale);
               }
             }
          }
        }
      }

      // --- EXPLICITLY SELECTED POINT HIGHLIGHT ---
      if (selectedPoint != null) {
        final highlightPaint = Paint()
          ..color = Colors.blueAccent.withOpacity(0.4)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(
          Offset(selectedPoint!.x.value, selectedPoint!.y.value),
          14.0 * invScale,
          highlightPaint,
        );
      }

      // --- ROTATION GUIDE LINE ---
      if ((isRPressed || isShiftRPressed) && hoverPosition != null) {
        if (rotationPivotOffset != null) {
          final rotPaint = Paint()
            ..color = isShiftRPressed ? Colors.deepOrangeAccent : Colors.orangeAccent
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
        }
      }

      // Live rubber-banding for actively drawn X-Spline
      if (currentTool == CompassTool.addPen && hoverPosition != null) {
        CompassXSpline? active;
        for(var layer in engine.layers) {
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
            
           // Draw a solid blue line for Pen Tool preview so it isn't confused with rotation scaffolding
           canvas.drawLine(lastPt, hoverPosition!, previewPaint);
        }
      }


      // Hover Ring
      if (hoveredPoint != null && hoveredPoint != shapeStartPoint && hoveredPoint != selectedPoint) {
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
        final offset = Offset(point.x.value, point.y.value);
        canvas.drawCircle(offset, 5.0 * invScale, pointPaint);
        canvas.drawCircle(offset, 5.0 * invScale, pointBorderPaint);
      }
    }

    canvas.restore();
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