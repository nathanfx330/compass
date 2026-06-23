// lib/ui/canvas/canvas_context_menus.dart

import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/spiral.dart';

import '../workspace/dialogs.dart';
import 'canvas_controller.dart'; 

class CanvasContextMenus {
  /// Shows the width constraint toggle menu when right-clicking a width handle (W key)
  static Future<void> showWidthConstraintMenu(
    BuildContext context, 
    CompassEngine engine, 
    Offset globalPos, 
    CompassXSpline spline, 
    CompassSplineNode node, 
    bool isLeft
  ) async {
    final isPinned = isLeft ? node.isLeftWidthPinned : node.isRightWidthPinned;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy),
      items: [
        PopupMenuItem(
          value: 'toggle',
          child: Text(isPinned ? 'Remove Width Constraint' : 'Set Width Constraint Flag'),
        )
      ]
    );
    if (selected == 'toggle') {
      engine.setWidthConstraint(spline, node, isLeft, !isPinned);
    }
  }

  /// Handles the massive right-click contextual menu for Points, Shapes, and the background canvas.
  static Future<void> handleSecondaryTap({
    required BuildContext context,
    required CompassEngine engine,
    required CanvasController controller,
    required Offset globalPosition,
    required Offset logicalPosition,
    required CompassPoint? clickedPoint,
    required CompassShape? clickedShape,
    required bool showScaffolding,
    required VoidCallback onToggleScaffolding,
    required bool showHandles,
    required VoidCallback onToggleHandles,
  }) async {
    final RelativeRect position = RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      globalPosition.dx,
      globalPosition.dy,
    );

    // ==========================================
    // 1. POINT CONTEXT MENU
    // ==========================================
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
            child: Text('Reset Handles (Make Fluid)'), 
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
        controller.removePointFromSelection(clickedPoint);
      } else if (selectedAction == 'reset_handles') {
        engine.resetPointHandles(clickedPoint);
      } else if (selectedAction == 'convert_to_bezier') {
        engine.convertPointToBezier(clickedPoint);
      } else if (selectedAction == 'fillet_corner' && parentSpline != null && clickedNode != null) {
        CompassDialogs.showFilletDialog(context, engine, parentSpline, clickedNode);
      } else if (selectedAction == 'toggle_closed' && parentSpline != null) {
        engine.toggleSplineClosed(parentSpline);
      } else if (selectedAction == 'start_spline') {
        controller.startSplineFrom(clickedPoint);
      } else if (selectedAction == 'start_circle') {
        controller.startCircleFrom(clickedPoint);
      }
    } 
    // ==========================================
    // 2. SHAPE CONTEXT MENU
    // ==========================================
    else if (clickedShape != null) {
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
    } 
    // ==========================================
    // 3. EMPTY CANVAS CONTEXT MENU
    // ==========================================
    else {
      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: [
          PopupMenuItem(
            value: 'toggle_scaffolding', 
            child: Text(showScaffolding ? 'Hide Scaffolding (Clean View)' : 'Show Scaffolding'),
          ), 
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
}