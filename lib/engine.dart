// lib/engine.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math';
import 'package:flutter/material.dart';

// --- DATA MODELS ---
import 'models/geometry/point.dart';
import 'models/geometry/shape.dart';
import 'models/geometry/line.dart';
import 'models/geometry/circle.dart';
import 'models/geometry/spiral.dart';
import 'models/geometry/spline.dart';
import 'models/geometry/rectangle.dart';
import 'models/layer.dart';
import 'models/reference_layer.dart';

// --- IO ---
import 'io/project_serializer.dart';
import 'io/svg_exporter.dart';

/// The state holder and brain of the application.
class CompassEngine extends ChangeNotifier {
  final List<CompassPoint> points = [];
  final List<CompassLayer> layers = [];
  
  CompassLayer? activeLayer;
  CompassShape? _selectedShape;

  CompassReferenceLayer? referenceLayer;

  // --- UNDO STACK ---
  final List<String> _undoStack = [];
  bool _isRestoring = false; 

  CompassEngine() {
    addLayer('Layer 1');
    _saveSnapshot(); 
  }

  CompassShape? get selectedShape => _selectedShape;

  void _saveSnapshot() {
    if (_isRestoring) return;
    
    final currentData = toProjectData();
    if (_undoStack.isEmpty || _undoStack.last != currentData) {
      _undoStack.add(currentData);
      if (_undoStack.length > 50) {
        _undoStack.removeAt(0);
      }
    }
  }

  void undo() {
    if (_undoStack.length > 1) {
      _isRestoring = true; 
      _undoStack.removeLast(); 
      final previousState = _undoStack.last; 
      
      loadProjectData(previousState);
      
      _isRestoring = false;
      notifyListeners();
    }
  }

  Future<void> loadReferenceImage(String path) async {
    try {
      final file = File(path);
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frameInfo = await codec.getNextFrame();
      
      referenceLayer = CompassReferenceLayer(imagePath: path);
      referenceLayer!.image = frameInfo.image;
      
      referenceLayer!.offset = Offset(-frameInfo.image.width / 2, -frameInfo.image.height / 2);
      
      _saveSnapshot();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load reference image: $e');
    }
  }

  void removeReferenceLayer() {
    referenceLayer = null;
    _saveSnapshot();
    notifyListeners();
  }

  void toggleReferenceLock() {
    if (referenceLayer != null) {
      referenceLayer!.isLocked = !referenceLayer!.isLocked;
      notifyListeners();
    }
  }

  void toggleReferenceVisibility() {
    if (referenceLayer != null) {
      referenceLayer!.isVisible = !referenceLayer!.isVisible;
      notifyListeners();
    }
  }

  void updateReferenceTransform(Offset deltaOffset, double deltaScale, double deltaRotation) {
    if (referenceLayer != null && !referenceLayer!.isLocked) {
      referenceLayer!.offset += deltaOffset;
      referenceLayer!.scale += deltaScale;
      referenceLayer!.rotation += deltaRotation;
      notifyListeners();
    }
  }

  void addLayer(String name) {
    final newLayer = CompassLayer(name: name);
    layers.add(newLayer);
    activeLayer = newLayer; 
    _selectedShape = null;
    _saveSnapshot();
    notifyListeners();
  }

  void removeLayer(CompassLayer layer) {
    layers.remove(layer);
    
    if (activeLayer == layer) {
      activeLayer = layers.isNotEmpty ? layers.first : null;
    }

    if (_selectedShape != null && layer.shapes.contains(_selectedShape)) {
      _selectedShape = null;
    }

    if (layers.isEmpty) {
      final newLayer = CompassLayer(name: 'Layer 1');
      layers.add(newLayer);
      activeLayer = newLayer;
    }

    _saveSnapshot();
    notifyListeners();
  }

  void selectLayer(CompassLayer layer) {
    if (!layer.isLocked) {
      activeLayer = layer;
      _selectedShape = null; 
      notifyListeners();
    }
  }
  
