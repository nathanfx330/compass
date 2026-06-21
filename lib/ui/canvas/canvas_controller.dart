// ./lib/ui/canvas/canvas_controller.dart

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

// --- Imports ---
import '../../ui/workspace/dialogs.dart';
import 'canvas_hit_tester.dart';

// Defines the current interaction mode for the canvas
enum CompassTool { select, addPoint, addLine, addCircle, addSpiral, addPen, addRect } 

class CanvasController extends ChangeNotifier {
  final CompassEngine engine;

  CanvasController(this.engine) {
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  // --- PUBLIC STATE FOR UI ---
  CompassTool currentTool = CompassTool.select;
  CompassPoint? shapeStartPoint; 
  
  Offset? hoverPosition;
  CompassPoint? hoveredPoint; 
  
  Set<CompassPoint> selectedPoints = {}; 
  bool isDraggingSelectionBox = false;
  Offset? selectionBoxStart;
  Offset? selectionBoxCurrent;
  
  CompassSplineNode? targetTensionNode; 
  CompassSplineNode? activeHandleNode;
  bool activeHandleIsOut = false;

  // --- NEW: Live Fillet State ---
  CompassSplineNode? activeFilletNode;
  CompassXSpline? activeFilletSpline;
  double activeFilletRadius = 0.0;

  // --- Q-hover "Add Resolution" preview state ---
  // When Q is held in select mode over a spline segment (and not over a point), we
  // preview a vertex at the segment's parametric center. A click commits it on press.
  // addVertexPreviewPos is the exact on-curve point (t=0.5 on the segment's cubic),
  // so it lands precisely where subdivideSplineSegment will place the new vertex.
  CompassXSpline? addVertexSpline;
  int addVertexSegmentIndex = -1;
  Offset? addVertexPreviewPos;

  Offset panOffset = Offset.zero;
  double canvasScale = 1.0; 
  bool isPanningCanvas = false;

  bool isRPressed = false;
  bool isShiftRPressed = false;
  bool isShiftPressed = false;
  bool isAPressed = false; 
  bool isFPressed = false; 
  bool isQPressed = false; 
  
  // --- NEW: Axis Locking State ---
  bool is1Pressed = false; 
  bool is2Pressed = false; 

  Offset? rotationPivotOffset; 

  // --- PRIVATE INTERNAL STATE ---
  Offset? _lastPanPosition; 
  Offset? _dragStartLogicalPosition; // --- NEW: Anchors the axis locks perfectly
  Set<CompassPoint> _initialSelectionBeforeBox = {};
  bool _isPanningSelectedPoints = false;

  // --- NEW: strict (no-propagation) move of just the highlighted multi-selection ---
  // Reuses _transformingPoints, but unlike _isPanningSelectedPoints it adds the delta
  // straight to each point's coords (no moveBy walk), so attached children are NOT
  // dragged along. This is the Shift+drag "move only them" path for a 2+ selection.
  bool _isStrictPanningSelection = false;

  // --- NEW: deferred press on a 2+ selection (hitPoint, wasShiftHeld) ---
  // onTapDown stashes any press that lands on the active multi-selection here instead
  // of mutating selection on pointer-down. A clean CLICK consumes it in onTap. (The
  // DRAG path no longer reads this -- onPanStart re-detects the group grab fresh,
  // because onTapCancel clears this stash on the tap->pan transition before onPanStart
  // runs. See onPanStart's group-drag block.)
  (CompassPoint?, bool)? _pendingSelectPress;
  
  CompassXSpline? _activeSpline;
  CompassSplineNode? _activeTensionNode; 

  bool _isRotating = false;
  bool _isPanningShape = false;
  
  Set<CompassPoint> _transformingPoints = {}; 
  final List<CompassSplineNode> _rotatingHandleNodes = [];
  final double _hitThreshold = 20.0; 

  // --- TOOL MANAGEMENT ---
  void setTool(CompassTool tool) {
    currentTool = tool;
    selectedPoints.clear(); 
    shapeStartPoint = null; 
    _activeSpline = null;
    _pendingSelectPress = null;
    _clearAddVertexHover();
    notifyListeners();
  }

  // --- KEYBOARD HANDLING ---
  bool _handleKeyEvent(KeyEvent event) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final isR = keys.contains(LogicalKeyboardKey.keyR);
    final isShift = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
    final isA = keys.contains(LogicalKeyboardKey.keyA);
    final isF = keys.contains(LogicalKeyboardKey.keyF); 
    final isQ = keys.contains(LogicalKeyboardKey.keyQ); 
    final is1 = keys.contains(LogicalKeyboardKey.digit1) || keys.contains(LogicalKeyboardKey.numpad1);
    final is2 = keys.contains(LogicalKeyboardKey.digit2) || keys.contains(LogicalKeyboardKey.numpad2);

    final isDelete = keys.contains(LogicalKeyboardKey.delete) || keys.contains(LogicalKeyboardKey.backspace);

    if (isDelete && selectedPoints.isNotEmpty && event is KeyDownEvent) {
       for (var p in selectedPoints.toList()) {
         engine.removePoint(p);
       }
       selectedPoints.clear();
       notifyListeners();
    }

    final bool shiftR = isR && isShift;
    final bool justR = isR && !isShift;
    final bool justShift = isShift && !isR && !isA && !isF; 

    if (isRPressed != justR || isShiftRPressed != shiftR || isShiftPressed != justShift || 
        isAPressed != isA || isFPressed != isF || isQPressed != isQ ||
        is1Pressed != is1 || is2Pressed != is2) {
      
      isRPressed = justR;
      isShiftRPressed = shiftR;
      isShiftPressed = justShift;
      isAPressed = isA; 
      isFPressed = isF; 
      isQPressed = isQ; 
      is1Pressed = is1; 
      is2Pressed = is2; 

      if (justR || shiftR) {
        _setupRotationState(hierarchy: shiftR);
      } else {
        rotationPivotOffset = null;
        _transformingPoints.clear();
        _isRotating = false; 
      }

      if (isA) {
        _setupTensionState();
      } else {
        targetTensionNode = null;
      }

      // If F is released while actively dragging a fillet, abort the fillet
      if (!isF && activeFilletNode != null) {
        activeFilletNode = null;
        activeFilletSpline = null;
        activeFilletRadius = 0.0;
      }

      // Refresh the Q-hover add-vertex preview against the new modifier state
      if (hoverPosition != null) {
        _updateAddVertexHover(hoverPosition!);
      } else {
        _clearAddVertexHover();
      }
      
      notifyListeners();
    }
    return false; 
  }

  // --- RIGID BODY & MATH LOGIC ---

