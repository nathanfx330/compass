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
import '../../models/geometry/gradient.dart';
import '../../models/layer.dart'; // <--- NEW: CompassLayer for the mirror-axis drag slot

// --- Imports ---
import 'canvas_geometry.dart';       
import 'canvas_keyboard_handler.dart'; 
import 'canvas_gesture_handler.dart'; // <--- NEW: Extracted Gestures

// Defines the current interaction mode for the canvas
// <--- NEW: Added addRhombus --->
enum CompassTool { select, addPoint, addLine, addCircle, addSpiral, addPen, addRect, addRhombus } 

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

  // --- NEW: MIRROR MODIFIER axis drag ---
  // Set by the gesture handler when a pan grabs the active layer's mirror axis
  // line; onPanUpdate then writes that layer's mirrorPosition until release
  // (snapshot on onPanEnd, cleared on onPanCancel).
  CompassLayer? mirrorDragLayer;

  // --- PER-SHAPE LINEAR GRADIENT STOP DRAG ---
  //
  // The first and last gradient stops define the axis and remain freely
  // draggable so the user can reposition, rotate, and resize that axis.
  // Stops between them are interior color stops. While an interior stop is
  // dragged, the gesture handler asks [constrainGradientStopDrag] for the
  // nearest position on the dotted axis, producing a true slider interaction.
  //
  // These slots are controller interaction state only. They are not document
  // state and therefore are never serialized or snapshotted.
  CompassShape? gradientDragShape;
  GradientStop? gradientDragStop;

  // --- TOOL MANAGEMENT ---
  void setTool(CompassTool tool) {
    currentTool = tool;
    selectedPoints.clear(); 
    shapeStartPoint = null; 
    activeSpline = null;
    pendingSelectPress = null;
    clearGradientStopDragState();
    clearAddVertexHover();
    clearMeshSliceHover();
    notifyListeners();
  }

  // ===========================================================================
  // DESELECT ALL (Escape key / Edit menu)
  // ===========================================================================
  //
  // THE "LET GO OF EVERYTHING" ACTION. Several mechanisms could previously hold
  // onto prior work with no keyboard escape hatch:
  //
  //   1. THE PEN TOOL NEVER RELEASED ITS SPLINE -- once activeSpline was set,
  //      every subsequent click appended another vertex to the SAME spline
  //      forever; the only exits were a right-click or clicking the first node
  //      to close the loop. This is the "doesn't let go of the previous
  //      vertexes" bug: the chain just kept growing.
  //   2. shapeStartPoint lingered when a two-click shape (line/circle/rect/
  //      spiral) was abandoned halfway, so the NEXT click completed a shape you
  //      forgot you started.
  //   3. isBeingDragged flags could be stranded ON if a drag ended through an
  //      unusual path (focus loss, gesture-arena races). A stranded flag
  //      silently disables the constraints' rigid-body guards, making geometry
  //      behave as if still attached to a phantom drag.
  //
  // deselectAll() clears ALL of it in one shot and returns to the Select tool:
  //
  //   * Abandons the pen tool's active spline. If that spline has fewer than 2
  //     nodes it is REMOVED outright (via engine.removeShape, which GCs its
  //     point and any constraints): a sub-2-node spline can neither render nor
  //     serialize (the loader requires >= 2), so leaving it was pure debris.
  //     With 2+ nodes the spline is kept as-is -- it's real geometry -- and
  //     merely released, exactly like the right-click abandon.
  //   * Clears shapeStartPoint (kills any half-built two-click shape).
  //   * Clears point selection AND the engine's selected shape.
  //   * Clears every transient interaction slot: pending press, selection box,
  //     rotation/fillet/width/tension/handle/corner-pulley/mirror-drag state,
  //     Q-hover and X-slice previews, smoothing captures.
  //   * FORCE-RESETS isBeingDragged on every point in the pool -- the stranded-
  //     flag cure. Safe even mid-drag: the flag is only an advisory read by the
  //     constraint guards, and a genuinely live drag re-latches nothing after
  //     Escape anyway since the transient slots above are also cleared.
  //
  // Deliberately NO undo snapshot: deselecting mutates no geometry (except the
  // degenerate-spline removal, and removeShape snapshots itself), so Escape
  // never pollutes the undo stack.
  void deselectAll() {
    // 1. Release (or GC) the pen tool's in-progress spline.
    if (activeSpline != null) {
      if (activeSpline!.nodes.length < 2) {
        engine.removeShape(activeSpline!);
      }
      activeSpline = null;
    }

    // 2. Kill any half-built two-click shape.
    shapeStartPoint = null;

    // 3. Clear selection: points AND shape.
    selectedPoints.clear();
    engine.selectShape(null);

    // 4. Clear every transient interaction slot.
    pendingSelectPress = null;
    isDraggingSelectionBox = false;
    selectionBoxStart = null;
    selectionBoxCurrent = null;
    initialSelectionBeforeBox = {};
    isPanningSelectedPoints = false;
    isStrictPanningSelection = false;
    isPanningShape = false;
    mirrorDragLayer = null;
    clearGradientStopDragState();

    clearRotationState();
    clearFilletState();
    clearWidthState();
    activeHandleNode = null;
    activeTensionNode = null;
    targetTensionNode = null;
    activeCornerCircleNode = null;

    isSmoothing = false;
    smoothOrigPositions.clear();
    smoothOrigHandles.clear();
    isWidthSmoothing = false;
    smoothOrigWidths.clear();

    clearAddVertexHover();
    clearMeshSliceHover();

    lastPanPosition = null;
    dragStartLogicalPosition = null;

    // 5. Stranded-flag cure: no point may claim to be mid-drag after Escape.
    for (var p in engine.points) {
      p.isBeingDragged = false;
    }

    // 6. Clean slate: back to the Select tool.
    currentTool = CompassTool.select;

    notifyListeners();
    engine.notifyListeners();
  }

  void removePointFromSelection(CompassPoint point) {
    if (selectedPoints.contains(point)) {
      selectedPoints.remove(point);
      notifyListeners();
    }
  }

  // ===========================================================================
  // PER-SHAPE LINEAR GRADIENT STOP DRAG
  // ===========================================================================

  /// Returns the selected, visible, unlocked shape and gradient stop that own
  /// [point], or `null` when the point is not an editable visible gradient stop.
  ///
  /// Gradient stops belonging to unselected shapes are intentionally ignored.
  /// Their dots and dotted axes are not drawn, so they must not remain
  /// accidentally hittable as invisible points.
  (CompassShape, GradientStop)? editableGradientStopForPoint(
    CompassPoint point,
  ) {
    final shape = engine.selectedShape;
    if (shape == null || !shape.isVisible) {
      return null;
    }

    CompassLayer? owningLayer;
    for (final layer in engine.layers) {
      if (layer.shapes.contains(shape)) {
        owningLayer = layer;
        break;
      }
    }

    if (owningLayer == null ||
        !owningLayer.isVisible ||
        owningLayer.isLocked) {
      return null;
    }

    final gradient = shape.gradient;
    if (gradient == null) {
      return null;
    }

    for (final stop in gradient.stops) {
      if (stop.point == point) {
        return (shape, stop);
      }
    }

    return null;
  }

  /// Captures a gradient stop for the current point drag.
  ///
  /// Returns `true` when [point] is an editable stop belonging to the currently
  /// selected shape. The gesture handler can still use its ordinary point-drag
  /// machinery; it only needs to pass proposed positions through
  /// [constrainGradientStopDrag].
  bool beginGradientStopDrag(CompassPoint point) {
    final hit = editableGradientStopForPoint(point);

    if (hit == null) {
      clearGradientStopDragState();
      return false;
    }

    gradientDragShape = hit.$1;
    gradientDragStop = hit.$2;
    return true;
  }

  /// Whether the captured gradient stop is an interior color stop.
  ///
  /// Endpoint stops define the gradient axis and therefore remain freely
  /// draggable. Only interior stops behave as sliders locked to that axis.
  bool get isDraggingInteriorGradientStop {
    final shape = gradientDragShape;
    final stop = gradientDragStop;
    final gradient = shape?.gradient;

    if (shape == null || stop == null || gradient == null) {
      return false;
    }

    if (!gradient.stops.contains(stop)) {
      return false;
    }

    return !gradient.isEndpoint(stop);
  }

  /// Constrains a proposed world-space drag position when an interior gradient
  /// stop is active.
  ///
  /// For endpoint stops, ordinary points, removed stops, or gradients that no
  /// longer exist, the proposed position is returned unchanged.
  Offset constrainGradientStopDrag(Offset proposedPosition) {
    final shape = gradientDragShape;
    final stop = gradientDragStop;
    final gradient = shape?.gradient;

    if (shape == null || stop == null || gradient == null) {
      return proposedPosition;
    }

    if (!gradient.stops.contains(stop) || gradient.isEndpoint(stop)) {
      return proposedPosition;
    }

    return gradient.projectOntoAxis(proposedPosition);
  }

  /// Clears the transient gradient-stop drag capture.
  void clearGradientStopDragState() {
    gradientDragShape = null;
    gradientDragStop = null;
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

        final nRaw = shape.nodes.length;
        if (nRaw < 2) continue;

        final resolved = shape.getResolvedNodes();
        final nRes = resolved.length;
        final segCount = shape.isClosed ? nRes : nRes - 1;

        for (int i = 0; i < segCount; i++) {
          final r0 = resolved[i];
          final r3 = resolved[(i + 1) % nRes];
          final p0 = r0.point;
          final p3 = r3.point;
          final p1 = p0 + r0.hOut;
          final p2 = p3 + r3.hIn;

          const samples = 16;
          double segMinDist = double.infinity;

          for (int s = 0; s <= samples; s++) {
            final pt = CanvasGeometry.cubicAt(p0, p1, p2, p3, s / samples); 
            final d = (pt - logical).distance;
            if (d < segMinDist) {
              segMinDist = d;
            }
          }

          if (segMinDist < bestDist && segMinDist <= scaledThreshold) {
            bestDist = segMinDist;
            bestSpline = shape;
            bestSeg = r0.rawIndex; 
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
  
  // --- CHANGED: now carries the Ghost Vertices flag + toggle through to the
  // gesture handler, which forwards them to the context-menu builder so the
  // right-click empty-canvas menu can offer the toggle like scaffolding/handles.
  Future<void> onSecondaryTapDown(TapDownDetails details, BuildContext context, bool showScaffolding, VoidCallback onToggleScaffolding, bool showHandles, VoidCallback onToggleHandles, bool ghostVertices, VoidCallback onToggleGhostVertices) => 
      CanvasGestureHandler.onSecondaryTapDown(this, engine, details, context, showScaffolding, onToggleScaffolding, showHandles, onToggleHandles, ghostVertices, onToggleGhostVertices);
  
  void onTapDown(TapDownDetails details, BuildContext context, bool showScaffolding) => CanvasGestureHandler.onTapDown(this, engine, details, context, showScaffolding);
  void onTap() => CanvasGestureHandler.onTap(this, engine);
  void onTapCancel() => CanvasGestureHandler.onTapCancel(this);
  
  void onPanStart(DragStartDetails details, BuildContext context, bool showScaffolding, bool showHandles) => CanvasGestureHandler.onPanStart(this, engine, details, context, showScaffolding, showHandles);
  void onPanUpdate(DragUpdateDetails details, BuildContext context, bool showScaffolding) => CanvasGestureHandler.onPanUpdate(this, engine, details, context, showScaffolding);
  void onPanEnd(DragEndDetails details) => CanvasGestureHandler.onPanEnd(this, engine, details);
  void onPanCancel() => CanvasGestureHandler.onPanCancel(this);
}