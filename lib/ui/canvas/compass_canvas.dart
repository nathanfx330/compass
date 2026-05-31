// lib/ui/canvas/compass_canvas.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:flutter/gestures.dart'; 

import '../../engine.dart';
import '../../constraints.dart';

// --- DATA MODELS ---
import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';

// --- UI COMPONENTS ---
import 'compass_renderer.dart';
import 'canvas_hud.dart';

// Defines the current interaction mode for the canvas
enum CompassTool { select, addPoint, addLine, addCircle, addSpiral, addPen }

class CompassCanvas extends StatefulWidget {
  final CompassEngine engine;
  final bool showScaffolding;
  final VoidCallback onToggleScaffolding;

  const CompassCanvas({
    super.key, 
    required this.engine,
    this.showScaffolding = true,
    required this.onToggleScaffolding,
  });

  @override
  State<CompassCanvas> createState() => _CompassCanvasState();
}

class _CompassCanvasState extends State<CompassCanvas> {
  CompassTool _currentTool = CompassTool.select;
  CompassPoint? _activePoint;
  CompassPoint? _shapeStartPoint; 
  Offset? _lastPanPosition; 
  
  // Hover & Selection tracking
  Offset? _hoverPosition;
  CompassPoint? _hoveredPoint; 
  CompassPoint? _selectedPoint; // Tracks an explicitly clicked point
  
  // X-Spline active state
  CompassXSpline? _activeSpline;
  CompassSplineNode? _activeTensionNode; // The node whose tension we are currently dragging
  CompassSplineNode? _targetTensionNode; // The node targeted by holding the 'A' key (pre-drag)

  // Canvas Transform State
  Offset _panOffset = Offset.zero;
  double _canvasScale = 1.0; 
  bool _isPanningCanvas = false;

  // Keyboard & Transformation State
  bool _isRPressed = false;
  bool _isShiftRPressed = false;
  bool _isShiftPressed = false;
  bool _isAPressed = false; 
  
  bool _isRotating = false;
  bool _isPanningShape = false;
  
  Offset? _rotationPivotOffset; 
  Set<CompassPoint> _transformingPoints = {}; // The rigid body of points being rotated or panned