  void toggleLayerExpanded(CompassLayer layer) {
    layer.isExpanded = !layer.isExpanded;
    notifyListeners();
  }

  void toggleLayerLock(CompassLayer layer) {
    layer.isLocked = !layer.isLocked;
    
    if (layer.isLocked && activeLayer == layer) {
       _selectedShape = null;
       activeLayer = null;
       for (var l in layers) {
         if (!l.isLocked) {
           activeLayer = l;
           break;
         }
       }
    }
    
    if (layer.isLocked && _selectedShape != null && layer.shapes.contains(_selectedShape)) {
      _selectedShape = null;
    }
    
    _saveSnapshot();
    notifyListeners();
  }

  void selectShape(CompassShape? shape) {
    if (shape != null) {
      for (var layer in layers) {
        if (layer.shapes.contains(shape)) {
          if (layer.isLocked) return; 
          
          activeLayer = layer;
          layer.isExpanded = true; 
          break;
        }
      }
    }
    _selectedShape = shape;
    notifyListeners();
  }

  void removeShape(CompassShape shape) {
    List<CompassPoint> shapePoints = [];
    if (shape is CompassLine) {
      shapePoints = [shape.start, shape.end];
    } else if (shape is CompassCircle) {
      shapePoints = [shape.center];
      if (shape.radiusPoint != null) shapePoints.add(shape.radiusPoint!);
    } else if (shape is CompassSpiral) {
      shapePoints = [shape.center, shape.startPoint];
    } else if (shape is CompassRectangle) { 
      shapePoints = [shape.p1, shape.p2];
    } else if (shape is CompassXSpline) {
      shapePoints = shape.nodes.map((n) => n.point).toList();
      if (shape.anchorPoint != null) shapePoints.add(shape.anchorPoint!);
    }

    bool removed = false;
    for (var layer in layers) {
      if (layer.shapes.remove(shape)) {
        if (_selectedShape == shape) {
          _selectedShape = null;
        }
        removed = true;
        break;
      }
    }

    if (removed) {
      for (var p in shapePoints) {
        _checkAndGCPoint(p);
      }
      
      _saveSnapshot();
      notifyListeners();
    }
  }

  void _checkAndGCPoint(CompassPoint p) {
    bool isUsed = false;
    for (var layer in layers) {
      for (var s in layer.shapes) {
        if (s is CompassLine && (s.start == p || s.end == p)) isUsed = true;
        else if (s is CompassCircle && (s.center == p || s.radiusPoint == p)) isUsed = true;
        else if (s is CompassSpiral && (s.center == p || s.startPoint == p)) isUsed = true;
        else if (s is CompassRectangle && (s.p1 == p || s.p2 == p)) isUsed = true; 
        else if (s is CompassXSpline && (s.nodes.any((n) => n.point == p) || s.anchorPoint == p)) isUsed = true;
        
        if (isUsed) break;
      }
      if (isUsed) break;
    }

    if (!isUsed) {
      bool hasDependencies = p.attachedPoints.isNotEmpty;
      for (var other in points) {
        if (other.attachedPoints.contains(p)) {
          hasDependencies = true;
          break;
        }
      }

      if (!hasDependencies) {
        points.remove(p);
        for (var remainingPoint in points) {
          remainingPoint.attachedPoints.remove(p);
        }
      }
    }
  }

