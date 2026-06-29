// /lib/ui/canvas/canvas_gesture_handler.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';

import '../../engine.dart';
import '../../constraints.dart';

import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/mesh.dart';

import 'canvas_controller.dart';
import 'canvas_geometry.dart';
import 'canvas_hit_tester.dart';
import 'canvas_context_menus.dart';

class CanvasGestureHandler {
  
  // ===========================================================================
  // HELPER METHODS (Moved from Controller)
  // ===========================================================================

  static bool isPressOnSelection(CanvasController controller, Offset logical) {
    if (controller.selectedPoints.length < 2) return false;
    final scaledThreshold = controller.hitThreshold / controller.canvasScale;
    for (var p in controller.selectedPoints) {
      if ((Offset(p.x.value, p.y.value) - logical).distance <= scaledThreshold) {
        return true;
      }
    }
    final b = controller.selectionBounds;
    if (b == null) return false;
    return b.inflate(scaledThreshold).contains(logical);
  }

  static void captureSmoothOriginals(CanvasController controller, CompassEngine engine) {
    controller.smoothOrigPositions.clear();
    controller.smoothOrigHandles.clear();

    for (var p in controller.selectedPoints) {
      controller.smoothOrigPositions[p] = Offset(p.x.value, p.y.value);
    }

    for (var layer in engine.layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is! CompassXSpline) continue;
        List<(Offset, Offset)>? controls;
        for (int i = 0; i < shape.nodes.length; i++) {
          final node = shape.nodes[i];
          if (!controller.selectedPoints.contains(node.point)) continue;
          controls ??= shape.getEvaluatedControls();
          controller.smoothOrigHandles[node] = (controls[i].$2, controls[i].$1);
        }
      }
    }
  }

  static void captureSmoothOriginalWidths(CanvasController controller, CompassEngine engine) {
    controller.smoothOrigWidths.clear();
    for (var layer in engine.layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is! CompassXSpline) continue;
        for (var node in shape.nodes) {
          if (!controller.selectedPoints.contains(node.point)) continue;
          controller.smoothOrigWidths[node] = (node.widthLeft.value, node.widthRight.value);
        }
      }
    }
  }

  static bool _nodeHasZeroWidth(CompassSplineNode node) {
    return node.widthLeft.value < 0.01 && node.widthRight.value < 0.01;
  }

  static Offset? _handleDotPosition(CompassSplineNode node, bool isOut) {
    final handle = isOut ? node.handleOut : node.handleIn;
    if (handle == null) return null;
    final t = node.tension.value;
    return Offset(
      node.point.x.value + handle.dx * t,
      node.point.y.value + handle.dy * t,
    );
  }

  // ===========================================================================
  // PAN & SCROLL GESTURES (Canvas Movement)
  // ===========================================================================

  static void startCanvasPan(CanvasController controller) {
    controller.isPanningCanvas = true;
    controller.notifyListeners();
  }

  static void updateCanvasPan(CanvasController controller, Offset delta) {
    if (controller.isPanningCanvas) {
      controller.panOffset += delta;
      controller.notifyListeners();
    }
  }

  static void endCanvasPan(CanvasController controller) {
    if (controller.isPanningCanvas) {
      controller.isPanningCanvas = false;
      controller.notifyListeners();
    }
  }

  static void handleScroll(CanvasController controller, CompassEngine engine, PointerScrollEvent event, BuildContext context) {
    final isRefUnlocked = engine.referenceLayer != null && !engine.referenceLayer!.isLocked;
    
    if (isRefUnlocked) {
      final double zoomDelta = event.scrollDelta.dy > 0 ? -0.1 : 0.1;
      engine.updateReferenceTransform(Offset.zero, zoomDelta, 0);
    } else {
      final RenderBox renderBox = context.findRenderObject() as RenderBox;
      final localPosition = renderBox.globalToLocal(event.position);
      final logicalPoint = controller.getLogicalPosition(localPosition);
      
      final double zoomFactor = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
      double newScale = controller.canvasScale * zoomFactor;
      newScale = newScale.clamp(0.05, 50.0); 
      
      controller.canvasScale = newScale;
      controller.panOffset = localPosition - logicalPoint * controller.canvasScale;
      controller.notifyListeners();
    }
  }

  // ===========================================================================
  // HOVER GESTURES
  // ===========================================================================

  static void onHover(CanvasController controller, CompassEngine engine, PointerHoverEvent event, BuildContext context, bool showScaffolding) {
    if (!showScaffolding) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(event.position);
    final logicalPosition = controller.getLogicalPosition(localPosition);

    controller.hoverPosition = logicalPosition;
    controller.hoveredPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, controller.hitThreshold / controller.canvasScale);

    controller.updateAddVertexHover(logicalPosition);
    controller.updateMeshSliceHover(logicalPosition); 
    
    if ((controller.isRPressed || controller.isShiftRPressed || controller.isCtrlRPressed) && controller.rotationPivotOffset == null && controller.hoveredPoint != null) {
      controller.setupRotationState(hierarchy: controller.isShiftRPressed, handlesOnly: controller.isCtrlRPressed);
    }

    if (controller.isAPressed && controller.targetTensionNode == null && controller.hoveredPoint != null && controller.activeTensionNode == null) {
      for (var layer in engine.layers) {
        if (!layer.isVisible || layer.isLocked) continue; 
        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue;
          
          if (shape is CompassXSpline) {
            for (var node in shape.nodes) {
              if (node.point == controller.hoveredPoint) {
                controller.targetTensionNode = node;
                controller.notifyListeners();
                return;
              }
            }
          } else if (shape is CompassMesh) {
            for (var node in shape.nodes) {
              if (node.point == controller.hoveredPoint) {
                controller.targetTensionNode = node;
                controller.notifyListeners();
                return;
              }
            }
          }
        }
      }
    }
    
    controller.notifyListeners();
  }

  static void clearHover(CanvasController controller) {
    controller.hoverPosition = null;
    controller.hoveredPoint = null;
    controller.clearAddVertexHover();
    controller.clearMeshSliceHover(); 
    controller.notifyListeners();
  }

  // ===========================================================================
  // CLICK GESTURES
  // ===========================================================================

  static Future<void> onSecondaryTapDown(
    CanvasController controller,
    CompassEngine engine,
    TapDownDetails details, 
    BuildContext context, 
    bool showScaffolding, 
    VoidCallback onToggleScaffolding,
    bool showHandles,
    VoidCallback onToggleHandles
  ) async {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = controller.getLogicalPosition(localPosition);

    final selForHandles = engine.selectedShape;
    if (controller.isWPressed && selForHandles is CompassXSpline && showScaffolding && showHandles) {
      final handleThreshold = 24.0 / controller.canvasScale;
      for (var node in selForHandles.nodes) {
         final leftDot = CanvasGeometry.getWidthHandlePosition(node, true, selForHandles); 
         if (leftDot != null && (logicalPosition - leftDot).distance < handleThreshold) {
            CanvasContextMenus.showWidthConstraintMenu(context, engine, details.globalPosition, selForHandles, node, true); 
            return;
         }
         final rightDot = CanvasGeometry.getWidthHandlePosition(node, false, selForHandles); 
         if (rightDot != null && (logicalPosition - rightDot).distance < handleThreshold) {
            CanvasContextMenus.showWidthConstraintMenu(context, engine, details.globalPosition, selForHandles, node, false); 
            return;
         }
      }
    }

    if (controller.currentTool == CompassTool.addPen && controller.activeSpline != null) {
      controller.activeSpline = null;
      controller.currentTool = CompassTool.select;
      controller.notifyListeners();
      return;
    }

    CompassShape? clickedShape;
    final scaledThreshold = controller.hitThreshold / controller.canvasScale;
    CompassPoint? clickedPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, scaledThreshold);

    if (clickedPoint == null) {
      for (var layer in engine.layers.reversed) {
        if (!layer.isVisible || layer.isLocked) continue; 
        for (var shape in layer.shapes.reversed) {
          if (!shape.isVisible) continue; 
          if (shape is CompassLine) {
            final start = Offset(shape.start.x.value, shape.start.y.value);
            final end = Offset(shape.end.x.value, shape.end.y.value);
            final tap = Offset(logicalPosition.dx, logicalPosition.dy);
            final dx = end.dx - start.dx;
            final dy = end.dy - start.dy;
            final l2 = dx * dx + dy * dy;
            double t = 0;
            if (l2 != 0) {
              t = ((tap.dx - start.dx) * dx + (tap.dy - start.dy) * dy) / l2;
              t = max(0, min(1, t)); 
            }
            final projX = start.dx + t * dx;
            final projY = start.dy + t * dy;
            final dist = sqrt((tap.dx - projX) * (tap.dx - projX) + (tap.dy - projY) * (tap.dy - projY));
            if (dist <= scaledThreshold) { clickedShape = shape; break; }
          } else if (shape is CompassCircle) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            
            // Widen the hit-testing radius to include the outward-stacked strokes
            double effR = shape.radius.value + layer.strokeWidth / 2.0;
            for (final r in shape.strokeRegions) {
              if (r.width > 0) effR += r.width;
            }
            effR = max(shape.radius.value, effR);

            final distToCenter = sqrt(pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2));
            final distToCircumference = (distToCenter - effR).abs();
            if (distToCircumference <= scaledThreshold || distToCenter <= effR) { clickedShape = shape; break; }
          } else if (shape is CompassSpiral) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final sx = shape.startPoint.x.value;
            final sy = shape.startPoint.y.value;
            final initialR = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));
            final distToCenter = sqrt(pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2));
            if (distToCenter <= initialR * CompassSpiral.phi * 4) { clickedShape = shape; break; }
          } else if (shape is CompassRectangle) {
             if (shape.getPath().contains(logicalPosition)) { clickedShape = shape; break; }
          } else if (shape is CompassMesh) {
             if (shape.getPath().contains(logicalPosition)) { clickedShape = shape; break; }
          } else if (shape is CompassXSpline) {
             if (shape.getPath().contains(logicalPosition)) { clickedShape = shape; break; }
          }
        }
        if (clickedShape != null) break;
      }
    }

    await CanvasContextMenus.handleSecondaryTap(
      context: context,
      engine: engine,
      controller: controller,
      globalPosition: details.globalPosition,
      logicalPosition: logicalPosition,
      clickedPoint: clickedPoint,
      clickedShape: clickedShape,
      showScaffolding: showScaffolding,
      onToggleScaffolding: onToggleScaffolding,
      showHandles: showHandles,
      onToggleHandles: onToggleHandles,
    );
  }

  static void onTapDown(CanvasController controller, CompassEngine engine, TapDownDetails details, BuildContext context, bool showScaffolding) {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = controller.getLogicalPosition(localPosition);

    final bool isShiftPressed = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);

    if (controller.sliceMesh != null && controller.sliceGap >= 0) {
      final mesh = controller.sliceMesh!;
      if (controller.sliceIsRow) {
        engine.insertMeshRow(mesh, controller.sliceGap, controller.sliceT);
      } else {
        engine.insertMeshColumn(mesh, controller.sliceGap, controller.sliceT);
      }

      if (controller.hoverPosition != null) {
        controller.updateMeshSliceHover(controller.hoverPosition!);
      } else {
        controller.clearMeshSliceHover();
      }

      controller.notifyListeners();
      return;
    }

    if (controller.addVertexSpline != null && controller.addVertexSegmentIndex >= 0) {
      final spline = controller.addVertexSpline!;
      final segIndex = controller.addVertexSegmentIndex;

      // <--- NEW: Pass the exact positional offset down to bypass raw splits --->
      final created = engine.subdivideSplineSegment(spline, segIndex, t: 0.5, exactPos: controller.addVertexPreviewPos);
      if (created != null) {
        engine.selectShape(spline);
        controller.selectedPoints = {created};
      }

      if (controller.hoverPosition != null) {
        controller.updateAddVertexHover(controller.hoverPosition!);
      } else {
        controller.clearAddVertexHover();
      }

      controller.notifyListeners();
      return;
    }

    if (controller.currentTool == CompassTool.select) {
      CompassPoint? hitPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, controller.hitThreshold / controller.canvasScale);

      final pressOnSelectionMember = hitPoint != null && controller.selectedPoints.contains(hitPoint);
      final pressInsideBox = hitPoint == null && isPressOnSelection(controller, logicalPosition);
      if (controller.selectedPoints.length >= 2 && (pressOnSelectionMember || pressInsideBox)) {
        controller.pendingSelectPress = (hitPoint, isShiftPressed);
        return;
      }

      if (hitPoint != null) {
        if (isShiftPressed) {
          if (controller.selectedPoints.contains(hitPoint)) {
            controller.selectedPoints.remove(hitPoint);
          } else {
            controller.selectedPoints.add(hitPoint); 
          }
        } else {
          controller.selectedPoints = {hitPoint}; 
        }
        controller.notifyListeners();

        CompassShape? ownerShape;
        for (var layer in engine.layers.reversed) {
          if (!layer.isVisible || layer.isLocked) continue; 
          for (var shape in layer.shapes.reversed) {
            if (!shape.isVisible) continue;
            if (shape is CompassXSpline && (shape.nodes.any((n) => n.point == hitPoint) || shape.anchorPoint == hitPoint)) { ownerShape = shape; break; } 
            else if (shape is CompassMesh && (shape.containsNode(hitPoint) || shape.anchorPoint == hitPoint)) { ownerShape = shape; break; }
            else if (shape is CompassCircle && (shape.center == hitPoint || shape.radiusPoint == hitPoint)) { ownerShape = shape; break; } 
            else if (shape is CompassRectangle && (shape.p1 == hitPoint || shape.p2 == hitPoint)) { ownerShape = shape; break; } 
            else if (shape is CompassLine && (shape.start == hitPoint || shape.end == hitPoint)) { ownerShape = shape; break; } 
            else if (shape is CompassSpiral && (shape.center == hitPoint || shape.startPoint == hitPoint)) { ownerShape = shape; break; }
          }
          if (ownerShape != null) break;
        }

        engine.selectShape(ownerShape);
        return;
      }

      CompassShape? hitShape;
      for (var layer in engine.layers.reversed) {
        if (!layer.isVisible || layer.isLocked) continue; 
        for (var shape in layer.shapes.reversed) {
          if (!shape.isVisible) continue; 

          if (shape is CompassCircle) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            
            // Widen the hit-testing radius to include the outward-stacked strokes
            double effR = shape.radius.value + layer.strokeWidth / 2.0;
            for (final r in shape.strokeRegions) {
              if (r.width > 0) effR += r.width;
            }
            effR = max(shape.radius.value, effR);

            final dist2 = pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2);
            if (dist2 <= effR * effR) { hitShape = shape; break; }
          } else if (shape is CompassSpiral) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final sx = shape.startPoint.x.value;
            final sy = shape.startPoint.y.value;
            final initialR = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));
            final distToCenter = sqrt(pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2));
            if (distToCenter <= initialR * CompassSpiral.phi * 4) { hitShape = shape; break; }
          } else if (shape is CompassRectangle) { 
             if (shape.getPath().contains(logicalPosition)) { hitShape = shape; break; }
          } else if (shape is CompassMesh) {
             if (shape.getPath().contains(logicalPosition)) { hitShape = shape; break; }
          } else if (shape is CompassXSpline) {
             if (shape.getPath().contains(logicalPosition)) { hitShape = shape; break; }
          }
        }
        if (hitShape != null) break;
      }

      if (hitShape == null && controller.hoveredPoint == null) {
        engine.selectShape(null);
        controller.selectedPoints.clear(); 
        controller.notifyListeners();
      } else if (hitShape != null) {
        engine.selectShape(hitShape);
        controller.selectedPoints.clear(); 
        controller.notifyListeners();
      }
    }
    else if (controller.currentTool == CompassTool.addPoint) {
      CompassShape? closestShape;
      double minDistance = controller.hitThreshold / controller.canvasScale;

      for (var layer in engine.layers) {
        if (!layer.isVisible || layer.isLocked) continue; 
        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue; 

          if (shape is CompassLine) {
            final start = Offset(shape.start.x.value, shape.start.y.value);
            final end = Offset(shape.end.x.value, shape.end.y.value);
            final tap = Offset(logicalPosition.dx, logicalPosition.dy);
            final dx = end.dx - start.dx;
            final dy = end.dy - start.dy;
            final l2 = dx * dx + dy * dy;
            double t = 0;
            if (l2 != 0) {
              t = ((tap.dx - start.dx) * dx + (tap.dy - start.dy) * dy) / l2;
              t = max(0, min(1, t)); 
            }
            final projX = start.dx + t * dx;
            final projY = start.dy + t * dy;
            final dist = sqrt((tap.dx - projX) * (tap.dx - projX) + (tap.dy - projY) * (tap.dy - projY));
            if (dist < minDistance) { minDistance = dist; closestShape = shape; }
          } else if (shape is CompassCircle) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final r = shape.radius.value;
            final tap = Offset(logicalPosition.dx, logicalPosition.dy);
            final distToCenter = sqrt((tap.dx - cx) * (tap.dx - cx) + (tap.dy - cy) * (tap.dy - cy));
            final distToCircumference = (distToCenter - r).abs();
            if (distToCircumference < minDistance) { minDistance = distToCircumference; closestShape = shape; }
          } else if (shape is CompassSpiral) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final sx = shape.startPoint.x.value;
            final sy = shape.startPoint.y.value;
            final initialR = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));
            final distToCenter = sqrt(pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2));
            if (distToCenter <= initialR * CompassSpiral.phi * 4) { minDistance = 0; closestShape = shape; }
          } else if (shape is CompassRectangle) {
            final p1 = Offset(shape.p1.x.value, shape.p1.y.value);
            final p2 = Offset(shape.p2.x.value, shape.p2.y.value);
            final tap = Offset(logicalPosition.dx, logicalPosition.dy);
            final corners = [p1, Offset(p2.dx, p1.dy), p2, Offset(p1.dx, p2.dy)];
            double minDistToRect = double.infinity;
            for (int i = 0; i < 4; i++) {
              final a = corners[i];
              final b = corners[(i + 1) % 4];
              final l2 = (b.dx - a.dx) * (b.dx - a.dx) + (b.dy - a.dy) * (b.dy - a.dy);
              double t = 0;
              if (l2 != 0) {
                t = ((tap.dx - a.dx) * (b.dx - a.dx) + (tap.dy - a.dy) * (b.dy - a.dy)) / l2;
                t = max(0, min(1, t));
              }
              final proj = Offset(a.dx + t * (b.dx - a.dx), a.dy + t * (b.dy - a.dy));
              final dist = (tap - proj).distance;
              if (dist < minDistToRect) minDistToRect = dist;
            }
            if (minDistToRect < minDistance) { minDistance = minDistToRect; closestShape = shape; }
          } else if (shape is CompassXSpline) {
            final tap = Offset(logicalPosition.dx, logicalPosition.dy);
            double minDistToSpline = double.infinity;
            int loopCount = shape.isClosed ? shape.nodes.length : shape.nodes.length - 1;
            for (int i = 0; i < loopCount; i++) {
              final p1 = Offset(shape.nodes[i].point.x.value, shape.nodes[i].point.y.value);
              final p2 = Offset(shape.nodes[(i + 1) % shape.nodes.length].point.x.value, shape.nodes[(i + 1) % shape.nodes.length].point.y.value);
              final l2 = (p2.dx - p1.dx) * (p2.dx - p1.dx) + (p2.dy - p1.dy) * (p2.dy - p1.dy);
              double t = 0;
              if (l2 != 0) {
                t = ((tap.dx - p1.dx) * (p2.dx - p1.dx) + (tap.dy - p1.dy) * (p2.dy - p1.dy)) / l2;
                t = max(0, min(1, t));
              }
              final proj = Offset(p1.dx + t * (p2.dx - p1.dx), p1.dy + t * (p2.dy - p1.dy));
              final dist = (tap - proj).distance;
              if (dist < minDistToSpline) minDistToSpline = dist;
            }
            if (minDistToSpline < minDistance) { minDistance = minDistToSpline; closestShape = shape; }
          }
        }
      }

      final newPoint = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
      engine.addPoint(newPoint);

      if (closestShape is CompassLine) {
        engine.addPointOnLine(newPoint, closestShape);
      } else if (closestShape is CompassCircle) {
        engine.addPointOnCircle(newPoint, closestShape);
      } else if (closestShape is CompassSpiral) {
        engine.addPointOnSpiral(newPoint, closestShape);
      } else if (closestShape is CompassRectangle) {
        engine.convertRectangleToSpline(closestShape);
        CompassXSpline? newSpline;
        for (var layer in engine.layers) {
          for (var s in layer.shapes) {
            if (s is CompassXSpline && s.anchorPoint != null) {
              final cx = (closestShape.p1.x.value + closestShape.p2.x.value) / 2;
              final cy = (closestShape.p1.y.value + closestShape.p2.y.value) / 2;
              if ((s.anchorPoint!.x.value - cx).abs() < 0.1 && (s.anchorPoint!.y.value - cy).abs() < 0.1) {
                newSpline = s; break;
              }
            }
          }
          if (newSpline != null) break;
        }
        if (newSpline != null) engine.insertPointIntoSpline(newPoint, newSpline);
      } else if (closestShape is CompassXSpline) {
        engine.insertPointIntoSpline(newPoint, closestShape);
      }
    } 
    else if (controller.currentTool == CompassTool.addPen) {
      CompassPoint tappedPoint;
      if (controller.hoveredPoint != null) {
        tappedPoint = controller.hoveredPoint!;
      } else {
        tappedPoint = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
        engine.addPoint(tappedPoint);
      }

      if (controller.activeSpline == null) {
        controller.activeSpline = CompassXSpline(isClosed: false);
        final node = CompassSplineNode(point: tappedPoint, tension: 1.0); 
        node.tension.addListener(engine.notifyListeners);
        controller.activeSpline!.addNode(node);
        engine.addShape(controller.activeSpline!);
      } else {
        if (controller.activeSpline!.nodes.isNotEmpty && controller.activeSpline!.nodes.first.point == tappedPoint) {
          engine.toggleSplineClosed(controller.activeSpline!);
          controller.activeSpline = null;
          controller.currentTool = CompassTool.select;
          controller.notifyListeners();
        } else {
          final node = CompassSplineNode(point: tappedPoint, tension: 1.0);
          node.tension.addListener(engine.notifyListeners);
          controller.activeSpline!.addNode(node);
          engine.notifyListeners();
        }
      }
    }
    else if (controller.currentTool == CompassTool.addLine || controller.currentTool == CompassTool.addCircle || controller.currentTool == CompassTool.addSpiral || controller.currentTool == CompassTool.addRect) {
      if (isShiftPressed) {
        final quickOffset = 100 / controller.canvasScale; 
        if (controller.currentTool == CompassTool.addLine) {
          final p1 = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final p2 = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy + quickOffset);
          engine.addPoint(p1); engine.addPoint(p2);
          engine.addShape(CompassLine(start: p1, end: p2));
        } else if (controller.currentTool == CompassTool.addCircle) {
          final center = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final radiusPoint = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy);
          engine.addPoint(center); engine.addPoint(radiusPoint);
          center.attach(radiusPoint); 
          final circle = CompassCircle(center: center, radiusPoint: radiusPoint, radius: 0);
          DistanceRadiusConstraint(p1: center, p2: radiusPoint, targetRadius: circle.radius);
          engine.addShape(circle);
        } else if (controller.currentTool == CompassTool.addSpiral) {
          final center = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final startPoint = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy);
          engine.addPoint(center); engine.addPoint(startPoint);
          center.attach(startPoint);
          final spiral = CompassSpiral(center: center, startPoint: startPoint);
          engine.addShape(spiral);
        } else if (controller.currentTool == CompassTool.addRect) {
          final p1 = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final p2 = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy + quickOffset);
          engine.addPoint(p1); engine.addPoint(p2);
          final rect = CompassRectangle(p1: p1, p2: p2, isSquare: true);
          SquareConstraint(rect: rect);
          engine.addShape(rect);
        }
        controller.shapeStartPoint = null;
        controller.notifyListeners();
        return; 
      }

      CompassPoint? tappedPoint;
      if (controller.hoveredPoint != null) {
        tappedPoint = controller.hoveredPoint;
      } else {
        tappedPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, controller.hitThreshold / controller.canvasScale);
      }

      if (tappedPoint == null) {
        tappedPoint = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
        engine.addPoint(tappedPoint);
      }

      if (controller.shapeStartPoint == null) {
        controller.shapeStartPoint = tappedPoint;
        controller.notifyListeners();
      } else {
        if (controller.shapeStartPoint != tappedPoint) {
          if (controller.currentTool == CompassTool.addLine) {
            engine.addShape(CompassLine(start: controller.shapeStartPoint!, end: tappedPoint!));
          } else if (controller.currentTool == CompassTool.addCircle) {
            final circle = CompassCircle(center: controller.shapeStartPoint!, radiusPoint: tappedPoint!, radius: 0);
            controller.shapeStartPoint!.attach(tappedPoint!);
            DistanceRadiusConstraint(p1: controller.shapeStartPoint!, p2: tappedPoint!, targetRadius: circle.radius);
            engine.addShape(circle);
          } else if (controller.currentTool == CompassTool.addSpiral) {
            final spiral = CompassSpiral(center: controller.shapeStartPoint!, startPoint: tappedPoint!);
            controller.shapeStartPoint!.attach(tappedPoint!);
            engine.addShape(spiral);
          } else if (controller.currentTool == CompassTool.addRect) { 
            final rect = CompassRectangle(p1: controller.shapeStartPoint!, p2: tappedPoint!);
            SquareConstraint(rect: rect); 
            engine.addShape(rect);
          }
        }
        controller.shapeStartPoint = null;
        controller.notifyListeners();
      }
    }
  }

  static void onTap(CanvasController controller, CompassEngine engine) {
    final pending = controller.pendingSelectPress;
    controller.pendingSelectPress = null;
    if (pending == null) return;

    final (hitPoint, wasShift) = pending;

    if (hitPoint != null) {
      if (wasShift) {
        if (controller.selectedPoints.contains(hitPoint)) {
          controller.selectedPoints.remove(hitPoint);
        } else {
          controller.selectedPoints.add(hitPoint);
        }
      } else {
        controller.selectedPoints = {hitPoint};

        CompassShape? ownerShape;
        for (var layer in engine.layers.reversed) {
          if (!layer.isVisible || layer.isLocked) continue;
          for (var shape in layer.shapes.reversed) {
            if (!shape.isVisible) continue;
            if (shape is CompassXSpline && (shape.nodes.any((n) => n.point == hitPoint) || shape.anchorPoint == hitPoint)) { ownerShape = shape; break; } 
            else if (shape is CompassMesh && (shape.containsNode(hitPoint) || shape.anchorPoint == hitPoint)) { ownerShape = shape; break; }
            else if (shape is CompassCircle && (shape.center == hitPoint || shape.radiusPoint == hitPoint)) { ownerShape = shape; break; } 
            else if (shape is CompassRectangle && (shape.p1 == hitPoint || shape.p2 == hitPoint)) { ownerShape = shape; break; } 
            else if (shape is CompassLine && (shape.start == hitPoint || shape.end == hitPoint)) { ownerShape = shape; break; } 
            else if (shape is CompassSpiral && (shape.center == hitPoint || shape.startPoint == hitPoint)) { ownerShape = shape; break; }
          }
          if (ownerShape != null) break;
        }
        engine.selectShape(ownerShape);
      }
    } else {
      if (!wasShift) {
        controller.selectedPoints.clear();
        engine.selectShape(null);
      }
    }
    controller.notifyListeners();
  }

  static void onTapCancel(CanvasController controller) {
    controller.pendingSelectPress = null;
  }

  // ===========================================================================
  // DRAG GESTURES
  // ===========================================================================

  static void onPanStart(CanvasController controller, CompassEngine engine, DragStartDetails details, BuildContext context, bool showScaffolding, bool showHandles) {
    if (controller.currentTool != CompassTool.select) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = controller.getLogicalPosition(localPosition);

    controller.lastPanPosition = logicalPosition;
    controller.dragStartLogicalPosition = logicalPosition;
    controller.hoverPosition = logicalPosition; 
    controller.notifyListeners();

    if (controller.isXPressed && controller.sliceMesh != null) {
      return;
    }

    if ((controller.isRPressed || controller.isShiftRPressed || controller.isCtrlRPressed) && controller.rotationPivotOffset != null) {
      controller.isRotating = true;
      
      if (!controller.isCtrlRPressed) {
        for (var p in controller.transformingPoints) p.isBeingDragged = true;
      }

      controller.rotatingHandleNodes.clear();
      for (var layer in engine.layers) {
        if (layer.isLocked) continue; 
        for (var shape in layer.shapes) {
          if (shape is CompassXSpline) {
            for (var node in shape.nodes) {
              if (controller.transformingPoints.contains(node.point)) {
                if (controller.isCtrlRPressed && node.handleIn == null && node.handleOut == null) {
                  engine.convertPointToBezier(node.point);
                }
                if (node.handleIn != null || node.handleOut != null) {
                  controller.rotatingHandleNodes.add(node);
                }
              }
            }
          }
        }
      }
      return; 
    }

    if (controller.isShiftZPressed && controller.selectedPoints.isNotEmpty) {
      captureSmoothOriginalWidths(controller, engine);
      controller.isWidthSmoothing = true;
      controller.notifyListeners();
      return;
    }

    if (controller.isZPressed && controller.selectedPoints.isNotEmpty) {
      captureSmoothOriginals(controller, engine);
      controller.isSmoothing = true;
      controller.notifyListeners();
      return;
    }

    final selForHandles = engine.selectedShape;

    if (selForHandles is CompassXSpline && showScaffolding && 
        !controller.isShiftPressed && !controller.isRPressed && !controller.isAPressed) {
      
      final handleThreshold = 15.0 / controller.canvasScale;
      for (var node in selForHandles.nodes) {
        if (node.cornerRadius.value > 0.01) {
          final pt = Offset(node.point.x.value, node.point.y.value);
          final distToCenter = (logicalPosition - pt).distance;
          final distToRim = (distToCenter - node.cornerRadius.value).abs();
          
          if (distToRim < handleThreshold) {
            // Both pulley constraints reuse this exact same controller slot to drag their scale
            controller.activeCornerCircleNode = node;
            controller.notifyListeners();
            return;
          }
        } else if (node.miterSize.value > 0.01) {
          // Miter pulley rim hit-test (same drag slot as the round pulley)
          final pt = Offset(node.point.x.value, node.point.y.value);
          final distToCenter = (logicalPosition - pt).distance;
          final distToRim = (distToCenter - node.miterSize.value).abs();
          
          if (distToRim < handleThreshold) {
            controller.activeCornerCircleNode = node;
            controller.notifyListeners();
            return;
          }
        }
      }
    }

    if (controller.selectedPoints.length >= 2 &&
        !controller.isRPressed && !controller.isShiftRPressed && !controller.isCtrlRPressed && !controller.isAPressed && !controller.isFPressed && !controller.isWPressed && !controller.isZPressed && !controller.isShiftZPressed) {
      final hp = CanvasHitTester.hitTestPoint(engine, logicalPosition, controller.hitThreshold / controller.canvasScale);
      final onMember = hp != null && controller.selectedPoints.contains(hp);
      final inBoxNoDot = hp == null && isPressOnSelection(controller, logicalPosition);

      if (onMember || inBoxNoDot) {
        controller.pendingSelectPress = null; 

        final liveShift = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
            HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);

        controller.transformingPoints = Set<CompassPoint>.from(controller.selectedPoints);
        for (var p in controller.transformingPoints) p.isBeingDragged = true;

        if (liveShift) {
          controller.isStrictPanningSelection = true;
        } else {
          controller.isPanningSelectedPoints = true;
        }
        return;
      }
    }

    if (controller.isShiftPressed && !controller.isRPressed && !controller.isShiftRPressed && !controller.isCtrlRPressed && !controller.isAPressed && !controller.isWPressed && !controller.isShiftZPressed) {
      if (controller.hoveredPoint != null || engine.selectedShape != null) {
        controller.transformingPoints = CanvasGeometry.getRigidBody(engine, engine.selectedShape, controller.hoveredPoint, true); 
        if (controller.transformingPoints.isNotEmpty) {
          controller.isPanningShape = true;
          for (var p in controller.transformingPoints) p.isBeingDragged = true;
          return;
        }
      }
    }

    if (controller.isAPressed && controller.targetTensionNode != null) {
      controller.activeTensionNode = controller.targetTensionNode;
      return;
    }

    if (controller.isFPressed && controller.selectedPoints.isNotEmpty) {
      final targetPoint = controller.selectedPoints.first;
      for (var layer in engine.layers) {
        if (!layer.isVisible || layer.isLocked) continue; 
        for (var shape in layer.shapes) {
          if (shape is CompassXSpline) {
            for (int i = 0; i < shape.nodes.length; i++) {
              final node = shape.nodes[i];
              if (node.point == targetPoint) {
                if (!shape.isClosed && (i == 0 || i == shape.nodes.length - 1)) continue;
                
                controller.activeFilletNode = node;
                controller.activeFilletSpline = shape;
                controller.activeFilletRadius = 0.0;
                controller.notifyListeners();
                return;
              }
            }
          }
        }
      }
    }

    if (selForHandles is CompassXSpline && showScaffolding && showHandles && controller.isWPressed) {
      final handleThreshold = 24.0 / controller.canvasScale;
      for (var node in selForHandles.nodes) {
        if (_nodeHasZeroWidth(node)) {
          final center = Offset(node.point.x.value, node.point.y.value);
          if ((logicalPosition - center).distance < handleThreshold) {
            controller.activeWidthNode = node;
            controller.activeWidthIsLeft = true; 
            controller.isUnifiedWidthPull = true;
            controller.activeWidthSpline = selForHandles; 
            controller.notifyListeners();
            return;
          }
          continue; 
        }

        final leftDot = CanvasGeometry.getWidthHandlePosition(node, true, selForHandles); 
        if (leftDot != null && (logicalPosition - leftDot).distance < handleThreshold) {
          controller.activeWidthNode = node;
          controller.activeWidthIsLeft = true;
          controller.isUnifiedWidthPull = false;
          controller.activeWidthSpline = selForHandles; 
          controller.notifyListeners();
          return;
        }

        final rightDot = CanvasGeometry.getWidthHandlePosition(node, false, selForHandles); 
        if (rightDot != null && (logicalPosition - rightDot).distance < handleThreshold) {
          controller.activeWidthNode = node;
          controller.activeWidthIsLeft = false;
          controller.isUnifiedWidthPull = false;
          controller.activeWidthSpline = selForHandles; 
          controller.notifyListeners();
          return;
        }
      }
    }

    if (selForHandles is CompassXSpline && showScaffolding && showHandles && 
        !controller.isShiftPressed && !controller.isRPressed && !controller.isShiftRPressed && !controller.isCtrlRPressed && !controller.isAPressed && !controller.isFPressed && !controller.isWPressed && !controller.isZPressed && !controller.isShiftZPressed) {
      final handleThreshold = 24.0 / controller.canvasScale;
      for (var node in selForHandles.nodes) {
        if (node.handleIn == null && node.handleOut == null) continue;

        final outDot = _handleDotPosition(node, true);
        if (outDot != null && (logicalPosition - outDot).distance < handleThreshold) {
          engine.commitNodeToBezierEdit(node);
          controller.activeHandleNode = node;
          controller.activeHandleIsOut = true;
          controller.notifyListeners();
          return;
        }

        final inDot = _handleDotPosition(node, false);
        if (inDot != null && (logicalPosition - inDot).distance < handleThreshold) {
          engine.commitNodeToBezierEdit(node);
          controller.activeHandleNode = node;
          controller.activeHandleIsOut = false;
          controller.notifyListeners();
          return;
        }
      }
    }

    if (showScaffolding) {
       if (selForHandles is CompassXSpline) {
         for (var node in selForHandles.nodes) {
            final pt = Offset(node.point.x.value, node.point.y.value);
            final handlePt = pt + const Offset(20, -30); 
            final dist = (logicalPosition - handlePt).distance;
            if (dist < (15.0 / controller.canvasScale)) {
              controller.activeTensionNode = node;
              return; 
            }
         }
       } else if (selForHandles is CompassMesh) {
         for (var node in selForHandles.nodes) {
            final pt = Offset(node.point.x.value, node.point.y.value);
            final handlePt = pt + const Offset(20, -30); 
            final dist = (logicalPosition - handlePt).distance;
            if (dist < (15.0 / controller.canvasScale)) {
              controller.activeTensionNode = node;
              return; 
            }
         }
       }
    }

    CompassPoint? hitPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, controller.hitThreshold / controller.canvasScale);

    if (hitPoint != null) {
      if (!controller.selectedPoints.contains(hitPoint)) {
        if (!controller.isShiftPressed) controller.selectedPoints.clear();
        controller.selectedPoints.add(hitPoint); 
      }
      controller.notifyListeners();
      
      controller.isPanningSelectedPoints = true;
      controller.transformingPoints = Set.from(controller.selectedPoints);
      for (var p in controller.transformingPoints) p.isBeingDragged = true;
    } else {
      controller.isDraggingSelectionBox = true;
      controller.selectionBoxStart = logicalPosition;
      controller.selectionBoxCurrent = logicalPosition;
      if (!controller.isShiftPressed) controller.selectedPoints.clear();
      controller.initialSelectionBeforeBox = Set.from(controller.selectedPoints);
      controller.notifyListeners();
    }
  }

  static void onPanUpdate(CanvasController controller, CompassEngine engine, DragUpdateDetails details, BuildContext context, bool showScaffolding) {
    if (controller.currentTool != CompassTool.select || controller.lastPanPosition == null) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    Offset logicalPosition = controller.getLogicalPosition(localPosition);

    if (controller.dragStartLogicalPosition != null) {
      if (controller.is1Pressed) {
        logicalPosition = Offset(logicalPosition.dx, controller.dragStartLogicalPosition!.dy);
      }
      if (controller.is2Pressed) {
        logicalPosition = Offset(controller.dragStartLogicalPosition!.dx, logicalPosition.dy);
      }
    }

    controller.hoverPosition = logicalPosition; 
    controller.notifyListeners();

    final dx = logicalPosition.dx - controller.lastPanPosition!.dx;
    final dy = logicalPosition.dy - controller.lastPanPosition!.dy;

    if (controller.activeCornerCircleNode != null) {
      final node = controller.activeCornerCircleNode!;
      final pt = Offset(node.point.x.value, node.point.y.value);
      
      final newRadius = (logicalPosition - pt).distance;
      if (node.cornerRadius.value > 0.01) {
        node.cornerRadius.value = max(1.0, newRadius); 
      } else if (node.miterSize.value > 0.01) {
        // Miter pulley rim drag
        node.miterSize.value = max(1.0, newRadius); 
      }
      
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.isRotating && controller.rotationPivotOffset != null) {
      final pivot = controller.rotationPivotOffset!;
      final startAngle = atan2(controller.lastPanPosition!.dy - pivot.dy, controller.lastPanPosition!.dx - pivot.dx);
      final currentAngle = atan2(logicalPosition.dy - pivot.dy, logicalPosition.dx - pivot.dx);
      final deltaAngle = currentAngle - startAngle;

      final cosA = cos(deltaAngle);
      final sinA = sin(deltaAngle);

      if (!controller.isCtrlRPressed) {
        for (var child in controller.transformingPoints) {
          final pointDx = child.x.value - pivot.dx;
          final pointDy = child.y.value - pivot.dy;
          
          child.x.value = pivot.dx + (pointDx * cosA - pointDy * sinA);
          child.y.value = pivot.dy + (pointDx * sinA + pointDy * cosA);
        }
      }

      for (var node in controller.rotatingHandleNodes) {
        if (node.handleIn != null) {
          final h = node.handleIn!;
          node.handleIn = Offset(
            h.dx * cosA - h.dy * sinA,
            h.dx * sinA + h.dy * cosA,
          );
        }
        if (node.handleOut != null) {
          final h = node.handleOut!;
          node.handleOut = Offset(
            h.dx * cosA - h.dy * sinA,
            h.dx * sinA + h.dy * cosA,
          );
        }
      }
      
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.isPanningShape) {
      for (var p in controller.transformingPoints) {
        p.x.value += dx;
        p.y.value += dy;
      }
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.isStrictPanningSelection) {
      for (var p in controller.transformingPoints) {
        p.x.value += dx;
        p.y.value += dy;
      }
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.isWidthSmoothing) {
      final start = controller.dragStartLogicalPosition ?? controller.lastPanPosition!;
      final dist = (logicalPosition - start).distance;
      final amount = (dist * 0.01).clamp(0.0, 1.0);
      engine.smoothWidths(
        controller.selectedPoints,
        controller.smoothOrigWidths,
        amount,
      );
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.isSmoothing) {
      final start = controller.dragStartLogicalPosition ?? controller.lastPanPosition!;
      final dist = (logicalPosition - start).distance;
      final amount = (dist * 0.01).clamp(0.0, 1.0);
      engine.smoothNodes(
        controller.selectedPoints,
        controller.smoothOrigPositions,
        controller.smoothOrigHandles,
        amount,
      );
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.activeFilletNode != null && controller.activeFilletSpline != null) {
      controller.activeFilletRadius += dx;
      if (controller.activeFilletRadius < 0.0) controller.activeFilletRadius = 0.0;
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.activeWidthNode != null && controller.activeWidthSpline != null) {
      final node = controller.activeWidthNode!;
      final pt = Offset(node.point.x.value, node.point.y.value);
      final newWidth = (logicalPosition - pt).distance;

      final liveShift = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
          HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);

      if (controller.isUnifiedWidthPull || liveShift) {
        engine.updateNodeWidth(controller.activeWidthSpline!, node, newWidth, true);
        engine.updateNodeWidth(controller.activeWidthSpline!, node, newWidth, false);
      } else {
        engine.updateNodeWidth(controller.activeWidthSpline!, node, newWidth, controller.activeWidthIsLeft);
      }
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.activeHandleNode != null) {
      final node = controller.activeHandleNode!;
      final newHandle = Offset(
        logicalPosition.dx - node.point.x.value,
        logicalPosition.dy - node.point.y.value,
      );
      engine.updateNodeHandle(node, controller.activeHandleIsOut, newHandle);
      controller.lastPanPosition = logicalPosition;
      return;
    }

    if (controller.isDraggingSelectionBox && controller.selectionBoxStart != null) {
       controller.selectionBoxCurrent = logicalPosition;
       final rect = Rect.fromPoints(controller.selectionBoxStart!, controller.selectionBoxCurrent!);
       final newSelection = Set<CompassPoint>.from(controller.initialSelectionBeforeBox);
       
       for(var p in engine.points) {
         if (CanvasHitTester.isPointLocked(engine, p)) continue;
         if (rect.contains(Offset(p.x.value, p.y.value))) {
           newSelection.add(p);
         }
       }
       
       controller.selectedPoints = newSelection;
       controller.notifyListeners();
       controller.lastPanPosition = logicalPosition;
       return;
    }

    if (controller.activeTensionNode != null) {
       if (controller.isAPressed) {
         final nodePos = Offset(controller.activeTensionNode!.point.x.value, controller.activeTensionNode!.point.y.value);
         final dist = (logicalPosition - nodePos).distance;
         double newTension = dist * 0.01;
         controller.activeTensionNode!.tension.value = max(0.0, newTension);
       } else {
         final physicalDy = details.delta.dy; 
         final tensionDelta = -physicalDy * 0.005; 
         double newTension = controller.activeTensionNode!.tension.value + tensionDelta;
         controller.activeTensionNode!.tension.value = max(0.0, newTension);
       }
    } 
    else if (controller.isPanningSelectedPoints) {
      final visited = <CompassPoint>{};
      for (var p in controller.transformingPoints) {
        p.moveBy(dx, dy, visited: visited);
      }
    } 
    else if (engine.referenceLayer != null && !engine.referenceLayer!.isLocked) {
      engine.updateReferenceTransform(Offset(dx * controller.canvasScale, dy * controller.canvasScale), 0, 0);
    }

    controller.lastPanPosition = logicalPosition;
  }

  static void onPanEnd(CanvasController controller, CompassEngine engine, DragEndDetails details) {
    if (controller.isRotating || controller.isPanningShape) {
      controller.isRotating = false;
      controller.isPanningShape = false;
      controller.rotatingHandleNodes.clear();
      for (var p in controller.transformingPoints) p.isBeingDragged = false;
      engine.finalizePointDrag(); 
    } else if (controller.isStrictPanningSelection) {
      controller.isStrictPanningSelection = false;
      for (var p in controller.transformingPoints) p.isBeingDragged = false;
      engine.finalizePointDrag();
    } else if (controller.activeCornerCircleNode != null) {
      controller.activeCornerCircleNode = null;
      engine.finalizePointDrag(); 
      controller.notifyListeners();
    } else if (controller.isWidthSmoothing) {
      controller.isWidthSmoothing = false;
      controller.smoothOrigWidths.clear();
      engine.finalizePointDrag();
      controller.notifyListeners();
    } else if (controller.isSmoothing) {
      controller.isSmoothing = false;
      controller.smoothOrigPositions.clear();
      controller.smoothOrigHandles.clear();
      engine.finalizePointDrag();
      controller.notifyListeners();
    } else if (controller.activeFilletNode != null && controller.activeFilletSpline != null) {
      if (controller.activeFilletRadius > 0.1) {
        engine.applyFilletToNode(controller.activeFilletSpline!, controller.activeFilletNode!, controller.activeFilletRadius);
      }
      controller.activeFilletNode = null;
      controller.activeFilletSpline = null;
      controller.activeFilletRadius = 0.0;
      controller.notifyListeners();
    } else if (controller.activeWidthNode != null) { 
      controller.activeWidthNode = null;
      controller.isUnifiedWidthPull = false;
      controller.activeWidthSpline = null;
      engine.finalizePointDrag();
      controller.notifyListeners();
    } else if (controller.activeHandleNode != null) {
      controller.activeHandleNode = null;
      engine.finalizePointDrag();
      controller.notifyListeners();
    } else if (controller.isDraggingSelectionBox) {
      controller.isDraggingSelectionBox = false;
      controller.selectionBoxStart = null;
      controller.selectionBoxCurrent = null;
      controller.notifyListeners();
    } else if (controller.isPanningSelectedPoints) {
      controller.isPanningSelectedPoints = false;
      for (var p in controller.transformingPoints) p.isBeingDragged = false;
      engine.finalizePointDrag();
    } else if (controller.activeTensionNode != null) {
      controller.activeTensionNode = null;
      engine.finalizePointDrag(); 
    }
    controller.lastPanPosition = null;
    controller.dragStartLogicalPosition = null;
  }
  
  static void onPanCancel(CanvasController controller) {
    if (controller.isRotating || controller.isPanningShape) {
      controller.isRotating = false;
      controller.isPanningShape = false;
      controller.rotatingHandleNodes.clear();
      for (var p in controller.transformingPoints) p.isBeingDragged = false;
    } else if (controller.isStrictPanningSelection) {
      controller.isStrictPanningSelection = false;
      for (var p in controller.transformingPoints) p.isBeingDragged = false;
    } else if (controller.isDraggingSelectionBox) {
      controller.isDraggingSelectionBox = false;
      controller.selectionBoxStart = null;
      controller.selectionBoxCurrent = null;
      controller.notifyListeners();
    } else if (controller.isPanningSelectedPoints) {
      controller.isPanningSelectedPoints = false;
      for (var p in controller.transformingPoints) p.isBeingDragged = false;
    }
    controller.activeCornerCircleNode = null;
    controller.activeHandleNode = null;
    controller.activeWidthNode = null; 
    controller.isUnifiedWidthPull = false;
    controller.activeWidthSpline = null;
    controller.activeTensionNode = null;

    controller.isWidthSmoothing = false;
    controller.smoothOrigWidths.clear();

    controller.isSmoothing = false;
    controller.smoothOrigPositions.clear();
    controller.smoothOrigHandles.clear();
    
    controller.activeFilletNode = null;
    controller.activeFilletSpline = null;
    controller.activeFilletRadius = 0.0;

    controller.pendingSelectPress = null;
    controller.lastPanPosition = null;
    controller.dragStartLogicalPosition = null;
  }
}