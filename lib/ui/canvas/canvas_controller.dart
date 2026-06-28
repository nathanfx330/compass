// /lib/ui/canvas/canvas_controller.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:flutter/gestures.dart'; 

import '../../engine.dart';

import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/mesh.dart'; // <--- NEW: gradient mesh slicing

// --- Imports ---
import 'canvas_geometry.dart';       
import 'canvas_keyboard_handler.dart'; 
import 'canvas_gesture_handler.dart'; // <--- NEW: Extracted Gestures

// Defines the current interaction mode for the canvas
enum CompassTool { select, addPoint, addLine, addCircle, addSpiral, addPen, addRect } 

class CanvasController extends ChangeNotifier {
  final CompassEngine engine;

  CanvasController(this.engine) {
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    return CanvasKeyboardHandler.handleKeyEvent(event, this, engine);
  }

  // --- PUBLIC STATE FOR UI & HANDLERS ---
  CompassTool currentTool = CompassTool.select;
  CompassPoint? shapeStartPoint; 
  
  Offset? hoverPosition;
  CompassPoint? hoveredPoint; 
  
  // --- UPDATED: Route selection state directly to the engine so panels can see it ---
  Set<CompassPoint> get selectedPoints => engine.selectedPoints;
  set selectedPoints(Set<CompassPoint> value) { 
    engine.selectedPoints = value; 
  }
  
  bool isDraggingSelectionBox = false;
  Offset? selectionBoxStart;
  Offset? selectionBoxCurrent;
  
  CompassSplineNode? targetTensionNode; 
  CompassSplineNode? activeHandleNode;
  bool activeHandleIsOut = false;

  CompassSplineNode? activeFilletNode;
  CompassXSpline? activeFilletSpline;
  double activeFilletRadius = 0.0;

  bool isWPressed = false;
  CompassSplineNode? activeWidthNode;
  bool activeWidthIsLeft = false;
  CompassXSpline? activeWidthSpline; 
  bool isUnifiedWidthPull = false;

  bool isZPressed = false;
  bool isShiftZPressed = false; 
  
  bool isSmoothing = false;
  final Map<CompassPoint, Offset> smoothOrigPositions = {};
  final Map<CompassSplineNode, (Offset?, Offset?)> smoothOrigHandles = {};

  bool isWidthSmoothing = false; 
  final Map<CompassSplineNode, (double, double)> smoothOrigWidths = {}; 

  CompassXSpline? addVertexSpline;
  int addVertexSegmentIndex = -1;
  Offset? addVertexPreviewPos;

  // --- X-KEY MESH SLICE HOVER STATE ---
  CompassMesh? sliceMesh;
  bool sliceIsRow = false; // true => horizontal cut (insert row); false => column
  int sliceGap = -1;
  double sliceT = 0.5; // parametric position of the cut within the band
  Offset? slicePreviewA;
  Offset? slicePreviewB;

  Offset panOffset = Offset.zero;
  double canvasScale = 1.0; 
  bool isPanningCanvas = false;

  bool isRPressed = false;
  bool isShiftRPressed = false;
  bool isCtrlRPressed = false; 
  bool isShiftPressed = false;
  bool isAPressed = false; 
  bool isFPressed = false; 
  bool isQPressed = false; 
  bool isXPressed = false; 
  bool is1Pressed = false; 
  bool is2Pressed = false; 

  Offset? rotationPivotOffset; 

  // Made public so CanvasGestureHandler can access them
  Offset? lastPanPosition; 
  Offset? dragStartLogicalPosition; 
  Set<CompassPoint> initialSelectionBeforeBox = {};
  bool isPanningSelectedPoints = false;
  bool isStrictPanningSelection = false;

  (CompassPoint?, bool)? pendingSelectPress;
  
  CompassXSpline? activeSpline;
  CompassSplineNode? activeTensionNode; 

  bool isRotating = false;
  bool isPanningShape = false;
  
  Set<CompassPoint> transformingPoints = {}; 
  final List<CompassSplineNode> rotatingHandleNodes = [];
  final double hitThreshold = 20.0; 

  // --- NEW: State for tracking the live Corner Radius constraint drag ---
  CompassSplineNode? activeCornerCircleNode;

  // --- TOOL MANAGEMENT ---
  void setTool(CompassTool tool) {
    currentTool = tool;
    selectedPoints.clear(); 
    shapeStartPoint = null; 
    activeSpline = null;
    pendingSelectPress = null;
    clearAddVertexHover();
    clearMeshSliceHover();
    notifyListeners();
  }

  void removePointFromSelection(CompassPoint point) {
    if (selectedPoints.contains(point)) {
      selectedPoints.remove(point);
      notifyListeners();
    }
  }

  void startSplineFrom(CompassPoint point) {
    currentTool = CompassTool.addPen;
    selectedPoints.clear(); 
    shapeStartPoint = null;
    
    activeSpline = CompassXSpline(isClosed: false);
    final node = CompassSplineNode(point: point, tension: 1.0);
    node.tension.addListener(engine.notifyListeners);
    activeSpline!.addNode(node);
    engine.addShape(activeSpline!);
    notifyListeners();
  }