  void convertCircleToSpline(CompassCircle circle) {
    CompassLayer? targetLayer;
    int shapeIndex = -1;
    for (var layer in layers) {
      shapeIndex = layer.shapes.indexOf(circle);
      if (shapeIndex != -1) {
        targetLayer = layer;
        break;
      }
    }
    
    if (targetLayer == null) return;

    final spline = CompassXSpline(isClosed: true, anchorPoint: circle.center)
      ..operation = circle.operation
      ..isVisible = circle.isVisible;

    final cx = circle.center.x.value;
    final cy = circle.center.y.value;
    final r = circle.radius.value;

    const int numNodes = 8;
    const double circleTension = 1.124; 

    for (int i = 0; i < numNodes; i++) {
      final angle = (i * 2 * pi) / numNodes;
      final px = cx + r * cos(angle);
      final py = cy + r * sin(angle);
      
      final p = CompassPoint(x: px, y: py);
      points.add(p);
      p.x.addListener(notifyListeners);
      p.y.addListener(notifyListeners);
      
      circle.center.attach(p);

      final node = CompassSplineNode(point: p, tension: circleTension);
      node.tension.addListener(notifyListeners);
      spline.addNode(node);
    }

    targetLayer.shapes[shapeIndex] = spline;
    
    if (_selectedShape == circle) {
      _selectedShape = spline;
    }

    if (circle.radiusPoint != null) {
      circle.center.detach(circle.radiusPoint!);
      _checkAndGCPoint(circle.radiusPoint!);
    }

    _saveSnapshot();
    notifyListeners();
  }

  // --- Convert Rectangle to Spline (exact circular-arc corners) ---
  void convertRectangleToSpline(CompassRectangle rect) {
    CompassLayer? targetLayer;
    int shapeIndex = -1;
    for (var layer in layers) {
      shapeIndex = layer.shapes.indexOf(rect);
      if (shapeIndex != -1) {
        targetLayer = layer;
        break;
      }
    }
    
    if (targetLayer == null) return;

    final cx = (rect.p1.x.value + rect.p2.x.value) / 2;
    final cy = (rect.p1.y.value + rect.p2.y.value) / 2;
    final anchor = CompassPoint(x: cx, y: cy);
    points.add(anchor);
    anchor.x.addListener(notifyListeners);
    anchor.y.addListener(notifyListeners);

    final spline = CompassXSpline(isClosed: true, anchorPoint: anchor)
      ..operation = rect.operation
      ..isVisible = rect.isVisible;

    final left = min(rect.p1.x.value, rect.p2.x.value);
    final right = max(rect.p1.x.value, rect.p2.x.value);
    final top = min(rect.p1.y.value, rect.p2.y.value);
    final bottom = max(rect.p1.y.value, rect.p2.y.value);
    
    final width = right - left;
    final height = bottom - top;
    final maxR = min(width / 2, height / 2);
    final r = rect.cornerRadius.value.clamp(0.0, maxR);

    void addNodeAt(Offset pos, {required double tension, Offset? handleIn, Offset? handleOut}) {
      final p = CompassPoint(x: pos.dx, y: pos.dy);
      points.add(p);
      p.x.addListener(notifyListeners);
      p.y.addListener(notifyListeners);
      anchor.attach(p);

      final node = CompassSplineNode(point: p, tension: tension, handleIn: handleIn, handleOut: handleOut);
      node.tension.addListener(notifyListeners);
      spline.addNode(node);
    }

    if (r <= 0.1) {
      final corners = [
        Offset(left, top),
        Offset(right, top),
        Offset(right, bottom),
        Offset(left, bottom),
      ];
      for (final c in corners) {
        addNodeAt(c, tension: 0.0);
      }
    } else {
      final k = 0.5522847498307936 * r; 

      final spec = <(Offset, Offset)>[
        (Offset(left + r, top),     Offset(k, 0)),   
        (Offset(right - r, top),    Offset(k, 0)),   
        (Offset(right, top + r),    Offset(0, k)),   
        (Offset(right, bottom - r), Offset(0, k)),   
        (Offset(right - r, bottom), Offset(-k, 0)),  
        (Offset(left + r, bottom),  Offset(-k, 0)),  
        (Offset(left, bottom - r),  Offset(0, -k)),  
        (Offset(left, top + r),     Offset(0, -k)),  
      ];

      for (final (pos, hOut) in spec) {
        // Because the corner arcs are perfectly symmetric, HandleIn is always -HandleOut
        addNodeAt(pos, tension: 1.0, handleOut: hOut, handleIn: Offset(-hOut.dx, -hOut.dy));
      }
    }

    targetLayer.shapes[shapeIndex] = spline;
    
    if (_selectedShape == rect) {
      _selectedShape = spline;
    }

    _checkAndGCPoint(rect.p1);
    _checkAndGCPoint(rect.p2);

    _saveSnapshot();
    notifyListeners();
  }
  
