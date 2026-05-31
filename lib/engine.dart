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
    // Cannot explicitly select a locked layer, but we can tap it in the UI to expand/collapse.
    // If it's locked, we just won't make it the 'activeLayer' for adding new shapes.
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

  // --- NEW: Toggle Layer Lock ---
  void toggleLayerLock(CompassLayer layer) {
    layer.isLocked = !layer.isLocked;
    
    // If we lock the active layer, try to find an unlocked one to make active
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
    
    // If we lock a layer that has the selected shape, deselect it
    if (layer.isLocked && _selectedShape != null && layer.shapes.contains(_selectedShape)) {
      _selectedShape = null;
    }
    
    _saveSnapshot();
    notifyListeners();
  }

  void selectShape(CompassShape? shape) {
    if (shape != null) {
      // Prevent selecting a shape if its parent layer is locked
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
    // 1. Gather all points that belong to the shape being deleted
    List<CompassPoint> shapePoints = [];
    if (shape is CompassLine) {
      shapePoints = [shape.start, shape.end];
    } else if (shape is CompassCircle) {
      shapePoints = [shape.center];
      if (shape.radiusPoint != null) shapePoints.add(shape.radiusPoint!);
    } else if (shape is CompassSpiral) {
      shapePoints = [shape.center, shape.startPoint];
    } else if (shape is CompassXSpline) {
      shapePoints = shape.nodes.map((n) => n.point).toList();
      if (shape.anchorPoint != null) shapePoints.add(shape.anchorPoint!);
    }

    // 2. Remove the shape from the layers
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

    // 3. Garbage Collect orphaned points safely
    if (removed) {
      for (var p in shapePoints) {
        _checkAndGCPoint(p);
      }
      
      _saveSnapshot();
      notifyListeners();
    }
  }

  /// Safely destroys a point ONLY if no shapes are rendering it 
  /// AND no other points are mathematically dependent on it.
  void _checkAndGCPoint(CompassPoint p) {
    bool isUsed = false;
    for (var layer in layers) {
      for (var s in layer.shapes) {
        if (s is CompassLine && (s.start == p || s.end == p)) isUsed = true;
        else if (s is CompassCircle && (s.center == p || s.radiusPoint == p)) isUsed = true;
        else if (s is CompassSpiral && (s.center == p || s.startPoint == p)) isUsed = true;
        else if (s is CompassXSpline && (s.nodes.any((n) => n.point == p) || s.anchorPoint == p)) isUsed = true;
        
        if (isUsed) break;
      }
      if (isUsed) break;
    }

    if (!isUsed) {
      // Don't delete if it is a parent or a child in a rigid body constraint
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

  /// Converts a parametric circle into an editable X-Spline, 
  /// retaining its center point constraints and boolean ops.
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
    // Mathematically calculated tension to perfectly approximate a circle with 8 Catmull-Rom nodes
    const double circleTension = 1.124; 

    for (int i = 0; i < numNodes; i++) {
      final angle = (i * 2 * pi) / numNodes;
      final px = cx + r * cos(angle);
      final py = cy + r * sin(angle);
      
      final p = CompassPoint(x: px, y: py);
      points.add(p);
      p.x.addListener(notifyListeners);
      p.y.addListener(notifyListeners);
      
      // Attach to original center! If the user moves the center point, the new spline moves with it.
      circle.center.attach(p);

      final node = CompassSplineNode(point: p, tension: circleTension);
      node.tension.addListener(notifyListeners);
      spline.addNode(node);
    }

    // Swap the shape in the exact layer position
    targetLayer.shapes[shapeIndex] = spline;
    
    if (_selectedShape == circle) {
      _selectedShape = spline;
    }

    // Attempt to garbage collect old points. 
    // The center point will SURVIVE automatically because it now has 8 children attached to it!
    if (circle.radiusPoint != null) {
      // FIX: Sever the specific parent-child relationship so the GC is allowed to delete it.
      circle.center.detach(circle.radiusPoint!);
      _checkAndGCPoint(circle.radiusPoint!);
    }
    // We intentionally DO NOT check the center point for GC anymore, because we explicitly transferred it to the spline.

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
    final index = spline.getInsertIndexForOffset(tap);
    final node = CompassSplineNode(point: p);
    node.tension.addListener(notifyListeners);
    
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
        } else if (shape is CompassXSpline) {
          shape.nodes.removeWhere((n) => n.point == p);
          // Destroy the spline if it doesn't have enough points left to form a path
          if (shape.nodes.length < 2) {
             // Let GC try to clean up the anchor point if the shape is destroyed
             if (shape.anchorPoint != null) {
                // Detach everything so the anchor isn't artificially holding onto ghost nodes
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

  // =========================================
  // DELEGATED IO SYSTEM
  // =========================================

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