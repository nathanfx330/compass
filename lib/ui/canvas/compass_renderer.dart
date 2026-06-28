// /lib/ui/canvas/compass_renderer.dart

import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/mesh.dart'; // <--- NEW: gradient mesh

// Import CompassTool from the canvas controller
import 'canvas_controller.dart';
import 'renderer_helpers.dart'; // <--- NEW

class CompassRenderer extends CustomPainter {
  final CompassEngine engine;
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
  final Offset panOffset;
  final double canvasScale;
  final Color pointBorderColor;

  final CompassSplineNode? activeHandleNode;
  final bool activeHandleIsOut;

  final Rect? selectionBounds; 

  CompassRenderer({
    required this.engine, 
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
    required this.panOffset,
    required this.canvasScale,
    required this.pointBorderColor,
    this.activeHandleNode,
    this.activeHandleIsOut = false,
    this.selectionBounds, 
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
        final fillPath = layer.getLayerFillPath();
        final layerPath = layer.getLayerPath();
        final strokeAreaPath = layer.getLayerStrokeAreaPath();

        // 1a. Fill Standard Geometry 
        if (layer.color != Colors.transparent) {
          final fillPaint = Paint()
            ..color = layer.color
            ..style = PaintingStyle.fill;
          canvas.drawPath(fillPath, fillPaint);
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
          final overpaints = layer.getStrokeAddBandOverpaints(fillPath);
          for (final (bandPath, bandColor) in overpaints) {
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

          final clip = layer.getLayerMeshClipPath(shape);
          if (clip.computeMetrics().isEmpty) continue;

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
              RendererHelpers.drawDashedLine(canvas, Offset(shape.center.x.value, shape.center.y.value), Offset(shape.radiusPoint!.x.value, shape.radiusPoint!.y.value), scaffoldPaint, invScale); // <--- UPDATED
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

              // --- UPGRADE: Draw Tension Handles for selected Mesh nodes ---
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
                 RendererHelpers.drawDashedLine(canvas, Offset(cx, cy), Offset(shape.nodes.first.point.x.value, shape.nodes.first.point.y.value), scaffoldPaint, invScale); // <--- UPDATED
               }

               // --- DRAW VERTEX NUMBERS IF TOGGLED ---
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
      if (selForHandles is CompassXSpline && showHandles && isWPressed) {
        RendererHelpers.drawWidthHandles(canvas, selForHandles, invScale, pointBorderColor, activeWidthNode, activeWidthIsLeft); // <--- UPDATED
      }

      // --- BEZIER HANDLES for the selected X-Spline ---
      if (selForHandles is CompassXSpline && showHandles && !isWPressed) { 
        RendererHelpers.drawBezierHandles(canvas, selForHandles, invScale, pointBorderColor, activeHandleNode, activeHandleIsOut); // <--- UPDATED
      }

      // --- MULTI-SELECTION BOUNDING BOX ---
      if (selectionBounds != null) {
        RendererHelpers.drawSelectionBounds(canvas, selectionBounds!, invScale); // <--- UPDATED
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
        RendererHelpers.drawFilletPreview(canvas, activeFilletSpline!, activeFilletNode!, activeFilletRadius, invScale); // <--- UPDATED
      }
      
      // --- TENSION GUIDE LINE (A KEY) ---
      else if (isAPressed && tensionTargetPoint != null && hoverPosition != null) {
        final targetOffset = Offset(tensionTargetPoint!.x.value, tensionTargetPoint!.y.value);
        
        final tensionPaint = Paint()
          ..color = Colors.orangeAccent 
          ..strokeWidth = 2.0 * invScale
          ..style = PaintingStyle.stroke;
          
        RendererHelpers.drawDashedLine(canvas, targetOffset, hoverPosition!, tensionPaint, invScale); // <--- UPDATED
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
            
          RendererHelpers.drawDashedLine(canvas, rotationPivotOffset!, hoverPosition!, rotPaint, invScale); // <--- UPDATED
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
          RendererHelpers.drawDashedLine(canvas, startOffset, hoverPosition!, previewPaint, invScale); // <--- UPDATED
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
        else if (shape is CompassMesh && (shape.containsNode(p) || shape.anchorPoint == p)) hasPoint = true;

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

  @override
  bool shouldRepaint(covariant CompassRenderer oldDelegate) {
    return true; 
  }
}