  void toggleShapeVisibility(CompassShape shape) {
    shape.isVisible = !shape.isVisible;
    if (!shape.isVisible && _selectedShape == shape) {
      _selectedShape = null; // Deselect if hidden
    }
    _saveSnapshot();
    notifyListeners();
  }

  void updateSpiral(CompassSpiral spiral, {bool? isClockwise, double? revolutions}) {
    if (isClockwise != null) spiral.isClockwise = isClockwise;
    if (revolutions != null) spiral.revolutions = revolutions;
    _saveSnapshot();
    notifyListeners();
  }

  void updateRectangleRadius(CompassRectangle rect, double radius) {
    rect.cornerRadius.value = radius;
    _saveSnapshot();
    notifyListeners();
  }

  void toggleRectangleSquare(CompassRectangle rect, bool isSquare) {
    rect.isSquare = isSquare;
    if (isSquare) {
      rect.p2.moveBy(0, 0); 
    }
    _saveSnapshot();
    notifyListeners();
  }

  void changeShapeOperation(CompassShape shape, CompassBooleanOp op) {
    shape.operation = op;
    _saveSnapshot();
    notifyListeners();
  }

  void changeLayerColor(CompassLayer layer, Color newColor) {
    layer.color = newColor;
    _saveSnapshot();
    notifyListeners();
  }

  void changeLayerStrokeColor(CompassLayer layer, Color newColor) {
    layer.strokeColor = newColor;
    _saveSnapshot();
    notifyListeners();
  }

  void changeLayerStrokeWidth(CompassLayer layer, double width) {
    layer.strokeWidth = width;
    _saveSnapshot();
    notifyListeners();
  }

  // --- SPLINE SPECIFIC ENGINE ACTIONS ---

  void insertPointIntoSpline(CompassPoint p, CompassXSpline spline) {
    final tap = Offset(p.x.value, p.y.value);
    final details = spline.getInsertDetailsForOffset(tap);
    final index = details.$1;
    final t = details.$2;

    final node = CompassSplineNode(point: p);
    node.tension.addListener(notifyListeners);
    
    // De Casteljau exact subdivision for Bezier curves
    if ((index > 0 && index < spline.nodes.length) || (spline.isClosed && index == spline.nodes.length)) {
      final prevIdx = index - 1;
      final nextIdx = index == spline.nodes.length ? 0 : index;
      
      final prevNode = spline.nodes[prevIdx];
      final nextNode = spline.nodes[nextIdx];
      
      final controls = spline.getEvaluatedControls();
      final hOut = controls[prevIdx].$1;
      final hIn = controls[nextIdx].$2;

      final p0 = Offset(prevNode.point.x.value, prevNode.point.y.value);
      final p3 = Offset(nextNode.point.x.value, nextNode.point.y.value);

      final p1 = p0 + hOut;
      final p2 = p3 + hIn;

      // 1st order
      final m0 = Offset.lerp(p0, p1, t)!;
      final m1 = Offset.lerp(p1, p2, t)!;
      final m2 = Offset.lerp(p2, p3, t)!;
      // 2nd order
      final r0 = Offset.lerp(m0, m1, t)!;
      final r1 = Offset.lerp(m1, m2, t)!;
      // 3rd order (Point on curve)
      final b = Offset.lerp(r0, r1, t)!;

      // Force user's dropped point to snap exactly to the mathematical split
      p.x.value = b.dx;
      p.y.value = b.dy;

      // Safely divide by tension to prevent double-scaling when saving back to explicit fields.
      // (Because getEvaluatedControls() already applies the tension multiplier).
      Offset safeDivide(Offset v, double tension) {
        return tension > 0.001 ? Offset(v.dx / tension, v.dy / tension) : Offset.zero;
      }

      // Solidify and truncate neighbor handles (baking Catmull-Rom into Explicit if needed)
      prevNode.handleIn ??= safeDivide(controls[prevIdx].$2, prevNode.tension.value);
      prevNode.handleOut = safeDivide(m0 - p0, prevNode.tension.value);

      nextNode.handleOut ??= safeDivide(controls[nextIdx].$1, nextNode.tension.value);
      nextNode.handleIn = safeDivide(m2 - p3, nextNode.tension.value);

      // Assign the new asymmetric handles to the inserted node
      node.handleIn = safeDivide(r0 - b, node.tension.value);
      node.handleOut = safeDivide(r1 - b, node.tension.value);
    }

    if (index >= spline.nodes.length) {
      spline.nodes.add(node);
    } else {
      spline.nodes.insert(index, node);
    }

    if (spline.nodes.isNotEmpty) {
      final firstPoint = spline.nodes.first.point;
      if (firstPoint != p) {
        firstPoint.attach(p);
      }
    }
    
    _saveSnapshot();
    notifyListeners();
  }