  final double _hitThreshold = 20.0; 

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    final isR = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.keyR);
    final isShift = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
                    HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight);
    final isA = HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.keyA);

    final bool shiftR = isR && isShift;
    final bool justR = isR && !isShift;
    final bool justShift = isShift && !isR && !isA; 

    if (_isRPressed != justR || _isShiftRPressed != shiftR || _isShiftPressed != justShift || _isAPressed != isA) {
      setState(() {
        _isRPressed = justR;
        _isShiftRPressed = shiftR;
        _isShiftPressed = justShift;
        _isAPressed = isA; 

        if (justR || shiftR) {
          _setupRotationState(hierarchy: shiftR);
        } else {
          _rotationPivotOffset = null;
          _transformingPoints.clear();
          _isRotating = false; 
        }

        if (isA) {
          _setupTensionState();
        } else {
          _targetTensionNode = null;
        }
      });
    }
    return false; // Do not swallow the event
  }

  void _setupTensionState() {
    CompassPoint? explicitPoint = _selectedPoint ?? _hoveredPoint;
    if (explicitPoint != null) {
      for (var layer in widget.engine.layers) {
        if (!layer.isVisible || layer.isLocked) continue; // Skip locked
        for (var shape in layer.shapes) {
          if (!shape.isVisible) continue;
          if (shape is CompassXSpline) {
            for (var node in shape.nodes) {
              if (node.point == explicitPoint) {
                _targetTensionNode = node;
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
    } else if (shape is CompassLine) {
      return Offset((shape.start.x.value + shape.end.x.value) / 2, (shape.start.y.value + shape.end.y.value) / 2);
    }
    return null;
  }

  // --- NEW: Helper to determine if a point is strictly bound to locked layers ---
  bool _isPointLocked(CompassPoint p) {
    bool usedInUnlocked = false;
    bool usedInLocked = false;

    for (var layer in widget.engine.layers) {
      if (!layer.isVisible) continue; 
      
      for (var shape in layer.shapes) {
        if (!shape.isVisible) continue;

        bool hasPoint = false;
        if (shape is CompassLine && (shape.start == p || shape.end == p)) hasPoint = true;
        else if (shape is CompassCircle && (shape.center == p || shape.radiusPoint == p)) hasPoint = true;
        else if (shape is CompassSpiral && (shape.center == p || shape.startPoint == p)) hasPoint = true;
        else if (shape is CompassXSpline && (shape.nodes.any((n) => n.point == p) || shape.anchorPoint == p)) hasPoint = true;

        if (hasPoint) {
          if (layer.isLocked) {
            usedInLocked = true;
          } else {
            usedInUnlocked = true;
          }
        }
      }
    }

    // Free floating points are unlocked
    if (!usedInLocked && !usedInUnlocked) return false;
    // If it's used in at least one unlocked layer, we must allow interacting with it
    return usedInLocked && !usedInUnlocked;
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

        for (var layer in widget.engine.layers) {
          if (!layer.isVisible || layer.isLocked) continue; // Skip locked layers for hierarchy gathering
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

  void _setupRotationState({required bool hierarchy}) {
    CompassPoint? explicitPoint = _selectedPoint ?? _hoveredPoint;
    CompassShape? selShape = widget.engine.selectedShape;

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

    _rotationPivotOffset = pivotOffset;
    _transformingPoints = _getRigidBody(selShape, explicitPoint, hierarchy);
  }

  Offset _getLogicalPosition(Offset localPosition) {
    return (localPosition - _panOffset) / _canvasScale;
  }

  void _onHover(PointerHoverEvent event) {
    if (!widget.showScaffolding) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(event.position);
    final logicalPosition = _getLogicalPosition(localPosition);

    CompassPoint? foundPoint;
    final scaledThreshold = _hitThreshold / _canvasScale; 

    for (var point in widget.engine.points) {
      if (_isPointLocked(point)) continue; // SKIP LOCKED
      
      final distance = sqrt(
        pow(point.x.value - logicalPosition.dx, 2) +
        pow(point.y.value - logicalPosition.dy, 2),
      );

      if (distance < scaledThreshold) {
        foundPoint = point;
        break; 
      }
    }

    setState(() {
      _hoverPosition = logicalPosition;
      _hoveredPoint = foundPoint;
      
      if ((_isRPressed || _isShiftRPressed) && _rotationPivotOffset == null && foundPoint != null) {
        _setupRotationState(hierarchy: _isShiftRPressed);
      }

      if (_isAPressed && _targetTensionNode == null && foundPoint != null) {
        _setupTensionState();
      }
    });
  }

  void _onSecondaryTapDown(TapDownDetails details) async {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = _getLogicalPosition(localPosition);

    if (_currentTool == CompassTool.addPen && _activeSpline != null) {
      setState(() {
        _activeSpline = null;
        _currentTool = CompassTool.select;
      });
      return;
    }

    CompassShape? clickedShape;
    CompassPoint? clickedPoint;
    final scaledThreshold = _hitThreshold / _canvasScale;

    for (var point in widget.engine.points) {
      if (_isPointLocked(point)) continue; // SKIP LOCKED
      
      final distance = sqrt(
        pow(point.x.value - logicalPosition.dx, 2) +
        pow(point.y.value - logicalPosition.dy, 2),
      );

      if (distance < scaledThreshold) {
        clickedPoint = point;
        break; 
      }
    }

    if (clickedPoint == null) {
      for (var layer in widget.engine.layers.reversed) {
        if (!layer.isVisible || layer.isLocked) continue; // SKIP LOCKED

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
      for (var layer in widget.engine.layers) {
        if (layer.isLocked) continue; // SKIP LOCKED
        for (var shape in layer.shapes) {
          if (shape is CompassXSpline && shape.nodes.any((n) => n.point == clickedPoint)) {
            parentSpline = shape;
            break;
          }
        }
        if (parentSpline != null) break;
      }

      final List<PopupMenuEntry<String>> pointMenuItems = [];

      if (parentSpline != null) {
        pointMenuItems.add(PopupMenuItem(
          value: 'toggle_closed',
          child: Text(parentSpline.isClosed ? 'Open Spline' : 'Close Spline (Connect Last to First)'),
        ));
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
        widget.engine.removePoint(clickedPoint);
        if (_selectedPoint == clickedPoint) setState(() => _selectedPoint = null);
      } else if (selectedAction == 'toggle_closed' && parentSpline != null) {
        widget.engine.toggleSplineClosed(parentSpline);
      } else if (selectedAction == 'start_spline') {
        setState(() {
          _currentTool = CompassTool.addPen;
          _activePoint = null;
          _shapeStartPoint = null;
          _selectedPoint = null; 
          
          _activeSpline = CompassXSpline(isClosed: false);
          final node = CompassSplineNode(point: clickedPoint!, tension: 1.0);
          node.tension.addListener(widget.engine.notifyListeners);
          _activeSpline!.addNode(node);
          widget.engine.addShape(_activeSpline!);
        });
      } else if (selectedAction == 'start_circle') {
        setState(() {
          _currentTool = CompassTool.addCircle;
          _shapeStartPoint = clickedPoint;
          _activePoint = null;
          _selectedPoint = null; 
          _activeSpline = null;
        });
      }
    } else if (clickedShape != null) {
      widget.engine.selectShape(clickedShape);

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
      } else if (clickedShape is CompassCircle) {
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
          widget.engine.removeShape(clickedShape);
        } else if (selectedAction == 'toggle_closed' && clickedShape is CompassXSpline) {
          widget.engine.toggleSplineClosed(clickedShape);
        } else if (selectedAction == 'convert_to_spline' && clickedShape is CompassCircle) {
          widget.engine.convertCircleToSpline(clickedShape);
        } else if (selectedAction == 'add_point') {
          final newPoint = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          widget.engine.addPoint(newPoint);

          if (clickedShape is CompassLine) {
            clickedShape.start.attach(newPoint); 
            PointOnLineConstraint(point: newPoint, line: clickedShape);
          } else if (clickedShape is CompassCircle) {
            clickedShape.center.attach(newPoint); 
            PointOnCircleConstraint(point: newPoint, circle: clickedShape);
          } else if (clickedShape is CompassSpiral) {
            clickedShape.center.attach(newPoint); 
            PointOnSpiralConstraint(point: newPoint, spiral: clickedShape);
          } else if (clickedShape is CompassXSpline) {
            widget.engine.insertPointIntoSpline(newPoint, clickedShape);
          }
        } else {
          final op = CompassBooleanOp.values.firstWhere((e) => e.name == selectedAction);
          widget.engine.changeShapeOperation(clickedShape, op);
        }
      }
    } else {
      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: [
          PopupMenuItem(
            value: 'toggle_scaffolding', 
            child: Text(widget.showScaffolding ? 'Hide Scaffolding (Clean View)' : 'Show Scaffolding'),
          ), 
        ],
      );

      if (selectedAction == 'toggle_scaffolding') {
        widget.onToggleScaffolding();
      }
    }
  }

  void _onTapDown(TapDownDetails details) {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = _getLogicalPosition(localPosition);

    final bool isShiftPressed = HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.shiftLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed
            .contains(LogicalKeyboardKey.shiftRight);

    if (_currentTool == CompassTool.select) {
      
      CompassPoint? hitPoint;
      final scaledThreshold = _hitThreshold / _canvasScale; 
      for (var point in widget.engine.points) {
        if (_isPointLocked(point)) continue; // SKIP LOCKED

        final distance = sqrt(
          pow(point.x.value - logicalPosition.dx, 2) +
          pow(point.y.value - logicalPosition.dy, 2),
        );
        if (distance < scaledThreshold) {
          hitPoint = point;
          break; 
        }
      }

      if (hitPoint != null) {
        setState(() {
          _selectedPoint = hitPoint;
        });

        CompassShape? ownerShape;
        for (var layer in widget.engine.layers.reversed) {
          if (!layer.isVisible || layer.isLocked) continue; // SKIP LOCKED
          for (var shape in layer.shapes.reversed) {
            if (!shape.isVisible) continue;
            if (shape is CompassXSpline && (shape.nodes.any((n) => n.point == hitPoint) || shape.anchorPoint == hitPoint)) {
              ownerShape = shape; break;
            } else if (shape is CompassCircle && (shape.center == hitPoint || shape.radiusPoint == hitPoint)) {
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
          widget.engine.selectShape(ownerShape);
        } else {
          widget.engine.selectShape(null);
        }
        return;
      }

      CompassShape? hitShape;
      for (var layer in widget.engine.layers.reversed) {
        if (!layer.isVisible || layer.isLocked) continue; // SKIP LOCKED
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
          } else if (shape is CompassXSpline) {
             if (shape.getPath().contains(logicalPosition)) {
                hitShape = shape;
                break;
             }
          }
        }
        if (hitShape != null) break;
      }

      if (hitShape == null && _hoveredPoint == null) {
        widget.engine.selectShape(null);
        setState(() => _selectedPoint = null); 
      } else if (hitShape != null) {
        widget.engine.selectShape(hitShape);
        setState(() => _selectedPoint = null); 
      }
    }
    else if (_currentTool == CompassTool.addPoint) {
      CompassShape? closestShape;
      double minDistance = _hitThreshold / _canvasScale;

      for (var layer in widget.engine.layers) {
        if (!layer.isVisible || layer.isLocked) continue; // SKIP LOCKED

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
      widget.engine.addPoint(newPoint);

      if (closestShape is CompassLine) {
        PointOnLineConstraint(point: newPoint, line: closestShape);
      } else if (closestShape is CompassCircle) {
        PointOnCircleConstraint(point: newPoint, circle: closestShape);
      } else if (closestShape is CompassSpiral) {
        PointOnSpiralConstraint(point: newPoint, spiral: closestShape);
      } else if (closestShape is CompassXSpline) {
        widget.engine.insertPointIntoSpline(newPoint, closestShape);
      }
    } 
    else if (_currentTool == CompassTool.addPen) {
      CompassPoint tappedPoint;
      
      if (_hoveredPoint != null) {
        tappedPoint = _hoveredPoint!;
      } else {
        tappedPoint = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
        widget.engine.addPoint(tappedPoint);
      }

      if (_activeSpline == null) {
        _activeSpline = CompassXSpline(isClosed: false);
        final node = CompassSplineNode(point: tappedPoint, tension: 1.0); 
        node.tension.addListener(widget.engine.notifyListeners);
        _activeSpline!.addNode(node);
        widget.engine.addShape(_activeSpline!);
      } else {
        if (_activeSpline!.nodes.isNotEmpty && _activeSpline!.nodes.first.point == tappedPoint) {
          widget.engine.toggleSplineClosed(_activeSpline!);
          setState(() {
            _activeSpline = null;
            _currentTool = CompassTool.select;
          });
        } else {
          final node = CompassSplineNode(point: tappedPoint, tension: 1.0);
          node.tension.addListener(widget.engine.notifyListeners);
          _activeSpline!.addNode(node);
          widget.engine.notifyListeners();
        }
      }
    }
    else if (_currentTool == CompassTool.addLine || _currentTool == CompassTool.addCircle || _currentTool == CompassTool.addSpiral) {
      
      if (isShiftPressed) {
        final quickOffset = 100 / _canvasScale; 
        if (_currentTool == CompassTool.addLine) {
          final p1 = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final p2 = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy + quickOffset);
          widget.engine.addPoint(p1);
          widget.engine.addPoint(p2);
          widget.engine.addShape(CompassLine(start: p1, end: p2));
        } else if (_currentTool == CompassTool.addCircle) {
          final center = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final radiusPoint = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy);
          widget.engine.addPoint(center);
          widget.engine.addPoint(radiusPoint);
          
          center.attach(radiusPoint); 

          final circle = CompassCircle(center: center, radiusPoint: radiusPoint, radius: 0);
          DistanceRadiusConstraint(
            p1: center,
            p2: radiusPoint,
            targetRadius: circle.radius,
          );
          widget.engine.addShape(circle);
        } else if (_currentTool == CompassTool.addSpiral) {
          final center = CompassPoint(x: logicalPosition.dx, y: logicalPosition.dy);
          final startPoint = CompassPoint(x: logicalPosition.dx + quickOffset, y: logicalPosition.dy);
          widget.engine.addPoint(center);
          widget.engine.addPoint(startPoint);
          
          center.attach(startPoint);

          final spiral = CompassSpiral(center: center, startPoint: startPoint);
          widget.engine.addShape(spiral);
        }
        
        setState(() {
          _shapeStartPoint = null;
        });
        return; 
      }

      CompassPoint? tappedPoint;
      
      if (_hoveredPoint != null) {
        tappedPoint = _hoveredPoint;
      } else {
        final scaledThreshold = _hitThreshold / _canvasScale;
        for (var point in widget.engine.points) {
          if (_isPointLocked(point)) continue; // SKIP LOCKED

          final distance = sqrt(
            pow(point.x.value - logicalPosition.dx, 2) +
            pow(point.y.value - logicalPosition.dy, 2),
          );

          if (distance < scaledThreshold) {
            tappedPoint = point;
            break; 
          }
        }
      }

      if (tappedPoint == null) {
        tappedPoint = CompassPoint(
          x: logicalPosition.dx,
          y: logicalPosition.dy,
        );
        widget.engine.addPoint(tappedPoint);
      }

      if (_shapeStartPoint == null) {
        setState(() {
          _shapeStartPoint = tappedPoint;
        });
      } else {
        if (_shapeStartPoint != tappedPoint) {
          if (_currentTool == CompassTool.addLine) {
            widget.engine.addShape(CompassLine(
              start: _shapeStartPoint!,
              end: tappedPoint!,
            ));
          } else if (_currentTool == CompassTool.addCircle) {
            final circle = CompassCircle(center: _shapeStartPoint!, radiusPoint: tappedPoint!, radius: 0);
            _shapeStartPoint!.attach(tappedPoint!);

            DistanceRadiusConstraint(
              p1: _shapeStartPoint!,
              p2: tappedPoint!,
              targetRadius: circle.radius,
            );
            
            widget.engine.addShape(circle);
          } else if (_currentTool == CompassTool.addSpiral) {
            final spiral = CompassSpiral(center: _shapeStartPoint!, startPoint: tappedPoint!);
            _shapeStartPoint!.attach(tappedPoint!);
            widget.engine.addShape(spiral);
          }
        }
        setState(() {
          _shapeStartPoint = null;
        });
      }
    }
  }

  void _onPanStart(DragStartDetails details) {
    if (_currentTool != CompassTool.select) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = _getLogicalPosition(localPosition);

    _lastPanPosition = logicalPosition;

    setState(() {
      _hoverPosition = logicalPosition; 
    });

    // 0. Check if we are initiating a Rotation
    if ((_isRPressed || _isShiftRPressed) && _rotationPivotOffset != null) {
      _isRotating = true;
      for (var p in _transformingPoints) p.isBeingDragged = true;
      return; 
    }

    // 0.5 Check if we are initiating a Shape Pan (Shift)
    if (_isShiftPressed && !_isRPressed && !_isShiftRPressed && !_isAPressed) {
      _transformingPoints = _getRigidBody(widget.engine.selectedShape, _selectedPoint ?? _hoveredPoint, true);
      if (_transformingPoints.isNotEmpty) {
        _isPanningShape = true;
        for (var p in _transformingPoints) p.isBeingDragged = true;
        return;
      }
    }

    // 0.75 NEW: Global Tension Edit
    if (_isAPressed && _targetTensionNode != null) {
      _activeTensionNode = _targetTensionNode;
      return;
    }

    // 1. Check for Mocha-style Tension Handle drag
    final selectedShape = widget.engine.selectedShape;
    if (selectedShape is CompassXSpline && widget.showScaffolding) {
       for (var node in selectedShape.nodes) {
          final pt = Offset(node.point.x.value, node.point.y.value);
          final handlePt = pt + const Offset(20, -30); 
          final dist = (logicalPosition - handlePt).distance;
          
          if (dist < (15.0 / _canvasScale)) {
            _activeTensionNode = node;
            return; 
          }
       }
    }

    // 2. Fall back to standard single point dragging
    final scaledThreshold = _hitThreshold / _canvasScale;
    for (var point in widget.engine.points) {
      if (_isPointLocked(point)) continue; // SKIP LOCKED

      final distance = sqrt(
        pow(point.x.value - logicalPosition.dx, 2) +
        pow(point.y.value - logicalPosition.dy, 2),
      );

      if (distance < scaledThreshold) {
        _activePoint = point;
        _activePoint!.isBeingDragged = true; 
        
        setState(() => _selectedPoint = point);
        break; 
      }
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_currentTool != CompassTool.select || _lastPanPosition == null) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final localPosition = renderBox.globalToLocal(details.globalPosition);
    final logicalPosition = _getLogicalPosition(localPosition);
    
    setState(() {
      _hoverPosition = logicalPosition; 
    });

    final dx = logicalPosition.dx - _lastPanPosition!.dx;
    final dy = logicalPosition.dy - _lastPanPosition!.dy;

    // 0a. If Rotating (rigid body mode)
    if (_isRotating && _rotationPivotOffset != null) {
      final pivot = _rotationPivotOffset!;
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
      
      _lastPanPosition = logicalPosition;
      return;
    }

    // 0b. If Panning Shape (rigid body mode)
    if (_isPanningShape) {
      for (var p in _transformingPoints) {
        p.x.value += dx;
        p.y.value += dy;
      }
      _lastPanPosition = logicalPosition;
      return;
    }

    // 1. If dragging a tension handle (or global tension with A key)
    if (_activeTensionNode != null) {
       if (_isAPressed) {
         // Absolute distance-based tension (like rotation)
         final nodePos = Offset(_activeTensionNode!.point.x.value, _activeTensionNode!.point.y.value);
         final dist = (logicalPosition - nodePos).distance;
         
         // 100 logical pixels = 1.0 tension (standard Catmull-Rom)
         double newTension = dist * 0.01;
         
         _activeTensionNode!.tension.value = max(0.0, newTension);
       } else {
         // Local handle drag delta
         final physicalDy = details.delta.dy; 
         final tensionDelta = -physicalDy * 0.005; 
         double newTension = _activeTensionNode!.tension.value + tensionDelta;
         
         _activeTensionNode!.tension.value = max(0.0, newTension);
       }
    } 
    // 2. If dragging a single point (standard translation)
    else if (_activePoint != null) {
      _activePoint!.moveBy(dx, dy);
    } 
    // 3. If dragging the reference layer
    else if (widget.engine.referenceLayer != null && !widget.engine.referenceLayer!.isLocked) {
      widget.engine.updateReferenceTransform(Offset(dx * _canvasScale, dy * _canvasScale), 0, 0);
    }

    _lastPanPosition = logicalPosition;
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isRotating || _isPanningShape) {
      _isRotating = false;
      _isPanningShape = false;
      for (var p in _transformingPoints) p.isBeingDragged = false;
      widget.engine.finalizePointDrag(); 
    } else if (_activeTensionNode != null) {
      _activeTensionNode = null;
      widget.engine.finalizePointDrag(); 
    } else if (_activePoint != null) {
      _activePoint!.isBeingDragged = false; 
      widget.engine.finalizePointDrag();
    }
    _activePoint = null;
    _lastPanPosition = null;
  }
  
  void _onPanCancel() {
    if (_isRotating || _isPanningShape) {
      _isRotating = false;
      _isPanningShape = false;
      for (var p in _transformingPoints) p.isBeingDragged = false;
    }
    _activeTensionNode = null;
    _activePoint?.isBeingDragged = false; 
    _activePoint = null;
    _lastPanPosition = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Stack(
      children: [
        // --- INTERACTIVE CANVAS LAYER ---
        Listener(
          onPointerDown: (event) {
            if (event.buttons == kMiddleMouseButton) {
              setState(() {
                _isPanningCanvas = true;
              });
            }
          },
          onPointerMove: (event) {
            if (_isPanningCanvas) {
              setState(() {
                _panOffset += event.delta;
              });
            }
          },
          onPointerUp: (event) {
            if (_isPanningCanvas) {
              setState(() {
                _isPanningCanvas = false;
              });
            }
          },
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              final isRefUnlocked = widget.engine.referenceLayer != null && !widget.engine.referenceLayer!.isLocked;
              
              if (isRefUnlocked) {
                final double zoomDelta = event.scrollDelta.dy > 0 ? -0.1 : 0.1;
                widget.engine.updateReferenceTransform(Offset.zero, zoomDelta, 0);
              } else {
                final RenderBox renderBox = context.findRenderObject() as RenderBox;
                final localPosition = renderBox.globalToLocal(event.position);
                
                final logicalPoint = _getLogicalPosition(localPosition);
                
                final double zoomFactor = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
                double newScale = _canvasScale * zoomFactor;
                newScale = newScale.clamp(0.05, 50.0); 
                
                setState(() {
                  _canvasScale = newScale;
                  _panOffset = localPosition - logicalPoint * _canvasScale;
                });
              }
            }
          },
          child: MouseRegion(
            onHover: _onHover,
            onExit: (_) => setState(() {
              _hoverPosition = null;
              _hoveredPoint = null;
            }),
            cursor: _isPanningCanvas
                ? SystemMouseCursors.move
                : (_targetTensionNode != null && _isAPressed
                    ? SystemMouseCursors.resizeUpRight
                    : (_hoveredPoint != null 
                        ? SystemMouseCursors.precise 
                        : SystemMouseCursors.basic)),
            child: GestureDetector(
              onTapDown: _onTapDown,
              onSecondaryTapDown: _onSecondaryTapDown, 
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              onPanCancel: _onPanCancel,
              child: Container(
                color: Colors.transparent, 
                width: double.infinity,
                height: double.infinity,
                child: CustomPaint(
                  painter: CompassRenderer(
                    engine: widget.engine,
                    selectedPoint: _selectedPoint,     
                    rotationPivotOffset: _rotationPivotOffset,     
                    isRPressed: _isRPressed,           
                    isShiftRPressed: _isShiftRPressed,
                    isAPressed: _isAPressed, // NEW
                    tensionTargetPoint: _targetTensionNode?.point, // NEW
                    shapeStartPoint: _shapeStartPoint, 
                    hoveredPoint: _hoveredPoint,
                    hoverPosition: _hoverPosition,
                    currentTool: _currentTool,
                    showScaffolding: widget.showScaffolding,
                    panOffset: _panOffset,
                    canvasScale: _canvasScale,
                    pointBorderColor: theme.colorScheme.surface, 
                  ),
                ),
              ),
            ),
          ),
        ),

        // --- HUD / UI OVERLAYS ---
        Positioned.fill(
          child: CanvasHUD(
            engine: widget.engine,
            showScaffolding: widget.showScaffolding,
            currentTool: _currentTool,
            onToolSelected: (tool) {
              setState(() {
                _currentTool = tool;
                _activePoint = null;
                _selectedPoint = null; 
                _shapeStartPoint = null; 
                _activeSpline = null;
              });
            },
            isRPressed: _isRPressed,
            isShiftRPressed: _isShiftRPressed,
            isShiftPressed: _isShiftPressed,
            isAPressed: _isAPressed, 
            panOffset: _panOffset,
            canvasScale: _canvasScale,
          ),
        ),
      ],
    );
  }
}