  void _setupTensionState() {
    CompassPoint? explicitPoint = selectedPoints.isNotEmpty ? selectedPoints.first : hoveredPoint;
    if (explicitPoint != null) {
      for (var layer in engine.layers) {
        if (!layer.isVisible || layer.isLocked) continue; 
        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue;
          if (shape is CompassXSpline) {
            for (var node in shape.nodes) {
              if (node.point == explicitPoint) {
                targetTensionNode = node;
                return;
              }
            }
          }
        }
      }
    }
  }

  List<CompassPoint> _getPointsOfShape(CompassShape shape) {
    if (shape is CompassLine) return [shape.start, shape.end];
    if (shape is CompassCircle) return [shape.center, if (shape.radiusPoint != null) shape.radiusPoint!];
    if (shape is CompassSpiral) return [shape.center, shape.startPoint];
    if (shape is CompassRectangle) return [shape.p1, shape.p2];
    if (shape is CompassXSpline) {
      final points = shape.nodes.map((n) => n.point).toList();
      if (shape.anchorPoint != null) points.add(shape.anchorPoint!);
      return points;
    }
    return [];
  }

  Offset? _getShapeCentroid(CompassShape shape) {
    if (shape is CompassXSpline) {
      if (shape.anchorPoint != null) {
        return Offset(shape.anchorPoint!.x.value, shape.anchorPoint!.y.value);
      }
      if (shape.nodes.isNotEmpty) {
        double cx = 0, cy = 0;
        for (var n in shape.nodes) {
          cx += n.point.x.value;
          cy += n.point.y.value;
        }
        return Offset(cx / shape.nodes.length, cy / shape.nodes.length);
      }
      return null;
    } else if (shape is CompassCircle) {
      return Offset(shape.center.x.value, shape.center.y.value);
    } else if (shape is CompassSpiral) {
      return Offset(shape.center.x.value, shape.center.y.value);
    } else if (shape is CompassRectangle) {
      return Offset((shape.p1.x.value + shape.p2.x.value) / 2, (shape.p1.y.value + shape.p2.y.value) / 2);
    } else if (shape is CompassLine) {
      return Offset((shape.start.x.value + shape.end.x.value) / 2, (shape.start.y.value + shape.end.y.value) / 2);
    }
    return null;
  }

  Set<CompassPoint> _getRigidBody(CompassShape? shape, CompassPoint? explicitPoint, bool hierarchy) {
    Set<CompassPoint> rigidBody = {};
    
    if (shape != null) {
      rigidBody.addAll(_getPointsOfShape(shape));
    } else if (explicitPoint != null) {
      rigidBody.add(explicitPoint);
    }

    if (hierarchy) {
      Set<CompassShape> visitedShapes = shape != null ? {shape} : {};
      List<CompassPoint> queue = rigidBody.toList();

      while (queue.isNotEmpty) {
        CompassPoint p = queue.removeLast();

        for (var child in p.attachedPoints) {
          if (!rigidBody.contains(child)) {
            rigidBody.add(child);
            queue.add(child);
          }
        }

        for (var other in engine.points) {
          if (other == p) continue;
          if (other.attachedPoints.contains(p) && !rigidBody.contains(other)) {
            rigidBody.add(other);
            queue.add(other);
          }
        }

        for (var layer in engine.layers) {
          if (!layer.isVisible || layer.isLocked) continue; 
          for (var s in layer.shapes) {
            if (!s.isVisible || visitedShapes.contains(s)) continue;
            
            final shapePts = _getPointsOfShape(s);
            if (shapePts.contains(p)) {
              visitedShapes.add(s);
              for (var sp in shapePts) {
                if (!rigidBody.contains(sp)) {
                  rigidBody.add(sp);
                  queue.add(sp);
                }
              }
            }
          }
        }
      }
    }
    return rigidBody;
  }

  Set<CompassPoint> _expandForShapeCohesion(Set<CompassPoint> pts) {
    final expanded = Set<CompassPoint>.from(pts);
    for (var layer in engine.layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is CompassCircle && shape.radiusPoint != null) {
          if (expanded.contains(shape.center) || expanded.contains(shape.radiusPoint)) {
            expanded.add(shape.center);
            expanded.add(shape.radiusPoint!);
          }
        } else if (shape is CompassSpiral) {
          if (expanded.contains(shape.center) || expanded.contains(shape.startPoint)) {
            expanded.add(shape.center);
            expanded.add(shape.startPoint);
          }
        }
      }
    }
    return expanded;
  }

  // Centroid of an arbitrary point set -- the pivot for isolated multi-selection
  // rotation. Plain mean of member coords; matches how the shape centroid reads.
  Offset? _centroidOfPoints(Set<CompassPoint> pts) {
    if (pts.isEmpty) return null;
    double cx = 0, cy = 0;
    for (var p in pts) {
      cx += p.x.value;
      cy += p.y.value;
    }
    return Offset(cx / pts.length, cy / pts.length);
  }

  void _setupRotationState({required bool hierarchy}) {
    // --- NEW: a 2+ highlighted selection is its own rigid body. ---
    // Plain R: rotate ONLY the highlighted points about their own centroid -- fully
    // isolated, nothing else on the canvas moves. Shift+R: rotate those points plus
    // everything rigidly bound to them (attachment graph + shape cohesion), still
    // pivoting on the selection centroid, preserving the local-vs-hierarchy split.
    if (selectedPoints.length >= 2) {
      rotationPivotOffset = _centroidOfPoints(selectedPoints);
      if (hierarchy) {
        Set<CompassPoint> body = {};
        for (var p in selectedPoints) {
          body.addAll(_getRigidBody(null, p, true));
        }
        _transformingPoints = _expandForShapeCohesion(body);
      } else {
        _transformingPoints = Set<CompassPoint>.from(selectedPoints);
      }
      return;
    }

    CompassPoint? explicitPoint = selectedPoints.isNotEmpty ? selectedPoints.first : hoveredPoint;
    CompassShape? selShape = engine.selectedShape;

    Offset? pivotOffset;
    if (hierarchy) {
      if (selShape != null) {
        pivotOffset = _getShapeCentroid(selShape);
      } else if (explicitPoint != null) {
        pivotOffset = Offset(explicitPoint.x.value, explicitPoint.y.value);
      }
    } else {
      if (explicitPoint != null) {
        pivotOffset = Offset(explicitPoint.x.value, explicitPoint.y.value);
      } else if (selShape != null) {
        pivotOffset = _getShapeCentroid(selShape);
      }
    }

    rotationPivotOffset = pivotOffset;
    _transformingPoints = _expandForShapeCohesion(_getRigidBody(selShape, explicitPoint, hierarchy));
  }

  Offset _getLogicalPosition(Offset localPosition) {
    return (localPosition - panOffset) / canvasScale;
  }

  Offset? _handleDotPosition(CompassSplineNode node, bool isOut) {
    final handle = isOut ? node.handleOut : node.handleIn;
    if (handle == null) return null;
    final t = node.tension.value;
    return Offset(
      node.point.x.value + handle.dx * t,
      node.point.y.value + handle.dy * t,
    );
  }

  // --- NEW: bounding box of the current multi-selection (logical space) ---
  // Null unless 2+ points are selected. Used both to draw the box (renderer reads it)
  // and to decide whether an empty-space press lands "inside the group" -> group drag.
  Rect? get selectionBounds {
    if (selectedPoints.length < 2) return null;
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (var p in selectedPoints) {
      minX = min(minX, p.x.value);
      minY = min(minY, p.y.value);
      maxX = max(maxX, p.x.value);
      maxY = max(maxY, p.y.value);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  // True when a logical press should grab the whole multi-selection: either dead-on a
  // selected dot, or anywhere inside the selection's bounding box (padded a little so
  // a tight cluster is still grabbable). A press on a NON-selected dot is excluded by
  // the caller, so grabbing an unselected vertex inside the box still drags that dot.
  bool _isPressOnSelection(Offset logical) {
    if (selectedPoints.length < 2) return false;
    final scaledThreshold = _hitThreshold / canvasScale;
    for (var p in selectedPoints) {
      if ((Offset(p.x.value, p.y.value) - logical).distance <= scaledThreshold) {
        return true;
      }
    }
    final b = selectionBounds;
    if (b == null) return false;
    return b.inflate(scaledThreshold).contains(logical);
  }

  // --- Q-HOVER "ADD RESOLUTION" HELPERS ---
  void _updateAddVertexHover(Offset logical) {
    if (currentTool != CompassTool.select || !isQPressed || hoveredPoint != null) {
      _clearAddVertexHover();
      return;
    }
    final hit = _findNearestSplineSegment(logical);
    if (hit == null) {
      _clearAddVertexHover();
      return;
    }
    addVertexSpline = hit.$1;
    addVertexSegmentIndex = hit.$2;
    addVertexPreviewPos = hit.$3;
  }

  void _clearAddVertexHover() {
    addVertexSpline = null;
    addVertexSegmentIndex = -1;
    addVertexPreviewPos = null;
  }

  (CompassXSpline, int, Offset)? _findNearestSplineSegment(Offset logical) {
    final scaledThreshold = _hitThreshold / canvasScale;

    CompassXSpline? bestSpline;
    int bestSeg = -1;
    Offset? bestCenter;
    double bestDist = double.infinity;

    for (var layer in engine.layers) {
      if (!layer.isVisible || layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;
        if (shape is! CompassXSpline) continue;

        final n = shape.nodes.length;
        if (n < 2) continue;

        final controls = shape.getEvaluatedControls();
        final segCount = shape.isClosed ? n : n - 1;

        for (int i = 0; i < segCount; i++) {
          final p0 = Offset(shape.nodes[i].point.x.value, shape.nodes[i].point.y.value);
          final p3 = Offset(shape.nodes[(i + 1) % n].point.x.value, shape.nodes[(i + 1) % n].point.y.value);
          final p1 = p0 + controls[i].$1;
          final p2 = p3 + controls[(i + 1) % n].$2;

          const samples = 16;
          double segMinDist = double.infinity;
          for (int s = 0; s <= samples; s++) {
            final pt = _cubicAt(p0, p1, p2, p3, s / samples);
            final d = (pt - logical).distance;
            if (d < segMinDist) segMinDist = d;
          }

          if (segMinDist < bestDist && segMinDist <= scaledThreshold) {
            bestDist = segMinDist;
            bestSpline = shape;
            bestSeg = i;
            bestCenter = _cubicAt(p0, p1, p2, p3, 0.5);
          }
        }
      }
    }

    if (bestSpline == null || bestCenter == null) return null;
    return (bestSpline, bestSeg, bestCenter);
  }

  Offset _cubicAt(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final u = 1.0 - t;
    final a = u * u * u;
    final b = 3 * u * u * t;
    final c = 3 * u * t * t;
    final d = t * t * t;
    return Offset(
      a * p0.dx + b * p1.dx + c * p2.dx + d * p3.dx,
      a * p0.dy + b * p1.dy + c * p2.dy + d * p3.dy,
    );
  }

  // --- GESTURE ROUTING ---

  void startCanvasPan() {
    isPanningCanvas = true;
    notifyListeners();
  }

  void updateCanvasPan(Offset delta) {
    if (isPanningCanvas) {
      panOffset += delta;
      notifyListeners();
    }
  }

  void endCanvasPan() {
    if (isPanningCanvas) {
      isPanningCanvas = false;
      notifyListeners();
    }
  }

  void handleScroll(PointerScrollEvent event, BuildContext context) {
    final isRefUnlocked = engine.referenceLayer != null && !engine.referenceLayer!.isLocked;
    
    if (isRefUnlocked) {
      final double zoomDelta = event.scrollDelta.dy > 0 ? -0.1 : 0.1;
      engine.updateReferenceTransform(Offset.zero, zoomDelta, 0);
    } else {
      final RenderBox renderBox = context.findRenderObject() as RenderBox;
      final localPosition = renderBox.globalToLocal(event.position);
      final logicalPoint = _getLogicalPosition(localPosition);
      
      final double zoomFactor = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
      double newScale = canvasScale * zoomFactor;
      newScale = newScale.clamp(0.05, 50.0); 
      
      canvasScale = newScale;
      panOffset = localPosition - logicalPoint * canvasScale;
      notifyListeners();
    }
  }

  void onHover(PointerHoverEvent event, BuildContext context, bool showScaffolding) {
    if (!showScaffolding) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(event.position);
    final logicalPosition = _getLogicalPosition(localPosition);

    hoverPosition = logicalPosition;
    hoveredPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, _hitThreshold / canvasScale);

    _updateAddVertexHover(logicalPosition);
    
    if ((isRPressed || isShiftRPressed) && rotationPivotOffset == null && hoveredPoint != null) {
      _setupRotationState(hierarchy: isShiftRPressed);
    }

    if (isAPressed && targetTensionNode == null && hoveredPoint != null) {
      _setupTensionState();
    }
    
    notifyListeners();
  }

  void clearHover() {
    hoverPosition = null;
    hoveredPoint = null;
    _clearAddVertexHover();
    notifyListeners();
  }

  Future<void> onSecondaryTapDown(
    TapDownDetails details, 
    BuildContext context, 
    bool showScaffolding, 
    VoidCallback onToggleScaffolding,
    bool showHandles, // <--- NEW ARGUMENT
    VoidCallback onToggleHandles // <--- NEW ARGUMENT
  ) async {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = _getLogicalPosition(localPosition);

    if (currentTool == CompassTool.addPen && _activeSpline != null) {
      _activeSpline = null;
      currentTool = CompassTool.select;
      notifyListeners();
      return;
    }

    CompassShape? clickedShape;
    final scaledThreshold = _hitThreshold / canvasScale;

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
            if (dist <= scaledThreshold) {
              clickedShape = shape;
              break;
            }

          } else if (shape is CompassCircle) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final r = shape.radius.value;
            
            final distToCenter = sqrt(pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2));
            final distToCircumference = (distToCenter - r).abs();
            
            if (distToCircumference <= scaledThreshold || distToCenter <= r) {
              clickedShape = shape;
              break;
            }
          } else if (shape is CompassSpiral) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final sx = shape.startPoint.x.value;
            final sy = shape.startPoint.y.value;
            
            final initialR = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));
            final distToCenter = sqrt(pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2));
            
            if (distToCenter <= initialR * CompassSpiral.phi * 4) {
              clickedShape = shape;
              break;
            }
          } else if (shape is CompassRectangle) {
             if (shape.getPath().contains(logicalPosition)) {
                clickedShape = shape;
                break;
             }
          } else if (shape is CompassXSpline) {
             if (shape.getPath().contains(logicalPosition)) {
                clickedShape = shape;
                break;
             }
          }
        }
        if (clickedShape != null) break;
      }
    }

    final RelativeRect position = RelativeRect.fromLTRB(
      details.globalPosition.dx,
      details.globalPosition.dy,
      details.globalPosition.dx,
      details.globalPosition.dy,
    );

    if (clickedPoint != null) {
      CompassXSpline? parentSpline;
      CompassSplineNode? clickedNode;
      
      for (var layer in engine.layers) {
        if (layer.isLocked) continue; 
        for (var shape in layer.shapes) {
          if (shape is CompassXSpline) {
            for (var n in shape.nodes) {
              if (n.point == clickedPoint) {
                parentSpline = shape;
                clickedNode = n;
                break;
              }
            }
          }
          if (parentSpline != null) break;
        }
        if (parentSpline != null) break;
      }

      final List<PopupMenuEntry<String>> pointMenuItems = [];

      if (parentSpline != null) {
        pointMenuItems.add(PopupMenuItem(
          value: 'toggle_closed',
          child: Text(parentSpline.isClosed ? 'Open Spline' : 'Close Spline (Connect Last to First)'),
        ));
        
        if (clickedNode != null && (clickedNode.handleIn != null || clickedNode.handleOut != null)) {
          pointMenuItems.add(const PopupMenuItem(
            value: 'reset_handles',
            child: Text('Reset Handles (Make Fluid)'), // <--- REVERTED BACK
          ));
        } else {
          pointMenuItems.add(const PopupMenuItem(
            value: 'convert_to_bezier',
            child: Text('Convert to Bézier (Edit Handles)'),
          ));
        }

        if (clickedNode != null) {
          pointMenuItems.add(const PopupMenuItem(
            value: 'fillet_corner',
            child: Text('Fillet Corner Dialog...'),
          ));
        }
        
        pointMenuItems.add(const PopupMenuDivider());
      }

      pointMenuItems.add(const PopupMenuItem(
        value: 'start_spline',
        child: Text('Start X-Spline from here'),
      ));
      pointMenuItems.add(const PopupMenuItem(
        value: 'start_circle',
        child: Text('Start Circle from here'),
      ));
      pointMenuItems.add(const PopupMenuDivider());

      pointMenuItems.add(const PopupMenuItem(
        value: 'delete_point', 
        child: Text('Delete Point (and dependent shapes)', style: TextStyle(color: Colors.red)),
      ));

      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: pointMenuItems,
      );

      if (selectedAction == 'delete_point') {
        engine.removePoint(clickedPoint);
        if (selectedPoints.contains(clickedPoint)) {
          selectedPoints.remove(clickedPoint);
          notifyListeners();
        }
      } else if (selectedAction == 'reset_handles') {
        engine.resetPointHandles(clickedPoint);
      } else if (selectedAction == 'convert_to_bezier') {
        engine.convertPointToBezier(clickedPoint);
      } else if (selectedAction == 'fillet_corner' && parentSpline != null && clickedNode != null) {
        CompassDialogs.showFilletDialog(context, engine, parentSpline, clickedNode);
      } else if (selectedAction == 'toggle_closed' && parentSpline != null) {
        engine.toggleSplineClosed(parentSpline);
      } else if (selectedAction == 'start_spline') {
        currentTool = CompassTool.addPen;
        selectedPoints.clear(); 
        shapeStartPoint = null;
        
        _activeSpline = CompassXSpline(isClosed: false);
        final node = CompassSplineNode(point: clickedPoint, tension: 1.0);
        node.tension.addListener(engine.notifyListeners);
        _activeSpline!.addNode(node);
        engine.addShape(_activeSpline!);
        notifyListeners();
      } else if (selectedAction == 'start_circle') {
        currentTool = CompassTool.addCircle;
        shapeStartPoint = clickedPoint;
        selectedPoints.clear();
        _activeSpline = null;
        notifyListeners();
      }
    } else if (clickedShape != null) {
      engine.selectShape(clickedShape);

      final List<PopupMenuEntry<String>> menuItems = [
        const PopupMenuItem(value: 'add_point', child: Text('Add Point to Shape')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'add', child: Text('Union (Add)')),
        const PopupMenuItem(value: 'subtract', child: Text('Subtract')),
        const PopupMenuItem(value: 'intersect', child: Text('Intersect')),
        const PopupMenuItem(value: 'none', child: Text('None (Construction)')), 
        const PopupMenuDivider(),
      ];

      if (clickedShape is CompassXSpline) {
        menuItems.insert(6, PopupMenuItem(
          value: 'toggle_closed', 
          child: Text(clickedShape.isClosed ? 'Open Spline' : 'Close Spline (Connect Last to First)'),
        ));
      } else if (clickedShape is CompassCircle || clickedShape is CompassRectangle) {
        menuItems.insert(6, const PopupMenuItem(
          value: 'convert_to_spline',
          child: Text('Convert to X-Spline'),
        ));
      }

      menuItems.add(const PopupMenuItem(
        value: 'delete', 
        child: Text('Delete Shape', style: TextStyle(color: Colors.red)),
      ));

      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: menuItems,
      );

      if (selectedAction != null) {
        if (selectedAction == 'delete') {
          engine.removeShape(clickedShape);
        } else if (selectedAction == 'toggle_closed' && clickedShape is CompassXSpline) {
          engine.toggleSplineClosed(clickedShape);
        } else if (selectedAction == 'convert_to_spline' && clickedShape is CompassCircle) {
          engine.convertCircleToSpline(clickedShape);
        } else if (selectedAction == 'convert_to_spline' && clickedShape is CompassRectangle) { 
          engine.convertRectangleToSpline(clickedShape);
        } else if (selectedAction == 'add_point') {
          final newPoint = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          engine.addPoint(newPoint);

          if (clickedShape is CompassLine) {
            clickedShape.start.attach(newPoint); 
            engine.addPointOnLine(newPoint, clickedShape);
          } else if (clickedShape is CompassCircle) {
            clickedShape.center.attach(newPoint); 
            engine.addPointOnCircle(newPoint, clickedShape);
          } else if (clickedShape is CompassSpiral) {
            clickedShape.center.attach(newPoint); 
            engine.addPointOnSpiral(newPoint, clickedShape);
          } else if (clickedShape is CompassRectangle) {
            engine.convertRectangleToSpline(clickedShape);
            
            CompassXSpline? newSpline;
            for (var layer in engine.layers) {
              for (var s in layer.shapes) {
                if (s is CompassXSpline && s.anchorPoint != null) {
                  final cx = (clickedShape.p1.x.value + clickedShape.p2.x.value) / 2;
                  final cy = (clickedShape.p1.y.value + clickedShape.p2.y.value) / 2;
                  if ((s.anchorPoint!.x.value - cx).abs() < 0.1 && (s.anchorPoint!.y.value - cy).abs() < 0.1) {
                    newSpline = s;
                    break;
                  }
                }
              }
              if (newSpline != null) break;
            }
            if (newSpline != null) {
              engine.insertPointIntoSpline(newPoint, newSpline);
            }
          } else if (clickedShape is CompassXSpline) {
            engine.insertPointIntoSpline(newPoint, clickedShape);
          }
        } else {
          final op = CompassBooleanOp.values.firstWhere((e) => e.name == selectedAction);
          engine.changeShapeOperation(clickedShape, op);
        }
      }
    } else {
      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: [
          PopupMenuItem(
            value: 'toggle_scaffolding', 
            child: Text(showScaffolding ? 'Hide Scaffolding (Clean View)' : 'Show Scaffolding'),
          ), 
          // <--- NEW: Right click empty canvas to toggle handles
          PopupMenuItem(
            value: 'toggle_handles', 
            child: Text(showHandles ? 'Hide Handles' : 'Show Handles'),
          ), 
        ],
      );

      if (selectedAction == 'toggle_scaffolding') {
        onToggleScaffolding();
      } else if (selectedAction == 'toggle_handles') {
        onToggleHandles();
      }
    }
  }

  void onTapDown(TapDownDetails details, BuildContext context, bool showScaffolding) {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = _getLogicalPosition(localPosition);

    final bool isShiftPressed = HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.shiftRight);

    if (addVertexSpline != null && addVertexSegmentIndex >= 0) {
      final spline = addVertexSpline!;
      final segIndex = addVertexSegmentIndex;

      final created = engine.subdivideSplineSegment(spline, segIndex, t: 0.5);
      if (created != null) {
        engine.selectShape(spline);
        selectedPoints = {created};
      }

      if (hoverPosition != null) {
        _updateAddVertexHover(hoverPosition!);
      } else {
        _clearAddVertexHover();
      }

      notifyListeners();
      return;
    }

    if (currentTool == CompassTool.select) {
      CompassPoint? hitPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, _hitThreshold / canvasScale);

      // --- NEW: defer presses that belong to an active 2+ selection. ---
      // If a multi-selection is live and this press lands on it -- on a member dot, or
      // anywhere inside the box but NOT on some OTHER (unselected) dot -- we do NOT
      // mutate selection now. We stash it so a clean CLICK can be resolved in onTap
      // (collapse / toggle). A DRAG is handled separately: onPanStart re-detects the
      // group grab fresh, because onTapCancel will have cleared this stash before
      // onPanStart runs (arena rejects tap -> onTapCancel -> then accepts pan).
      final pressOnSelectionMember = hitPoint != null && selectedPoints.contains(hitPoint);
      final pressInsideBox = hitPoint == null && _isPressOnSelection(logicalPosition);
      if (selectedPoints.length >= 2 && (pressOnSelectionMember || pressInsideBox)) {
        _pendingSelectPress = (hitPoint, isShiftPressed);
        return;
      }

      if (hitPoint != null) {
        if (isShiftPressed) {
          if (selectedPoints.contains(hitPoint)) {
            selectedPoints.remove(hitPoint);
          } else {
            selectedPoints.add(hitPoint); 
          }
        } else {
          selectedPoints = {hitPoint}; 
        }
        notifyListeners();

        CompassShape? ownerShape;
        for (var layer in engine.layers.reversed) {
          if (!layer.isVisible || layer.isLocked) continue; 
          for (var shape in layer.shapes.reversed) {
            if (!shape.isVisible) continue;
            if (shape is CompassXSpline && (shape.nodes.any((n) => n.point == hitPoint) || shape.anchorPoint == hitPoint)) {
              ownerShape = shape; break;
            } else if (shape is CompassCircle && (shape.center == hitPoint || shape.radiusPoint == hitPoint)) {
              ownerShape = shape; break;
            } else if (shape is CompassRectangle && (shape.p1 == hitPoint || shape.p2 == hitPoint)) { 
              ownerShape = shape; break;
            } else if (shape is CompassLine && (shape.start == hitPoint || shape.end == hitPoint)) {
              ownerShape = shape; break;
            } else if (shape is CompassSpiral && (shape.center == hitPoint || shape.startPoint == hitPoint)) {
              ownerShape = shape; break;
            }
          }
          if (ownerShape != null) break;
        }

        if (ownerShape != null) {
          engine.selectShape(ownerShape);
        } else {
          engine.selectShape(null);
        }
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
            final r = shape.radius.value;
            final dist2 = pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2);
            if (dist2 <= r * r) {
              hitShape = shape;
              break;
            }
          } else if (shape is CompassSpiral) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final sx = shape.startPoint.x.value;
            final sy = shape.startPoint.y.value;
            final initialR = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));
            final distToCenter = sqrt(pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2));
            if (distToCenter <= initialR * CompassSpiral.phi * 4) {
              hitShape = shape;
              break;
            }
          } else if (shape is CompassRectangle) { 
             if (shape.getPath().contains(logicalPosition)) {
                hitShape = shape;
                break;
             }
          } else if (shape is CompassXSpline) {
             if (shape.getPath().contains(logicalPosition)) {
                hitShape = shape;
                break;
             }
          }
        }
        if (hitShape != null) break;
      }

      if (hitShape == null && hoveredPoint == null) {
        engine.selectShape(null);
        selectedPoints.clear(); 
        notifyListeners();
      } else if (hitShape != null) {
        engine.selectShape(hitShape);
        selectedPoints.clear(); 
        notifyListeners();
      }
    }
    else if (currentTool == CompassTool.addPoint) {
      CompassShape? closestShape;
      double minDistance = _hitThreshold / canvasScale;

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
            
            if (dist < minDistance) {
              minDistance = dist;
              closestShape = shape;
            }
          } else if (shape is CompassCircle) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final r = shape.radius.value;
            final tap = Offset(logicalPosition.dx, logicalPosition.dy);

            final distToCenter = sqrt((tap.dx - cx) * (tap.dx - cx) + (tap.dy - cy) * (tap.dy - cy));
            final distToCircumference = (distToCenter - r).abs();

            if (distToCircumference < minDistance) {
              minDistance = distToCircumference;
              closestShape = shape;
            }
          } else if (shape is CompassSpiral) {
            final cx = shape.center.x.value;
            final cy = shape.center.y.value;
            final sx = shape.startPoint.x.value;
            final sy = shape.startPoint.y.value;
            final initialR = sqrt(pow(sx - cx, 2) + pow(sy - cy, 2));
            final distToCenter = sqrt(pow(logicalPosition.dx - cx, 2) + pow(logicalPosition.dy - cy, 2));
            if (distToCenter <= initialR * CompassSpiral.phi * 4) {
              minDistance = 0; 
              closestShape = shape;
            }
          } else if (shape is CompassRectangle) {
            final p1 = Offset(shape.p1.x.value, shape.p1.y.value);
            final p2 = Offset(shape.p2.x.value, shape.p2.y.value);
            final tap = Offset(logicalPosition.dx, logicalPosition.dy);
            
            final corners = [
              p1,
              Offset(p2.dx, p1.dy),
              p2,
              Offset(p1.dx, p2.dy),
            ];
            
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
              if (dist < minDistToRect) {
                minDistToRect = dist;
              }
            }
            if (minDistToRect < minDistance) {
              minDistance = minDistToRect;
              closestShape = shape;
            }
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
              
              if (dist < minDistToSpline) {
                minDistToSpline = dist;
              }
            }
            if (minDistToSpline < minDistance) {
              minDistance = minDistToSpline;
              closestShape = shape;
            }
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
                newSpline = s;
                break;
              }
            }
          }
          if (newSpline != null) break;
        }
        if (newSpline != null) {
          engine.insertPointIntoSpline(newPoint, newSpline);
        }
      } else if (closestShape is CompassXSpline) {
        engine.insertPointIntoSpline(newPoint, closestShape);
      }
    } 
    else if (currentTool == CompassTool.addPen) {
      CompassPoint tappedPoint;
      
      if (hoveredPoint != null) {
        tappedPoint = hoveredPoint!;
      } else {
        tappedPoint = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
        engine.addPoint(tappedPoint);
      }

      if (_activeSpline == null) {
        _activeSpline = CompassXSpline(isClosed: false);
        final node = CompassSplineNode(point: tappedPoint, tension: 1.0); 
        node.tension.addListener(engine.notifyListeners);
        _activeSpline!.addNode(node);
        engine.addShape(_activeSpline!);
      } else {
        if (_activeSpline!.nodes.isNotEmpty && _activeSpline!.nodes.first.point == tappedPoint) {
          engine.toggleSplineClosed(_activeSpline!);
          _activeSpline = null;
          currentTool = CompassTool.select;
          notifyListeners();
        } else {
          final node = CompassSplineNode(point: tappedPoint, tension: 1.0);
          node.tension.addListener(engine.notifyListeners);
          _activeSpline!.addNode(node);
          engine.notifyListeners();
        }
      }
    }
    else if (currentTool == CompassTool.addLine || currentTool == CompassTool.addCircle || currentTool == CompassTool.addSpiral || currentTool == CompassTool.addRect) {
      
      if (isShiftPressed) {
        final quickOffset = 100 / canvasScale; 
        if (currentTool == CompassTool.addLine) {
          final p1 = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final p2 = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy + quickOffset);
          engine.addPoint(p1);
          engine.addPoint(p2);
          engine.addShape(CompassLine(start: p1, end: p2));
        } else if (currentTool == CompassTool.addCircle) {
          final center = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final radiusPoint = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy);
          engine.addPoint(center);
          engine.addPoint(radiusPoint);
          
          center.attach(radiusPoint); 

          final circle = CompassCircle(center: center, radiusPoint: radiusPoint, radius: 0);
          DistanceRadiusConstraint(
            p1: center,
            p2: radiusPoint,
            targetRadius: circle.radius,
          );
          engine.addShape(circle);
        } else if (currentTool == CompassTool.addSpiral) {
          final center = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final startPoint = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy);
          engine.addPoint(center);
          engine.addPoint(startPoint);
          
          center.attach(startPoint);

          final spiral = CompassSpiral(center: center, startPoint: startPoint);
          engine.addShape(spiral);
        } else if (currentTool == CompassTool.addRect) {
          final p1 = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final p2 = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy + quickOffset);
          engine.addPoint(p1);
          engine.addPoint(p2);
          
          final rect = CompassRectangle(p1: p1, p2: p2, isSquare: true);
          SquareConstraint(rect: rect);
          engine.addShape(rect);
        }
        
        shapeStartPoint = null;
        notifyListeners();
        return; 
      }

      CompassPoint? tappedPoint;
      
      if (hoveredPoint != null) {
        tappedPoint = hoveredPoint;
      } else {
        tappedPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, _hitThreshold / canvasScale);
      }

      if (tappedPoint == null) {
        tappedPoint = CompassPoint(
          x: logicalPosition.dx,
          y: logicalPosition.dy,
        );
        engine.addPoint(tappedPoint);
      }

      if (shapeStartPoint == null) {
        shapeStartPoint = tappedPoint;
        notifyListeners();
      } else {
        if (shapeStartPoint != tappedPoint) {
          if (currentTool == CompassTool.addLine) {
            engine.addShape(CompassLine(
              start: shapeStartPoint!,
              end: tappedPoint!,
            ));
          } else if (currentTool == CompassTool.addCircle) {
            final circle = CompassCircle(center: shapeStartPoint!, radiusPoint: tappedPoint!, radius: 0);
            shapeStartPoint!.attach(tappedPoint!);

            DistanceRadiusConstraint(
              p1: shapeStartPoint!,
              p2: tappedPoint!,
              targetRadius: circle.radius,
            );
            
            engine.addShape(circle);
          } else if (currentTool == CompassTool.addSpiral) {
            final spiral = CompassSpiral(center: shapeStartPoint!, startPoint: tappedPoint!);
            shapeStartPoint!.attach(tappedPoint!);
            engine.addShape(spiral);
          } else if (currentTool == CompassTool.addRect) { 
            final rect = CompassRectangle(
              p1: shapeStartPoint!,
              p2: tappedPoint!,
            );
            SquareConstraint(rect: rect); 
            engine.addShape(rect);
          }
        }
        shapeStartPoint = null;
        notifyListeners();
      }
    }
  }

  // --- NEW: resolve a clean click (no drag) on a 2+ selection. ---
  // Wired to GestureDetector.onTap in compass_canvas.dart. Fires only when a press
  // did NOT become a pan, so by here we know the user clicked, not dragged. This is
  // the half of the tap-vs-drag fix that lets a click still collapse/toggle the
  // group while a drag (handled in onPanStart) moves it. Consumes _pendingSelectPress.
  void onTap() {
    final pending = _pendingSelectPress;
    _pendingSelectPress = null;
    if (pending == null) return;

    final (hitPoint, wasShift) = pending;

    if (hitPoint != null) {
      if (wasShift) {
        // Shift-click a member: toggle it out of the group.
        if (selectedPoints.contains(hitPoint)) {
          selectedPoints.remove(hitPoint);
        } else {
          selectedPoints.add(hitPoint);
        }
      } else {
        // Plain click a member: collapse the whole group down to just that point,
        // and select its owning shape (mirrors single-point click behavior).
        selectedPoints = {hitPoint};

        CompassShape? ownerShape;
        for (var layer in engine.layers.reversed) {
          if (!layer.isVisible || layer.isLocked) continue;
          for (var shape in layer.shapes.reversed) {
            if (!shape.isVisible) continue;
            if (shape is CompassXSpline && (shape.nodes.any((n) => n.point == hitPoint) || shape.anchorPoint == hitPoint)) {
              ownerShape = shape; break;
            } else if (shape is CompassCircle && (shape.center == hitPoint || shape.radiusPoint == hitPoint)) {
              ownerShape = shape; break;
            } else if (shape is CompassRectangle && (shape.p1 == hitPoint || shape.p2 == hitPoint)) {
              ownerShape = shape; break;
            } else if (shape is CompassLine && (shape.start == hitPoint || shape.end == hitPoint)) {
              ownerShape = shape; break;
            } else if (shape is CompassSpiral && (shape.center == hitPoint || shape.startPoint == hitPoint)) {
              ownerShape = shape; break;
            }
          }
          if (ownerShape != null) break;
        }
        engine.selectShape(ownerShape);
      }
    } else {
      // Plain click on empty space inside the box: clear the group (unless Shift,
      // which is a no-op so a mis-click doesn't nuke a careful selection).
      if (!wasShift) {
        selectedPoints.clear();
        engine.selectShape(null);
      }
    }
    notifyListeners();
  }

  // --- tap aborted without becoming a pan -- drop any deferred selection press so
  // it can't leak into the next gesture. This fires on the tap->pan transition too
  // (arena rejects tap before accepting pan); that's fine, because the DRAG path in
  // onPanStart re-detects the group grab fresh and does not rely on this stash. ---
  void onTapCancel() {
    _pendingSelectPress = null;
  }

  void onPanStart(
    DragStartDetails details, 
    BuildContext context, 
    bool showScaffolding,
    bool showHandles // <--- NEW ARGUMENT
  ) {
    if (currentTool != CompassTool.select) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = _getLogicalPosition(localPosition);

    _lastPanPosition = logicalPosition;
    _dragStartLogicalPosition = logicalPosition; // <-- NEW: Anchors the 1/2 axis lock orthogonal lines
    hoverPosition = logicalPosition; 
    notifyListeners();

    if ((isRPressed || isShiftRPressed) && rotationPivotOffset != null) {
      _isRotating = true;
      for (var p in _transformingPoints) p.isBeingDragged = true;

      _rotatingHandleNodes.clear();
      for (var layer in engine.layers) {
        for (var shape in layer.shapes) {
          if (shape is CompassXSpline) {
            for (var node in shape.nodes) {
              if ((node.handleIn != null || node.handleOut != null) && _transformingPoints.contains(node.point)) {
                _rotatingHandleNodes.add(node);
              }
            }
          }
        }
      }
      return; 
    }

    // --- Group drag of a 2+ highlighted selection. ---
    // Detected FRESH here rather than via the _pendingSelectPress stash, because the
    // stash is cleared by onTapCancel on the tap->pan transition (the arena rejects
    // the tap recognizer -- firing onTapCancel -- BEFORE it accepts the pan and fires
    // onPanStart), so by the time we reach here the stash is already gone. Re-deriving
    // the hit and reading Shift LIVE also makes the plain-vs-strict choice independent
    // of press/key ordering, which is what fixes "held Shift still moved the whole
    // rigid body."
    //
    // A press counts as a group grab when it lands on a SELECTED member dot, or inside
    // the selection box but not on ANY dot -- mirroring the onTapDown defer test, so
    // grabbing an UNSELECTED vertex inside the box still drags just that one dot.
    // Plain = moveBy (attached children ride along). Shift = raw coordinate add on
    // ONLY the highlighted points, no propagation (the "move only the lasso" case).
    // Guarded so it never steals R / Shift+R / A / F.
    if (selectedPoints.length >= 2 &&
        !isRPressed && !isShiftRPressed && !isAPressed && !isFPressed) {
      final hp = CanvasHitTester.hitTestPoint(engine, logicalPosition, _hitThreshold / canvasScale);
      final onMember = hp != null && selectedPoints.contains(hp);
      final inBoxNoDot = hp == null && _isPressOnSelection(logicalPosition);

      if (onMember || inBoxNoDot) {
        _pendingSelectPress = null; // the drag owns this gesture; no click to resolve

        final liveShift = HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.shiftLeft) ||
            HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.shiftRight);

        _transformingPoints = Set<CompassPoint>.from(selectedPoints);
        for (var p in _transformingPoints) p.isBeingDragged = true;

        if (liveShift) {
          _isStrictPanningSelection = true;
        } else {
          _isPanningSelectedPoints = true;
        }
        return;
      }
    }

    if (isShiftPressed && !isRPressed && !isShiftRPressed && !isAPressed) {
      if (hoveredPoint != null || engine.selectedShape != null) {
        _transformingPoints = _getRigidBody(engine.selectedShape, hoveredPoint, true);
        if (_transformingPoints.isNotEmpty) {
          _isPanningShape = true;
          for (var p in _transformingPoints) p.isBeingDragged = true;
          return;
        }
      }
    }

    if (isAPressed && targetTensionNode != null) {
      _activeTensionNode = targetTensionNode;
      return;
    }

    if (isFPressed && selectedPoints.isNotEmpty) {
      final targetPoint = selectedPoints.first;
      for (var layer in engine.layers) {
        if (!layer.isVisible || layer.isLocked) continue; 
        for (var shape in layer.shapes) {
          if (shape is CompassXSpline) {
            for (int i = 0; i < shape.nodes.length; i++) {
              final node = shape.nodes[i];
              if (node.point == targetPoint) {
                if (!shape.isClosed && (i == 0 || i == shape.nodes.length - 1)) continue;
                
                activeFilletNode = node;
                activeFilletSpline = shape;
                activeFilletRadius = 0.0;
                notifyListeners();
                return;
              }
            }
          }
        }
      }
    }

    final selForHandles = engine.selectedShape;
    if (selForHandles is CompassXSpline &&
        showScaffolding && showHandles && // <--- NEW CHECK
        !isShiftPressed && !isRPressed && !isShiftRPressed && !isAPressed && !isFPressed) {
      final handleThreshold = 24.0 / canvasScale;
      for (var node in selForHandles.nodes) {
        if (node.handleIn == null && node.handleOut == null) continue;

        final outDot = _handleDotPosition(node, true);
        if (outDot != null && (logicalPosition - outDot).distance < handleThreshold) {
          engine.commitNodeToBezierEdit(node);
          activeHandleNode = node;
          activeHandleIsOut = true;
          notifyListeners();
          return;
        }

        final inDot = _handleDotPosition(node, false);
        if (inDot != null && (logicalPosition - inDot).distance < handleThreshold) {
          engine.commitNodeToBezierEdit(node);
          activeHandleNode = node;
          activeHandleIsOut = false;
          notifyListeners();
          return;
        }
      }
    }

    final selectedShape = engine.selectedShape;
    if (selectedShape is CompassXSpline && showScaffolding) {
       for (var node in selectedShape.nodes) {
          final pt = Offset(node.point.x.value, node.point.y.value);
          final handlePt = pt + const Offset(20, -30); 
          final dist = (logicalPosition - handlePt).distance;
          
          if (dist < (15.0 / canvasScale)) {
            _activeTensionNode = node;
            return; 
          }
       }
    }

    CompassPoint? hitPoint = CanvasHitTester.hitTestPoint(engine, logicalPosition, _hitThreshold / canvasScale);

    if (hitPoint != null) {
      if (!selectedPoints.contains(hitPoint)) {
        if (!isShiftPressed) selectedPoints.clear();
        selectedPoints.add(hitPoint); 
      }
      notifyListeners();
      
      _isPanningSelectedPoints = true;
      _transformingPoints = Set.from(selectedPoints);
      for (var p in _transformingPoints) p.isBeingDragged = true;
    } else {
      isDraggingSelectionBox = true;
      selectionBoxStart = logicalPosition;
      selectionBoxCurrent = logicalPosition;
      if (!isShiftPressed) selectedPoints.clear();
      _initialSelectionBeforeBox = Set.from(selectedPoints);
      notifyListeners();
    }
  }

  void onPanUpdate(DragUpdateDetails details, BuildContext context, bool showScaffolding) {
    if (currentTool != CompassTool.select || _lastPanPosition == null) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    Offset logicalPosition = _getLogicalPosition(localPosition);

    // --- NEW: Axis Locking Logic (Snaps to original drag start coordinate) ---
    if (_dragStartLogicalPosition != null) {
      if (is1Pressed) {
        logicalPosition = Offset(logicalPosition.dx, _dragStartLogicalPosition!.dy);
      }
      if (is2Pressed) {
        logicalPosition = Offset(_dragStartLogicalPosition!.dx, logicalPosition.dy);
      }
    }

    hoverPosition = logicalPosition; 
    notifyListeners();

    final dx = logicalPosition.dx - _lastPanPosition!.dx;
    final dy = logicalPosition.dy - _lastPanPosition!.dy;

    if (_isRotating && rotationPivotOffset != null) {
      final pivot = rotationPivotOffset!;
      final startAngle = atan2(_lastPanPosition!.dy - pivot.dy, _lastPanPosition!.dx - pivot.dx);
      final currentAngle = atan2(logicalPosition.dy - pivot.dy, logicalPosition.dx - pivot.dx);
      final deltaAngle = currentAngle - startAngle;

      final cosA = cos(deltaAngle);
      final sinA = sin(deltaAngle);

      for (var child in _transformingPoints) {
        final pointDx = child.x.value - pivot.dx;
        final pointDy = child.y.value - pivot.dy;
        
        child.x.value = pivot.dx + (pointDx * cosA - pointDy * sinA);
        child.y.value = pivot.dy + (pointDx * sinA + pointDy * cosA);
      }

      for (var node in _rotatingHandleNodes) {
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
      
      _lastPanPosition = logicalPosition;
      return;
    }

    if (_isPanningShape) {
      for (var p in _transformingPoints) {
        p.x.value += dx;
        p.y.value += dy;
      }
      _lastPanPosition = logicalPosition;
      return;
    }

    // --- NEW: strict multi-selection move (Shift+drag) -- no propagation. ---
    if (_isStrictPanningSelection) {
      for (var p in _transformingPoints) {
        p.x.value += dx;
        p.y.value += dy;
      }
      _lastPanPosition = logicalPosition;
      return;
    }

    if (activeFilletNode != null && activeFilletSpline != null) {
      activeFilletRadius += dx;
      if (activeFilletRadius < 0.0) activeFilletRadius = 0.0;
      _lastPanPosition = logicalPosition;
      return;
    }

    if (activeHandleNode != null) {
      final node = activeHandleNode!;
      final newHandle = Offset(
        logicalPosition.dx - node.point.x.value,
        logicalPosition.dy - node.point.y.value,
      );
      engine.updateNodeHandle(node, activeHandleIsOut, newHandle);
      _lastPanPosition = logicalPosition;
      return;
    }

    if (isDraggingSelectionBox && selectionBoxStart != null) {
       selectionBoxCurrent = logicalPosition;
       final rect = Rect.fromPoints(selectionBoxStart!, selectionBoxCurrent!);
       final newSelection = Set<CompassPoint>.from(_initialSelectionBeforeBox);
       
       for(var p in engine.points) {
         if (CanvasHitTester.isPointLocked(engine, p)) continue;
         if (rect.contains(Offset(p.x.value, p.y.value))) {
           newSelection.add(p);
         }
       }
       
       selectedPoints = newSelection;
       notifyListeners();
       _lastPanPosition = logicalPosition;
       return;
    }

    if (_activeTensionNode != null) {
       if (isAPressed) {
         final nodePos = Offset(_activeTensionNode!.point.x.value, _activeTensionNode!.point.y.value);
         final dist = (logicalPosition - nodePos).distance;
         
         double newTension = dist * 0.01;
         
         _activeTensionNode!.tension.value = max(0.0, newTension);
       } else {
         final physicalDy = details.delta.dy; 
         final tensionDelta = -physicalDy * 0.005; 
         double newTension = _activeTensionNode!.tension.value + tensionDelta;
         
         _activeTensionNode!.tension.value = max(0.0, newTension);
       }
    } 
    else if (_isPanningSelectedPoints) {
      final visited = <CompassPoint>{};
      for (var p in _transformingPoints) {
        p.moveBy(dx, dy, visited: visited);
      }
    } 
    else if (engine.referenceLayer != null && !engine.referenceLayer!.isLocked) {
      engine.updateReferenceTransform(Offset(dx * canvasScale, dy * canvasScale), 0, 0);
    }

    _lastPanPosition = logicalPosition;
  }

  void onPanEnd(DragEndDetails details) {
    if (_isRotating || _isPanningShape) {
      _isRotating = false;
      _isPanningShape = false;
      _rotatingHandleNodes.clear();
      for (var p in _transformingPoints) p.isBeingDragged = false;
      engine.finalizePointDrag(); 
    } else if (_isStrictPanningSelection) {
      _isStrictPanningSelection = false;
      for (var p in _transformingPoints) p.isBeingDragged = false;
      engine.finalizePointDrag();
    } else if (activeFilletNode != null && activeFilletSpline != null) {
      if (activeFilletRadius > 0.1) {
        engine.applyFilletToNode(activeFilletSpline!, activeFilletNode!, activeFilletRadius);
      }
      activeFilletNode = null;
      activeFilletSpline = null;
      activeFilletRadius = 0.0;
      notifyListeners();
    } else if (activeHandleNode != null) {
      activeHandleNode = null;
      engine.finalizePointDrag();
      notifyListeners();
    } else if (isDraggingSelectionBox) {
      isDraggingSelectionBox = false;
      selectionBoxStart = null;
      selectionBoxCurrent = null;
      notifyListeners();
    } else if (_isPanningSelectedPoints) {
      _isPanningSelectedPoints = false;
      for (var p in _transformingPoints) p.isBeingDragged = false;
      engine.finalizePointDrag();
    } else if (_activeTensionNode != null) {
      _activeTensionNode = null;
      engine.finalizePointDrag(); 
    }
    _lastPanPosition = null;
    _dragStartLogicalPosition = null;
  }
  
  void onPanCancel() {
    if (_isRotating || _isPanningShape) {
      _isRotating = false;
      _isPanningShape = false;
      _rotatingHandleNodes.clear();
      for (var p in _transformingPoints) p.isBeingDragged = false;
    } else if (_isStrictPanningSelection) {
      _isStrictPanningSelection = false;
      for (var p in _transformingPoints) p.isBeingDragged = false;
    } else if (isDraggingSelectionBox) {
      isDraggingSelectionBox = false;
      selectionBoxStart = null;
      selectionBoxCurrent = null;
      notifyListeners();
    } else if (_isPanningSelectedPoints) {
      _isPanningSelectedPoints = false;
      for (var p in _transformingPoints) p.isBeingDragged = false;
    }
    activeHandleNode = null;
    _activeTensionNode = null;
    
    activeFilletNode = null;
    activeFilletSpline = null;
    activeFilletRadius = 0.0;

    _pendingSelectPress = null;
    _lastPanPosition = null;
    _dragStartLogicalPosition = null;
  }
}