  void startCircleFrom(CompassPoint point) {
    currentTool = CompassTool.addCircle;
    shapeStartPoint = point;
    selectedPoints.clear();
    activeSpline = null;
    notifyListeners();
  }

  // --- STATE SETUP & TEARDOWN HELPERS ---
  void setupTensionState() {
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

  void setupRotationState({required bool hierarchy, bool handlesOnly = false}) {
    if (selectedPoints.length >= 2) {
      rotationPivotOffset = CanvasGeometry.centroidOfPoints(selectedPoints); 
      if (hierarchy && !handlesOnly) {
        Set<CompassPoint> body = {};
        for (var p in selectedPoints) {
          body.addAll(CanvasGeometry.getRigidBody(engine, null, p, true)); 
        }
        transformingPoints = CanvasGeometry.expandForShapeCohesion(engine, body); 
      } else {
        transformingPoints = Set<CompassPoint>.from(selectedPoints);
      }
      return;
    }

    CompassPoint? explicitPoint = selectedPoints.isNotEmpty ? selectedPoints.first : hoveredPoint;
    
    if (handlesOnly) {
      if (explicitPoint != null) {
        rotationPivotOffset = Offset(explicitPoint.x.value, explicitPoint.y.value);
        transformingPoints = {explicitPoint};
      } else {
        rotationPivotOffset = null;
        transformingPoints = {};
      }
      return;
    }

    CompassShape? selShape = engine.selectedShape;
    Offset? pivotOffset;

    if (hierarchy) {
      if (selShape != null) {
        pivotOffset = CanvasGeometry.getShapeCentroid(selShape); 
      } else if (explicitPoint != null) {
        pivotOffset = Offset(explicitPoint.x.value, explicitPoint.y.value);
      }
    } else {
      if (explicitPoint != null) {
        pivotOffset = Offset(explicitPoint.x.value, explicitPoint.y.value);
      } else if (selShape != null) {
        pivotOffset = CanvasGeometry.getShapeCentroid(selShape); 
      }
    }

    rotationPivotOffset = pivotOffset;
    transformingPoints = CanvasGeometry.expandForShapeCohesion(
      engine, CanvasGeometry.getRigidBody(engine, selShape, explicitPoint, hierarchy) 
    );
  }

  void clearRotationState() {
    rotationPivotOffset = null;
    transformingPoints.clear();
    isRotating = false;
  }

  void clearFilletState() {
    activeFilletNode = null;
    activeFilletSpline = null;
    activeFilletRadius = 0.0;
  }

  void clearWidthState() {
    activeWidthNode = null;
    isUnifiedWidthPull = false;
    activeWidthSpline = null;
  }

  // --- INTERNAL MATH & HIT TESTING ---

  Offset getLogicalPosition(Offset localPosition) {
    return (localPosition - panOffset) / canvasScale;
  }

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

  // --- Q-HOVER "ADD RESOLUTION" HELPERS ---
  void updateAddVertexHover(Offset logical) {
    if (currentTool != CompassTool.select || !isQPressed || hoveredPoint != null) {
      clearAddVertexHover();
      return;
    }
    final hit = _findNearestSplineSegment(logical);
    if (hit == null) {
      clearAddVertexHover();
      return;
    }
    addVertexSpline = hit.$1;
    addVertexSegmentIndex = hit.$2;
    addVertexPreviewPos = hit.$3;
  }

  void clearAddVertexHover() {
    addVertexSpline = null;
    addVertexSegmentIndex = -1;
    addVertexPreviewPos = null;
  }

  // --- X-HOVER "SLICE MESH" HELPERS ---
  void updateMeshSliceHover(Offset logical) {
    if (currentTool != CompassTool.select || !isXPressed) {
      clearMeshSliceHover();
      return;
    }

    CompassMesh? target;
    for (var layer in engine.layers.reversed) {
      if (!layer.isVisible || layer.isLocked) continue;
      for (var shape in layer.shapes.reversed) {
        if (!shape.isVisible) continue;
        if (shape is CompassMesh && shape.getPath().contains(logical)) {
          target = shape;
          break;
        }
      }
      if (target != null) break;
    }

    if (target == null || target.rows < 2 || target.cols < 2) {
      clearMeshSliceHover();
      return;
    }

    final rowGap = target.rowGapAt(logical);
    final colGap = target.colGapAt(logical);

    double rowT = 0.5, colT = 0.5;
    (Offset, Offset)? rowLine;
    (Offset, Offset)? colLine;

    double distToRowEdge = double.infinity;
    double distToColEdge = double.infinity;

    if (rowGap != -1) {
      rowT = target.rowParamAt(rowGap, logical);
      rowLine = target.rowSlicePreview(rowGap, rowT);
      if (rowLine != null) {
        final yTop = target.rowY(rowGap);
        final yBot = target.rowY(rowGap + 1);
        distToRowEdge = min((logical.dy - yTop).abs(), (logical.dy - yBot).abs());
      }
    }
    
    if (colGap != -1) {
      colT = target.colParamAt(colGap, logical);
      colLine = target.colSlicePreview(colGap, colT);
      if (colLine != null) {
        final xLeft = target.colX(colGap);
        final xRight = target.colX(colGap + 1);
        distToColEdge = min((logical.dx - xLeft).abs(), (logical.dx - xRight).abs());
      }
    }

    if (rowLine == null && colLine == null) {
      clearMeshSliceHover();
      return;
    }

    bool chooseRow;

    if (is1Pressed && rowLine != null) {
      chooseRow = true;
    } else if (is2Pressed && colLine != null) {
      chooseRow = false;
    } else {
      double bias = 0.0;
      if (sliceMesh == target && sliceGap != -1) {
        bias = 10.0 / canvasScale; 
      }

      double effectiveColDist = distToColEdge - (sliceIsRow ? bias : 0);
      double effectiveRowDist = distToRowEdge - (!sliceIsRow ? bias : 0);

      chooseRow = effectiveColDist <= effectiveRowDist ? rowLine != null : colLine == null;
      if (rowLine == null) chooseRow = false;
      if (colLine == null) chooseRow = true;
    }

    sliceMesh = target;
    if (chooseRow && rowLine != null) {
      sliceIsRow = true;
      sliceGap = rowGap;
      sliceT = rowT;
      slicePreviewA = rowLine.$1;
      slicePreviewB = rowLine.$2;
    } else if (colLine != null) {
      sliceIsRow = false;
      sliceGap = colGap;
      sliceT = colT;
      slicePreviewA = colLine.$1;
      slicePreviewB = colLine.$2;
    } else {
      clearMeshSliceHover();
    }
  }

  void clearMeshSliceHover() {
    sliceMesh = null;
    sliceIsRow = false;
    sliceGap = -1;
    sliceT = 0.5;
    slicePreviewA = null;
    slicePreviewB = null;
  }

  (CompassXSpline, int, Offset)? _findNearestSplineSegment(Offset logical) {
    final scaledThreshold = hitThreshold / canvasScale;

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
            final pt = CanvasGeometry.cubicAt(p0, p1, p2, p3, s / samples); 
            final d = (pt - logical).distance;
            if (d < segMinDist) segMinDist = d;
          }

          if (segMinDist < bestDist && segMinDist <= scaledThreshold) {
            bestDist = segMinDist;
            bestSpline = shape;
            bestSeg = i;
            bestCenter = CanvasGeometry.cubicAt(p0, p1, p2, p3, 0.5); 
          }
        }
      }
    }

    if (bestSpline == null || bestCenter == null) return null;
    return (bestSpline, bestSeg, bestCenter);
  }

  // ===========================================================================
  // GESTURE DELEGATES (Routed to CanvasGestureHandler)
  // ===========================================================================

  void startCanvasPan() => CanvasGestureHandler.startCanvasPan(this);
  void updateCanvasPan(Offset delta) => CanvasGestureHandler.updateCanvasPan(this, delta);
  void endCanvasPan() => CanvasGestureHandler.endCanvasPan(this);
  void handleScroll(PointerScrollEvent event, BuildContext context) => CanvasGestureHandler.handleScroll(this, engine, event, context);
  void onHover(PointerHoverEvent event, BuildContext context, bool showScaffolding) => CanvasGestureHandler.onHover(this, engine, event, context, showScaffolding);
  void clearHover() => CanvasGestureHandler.clearHover(this);
  
  Future<void> onSecondaryTapDown(TapDownDetails details, BuildContext context, bool showScaffolding, VoidCallback onToggleScaffolding, bool showHandles, VoidCallback onToggleHandles) => 
      CanvasGestureHandler.onSecondaryTapDown(this, engine, details, context, showScaffolding, onToggleScaffolding, showHandles, onToggleHandles);
  
  void onTapDown(TapDownDetails details, BuildContext context, bool showScaffolding) => CanvasGestureHandler.onTapDown(this, engine, details, context, showScaffolding);
  void onTap() => CanvasGestureHandler.onTap(this, engine);
  void onTapCancel() => CanvasGestureHandler.onTapCancel(this);
  
  void onPanStart(DragStartDetails details, BuildContext context, bool showScaffolding, bool showHandles) => CanvasGestureHandler.onPanStart(this, engine, details, context, showScaffolding, showHandles);
  void onPanUpdate(DragUpdateDetails details, BuildContext context, bool showScaffolding) => CanvasGestureHandler.onPanUpdate(this, engine, details, context, showScaffolding);
  void onPanEnd(DragEndDetails details) => CanvasGestureHandler.onPanEnd(this, engine, details);
  void onPanCancel() => CanvasGestureHandler.onPanCancel(this);
}