  void toggleSplineClosed(CompassXSpline spline) {
    spline.isClosed = !spline.isClosed;
    _saveSnapshot();
    notifyListeners();
  }

  // Escape hatch: clears explicit baked Bezier handles, restoring standard Catmull-Rom math.
  void resetPointHandles(CompassPoint p) {
    bool changed = false;
    for (var layer in layers) {
      if (layer.isLocked) continue;
      for (var shape in layer.shapes) {
        if (shape is CompassXSpline) {
          for (var node in shape.nodes) {
            if (node.point == p) {
              if (node.handleIn != null || node.handleOut != null) {
                node.handleIn = null;
                node.handleOut = null;
                changed = true;
              }
            }
          }
        }
      }
    }
    
    if (changed) {
      _saveSnapshot();
      notifyListeners();
    }
  }

  // -------------------------------------

  void addPoint(CompassPoint p) {
    points.add(p);
    p.x.addListener(notifyListeners);
    p.y.addListener(notifyListeners);
    _saveSnapshot();
    notifyListeners();
  }

  void removePoint(CompassPoint p) {
    for (var layer in layers) {
      layer.shapes.removeWhere((shape) {
        if (shape is CompassLine) {
          return shape.start == p || shape.end == p;
        } else if (shape is CompassCircle) {
          return shape.center == p || shape.radiusPoint == p;
        } else if (shape is CompassSpiral) {
          return shape.center == p || shape.startPoint == p;
        } else if (shape is CompassRectangle) {
          return shape.p1 == p || shape.p2 == p;
        } else if (shape is CompassXSpline) {
          shape.nodes.removeWhere((n) => n.point == p);
          if (shape.nodes.length < 2) {
             if (shape.anchorPoint != null) {
                for (var n in shape.nodes) shape.anchorPoint!.detach(n.point);
             }
             return true; 
          }
          return false; 
        }
        return false;
      });
    }
    
    if (_selectedShape != null) {
      bool stillExists = false;
      for (var layer in layers) {
        if (layer.shapes.contains(_selectedShape)) {
          stillExists = true;
          break;
        }
      }
      if (!stillExists) _selectedShape = null;
    }

    points.remove(p);
    _saveSnapshot();
    notifyListeners();
  }

  void addShape(CompassShape s) {
    if (activeLayer != null) {
      activeLayer!.shapes.add(s);
      _selectedShape = s;
      activeLayer!.isExpanded = true;
      _saveSnapshot();
      notifyListeners();
    }
  }

  void finalizePointDrag() {
    _saveSnapshot();
  }

  String toProjectData() {
    return ProjectSerializer.serialize(this);
  }

  void loadProjectData(String data) {
    ProjectSerializer.deserialize(this, data, notifyListeners);
  }

  String toSVG() {
    return SVGExporter.toSVG(this);
  }
}