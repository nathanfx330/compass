// /lib/ui/canvas/canvas_context_menus.dart

import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/mesh.dart';
import '../../models/geometry/gradient.dart';
import '../../models/layer.dart';

import '../widgets/compass_color_picker.dart';
import '../workspace/dialogs.dart';
import 'canvas_controller.dart';

class CanvasContextMenus {
  /// Shows the width constraint toggle menu when right-clicking a width handle.
  static Future<void> showWidthConstraintMenu(
    BuildContext context,
    CompassEngine engine,
    Offset globalPos,
    CompassXSpline spline,
    CompassSplineNode node,
    bool isLeft,
  ) async {
    final isPinned =
        isLeft ? node.isLeftWidthPinned : node.isRightWidthPinned;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        globalPos.dx,
        globalPos.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'toggle',
          child: Text(
            isPinned
                ? 'Remove Width Constraint'
                : 'Set Width Constraint Flag',
          ),
        ),
      ],
    );

    if (selected == 'toggle') {
      engine.setWidthConstraint(
        spline,
        node,
        isLeft,
        !isPinned,
      );
    }
  }

  /// Handles the right-click contextual menu for points, gradient axes, shapes,
  /// and the background canvas.
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
    required bool ghostVertices,
    required VoidCallback onToggleGhostVertices,
  }) async {
    final position = RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      globalPosition.dx,
      globalPosition.dy,
    );

    // The dotted linear-gradient axis is its own context-menu target.
    //
    // Once a gradient has two endpoints, interior stops are created only by
    // right-clicking this line. This prevents arbitrary shape clicks from
    // changing the gradient and ensures every new interior stop begins exactly
    // on the gradient axis.
    CompassShape? clickedGradientAxisShape;
    Offset? gradientAxisInsertPosition;
    Color? gradientAxisInsertColor;

    final selectedGradientShape = engine.selectedShape;
    final selectedGradient = selectedGradientShape?.gradient;

    if (showScaffolding &&
        clickedPoint == null &&
        selectedGradientShape != null &&
        selectedGradient != null &&
        selectedGradient.axis != null) {
      var selectedShapeIsEditable = false;

      for (final layer in engine.layers) {
        if (!layer.isVisible || layer.isLocked) {
          continue;
        }

        if (layer.shapes.contains(selectedGradientShape)) {
          selectedShapeIsEditable = selectedGradientShape.isVisible;
          break;
        }
      }

      if (selectedShapeIsEditable) {
        final projected =
            selectedGradient.projectOntoAxis(logicalPosition);

        final axisHitThreshold =
            12.0 / controller.canvasScale;

        if ((logicalPosition - projected).distance <= axisHitThreshold) {
          clickedGradientAxisShape = selectedGradientShape;
          gradientAxisInsertPosition = projected;

          // Sampling the existing ramp means inserting a stop does not visibly
          // alter the gradient until the user changes that stop's color.
          gradientAxisInsertColor =
              selectedGradient.colorAtPosition(projected);
        }
      }
    }

    // =========================================================================
    // 1. POINT CONTEXT MENU
    // =========================================================================
    if (clickedPoint != null) {
      CompassXSpline? parentSpline;
      CompassSplineNode? clickedNode;
      CompassMesh? parentMesh;

      // The shape whose per-shape gradient owns clickedPoint as a stop.
      //
      // A gradient stop is an ordinary CompassPoint, but it is not a structural
      // spline or mesh vertex. It receives only gradient-specific menu actions.
      CompassShape? gradientStopShape;
      GradientStop? clickedGradientStop;

      for (final layer in engine.layers) {
        if (layer.isLocked) {
          continue;
        }

        for (final shape in layer.shapes) {
          if (shape is CompassXSpline) {
            for (final node in shape.nodes) {
              if (node.point == clickedPoint) {
                parentSpline = shape;
                clickedNode = node;
                break;
              }
            }
          } else if (shape is CompassMesh &&
              shape.containsNode(clickedPoint)) {
            parentMesh = shape;
          }

          final gradient = shape.gradient;

          if (gradient != null) {
            for (final stop in gradient.stops) {
              if (stop.point == clickedPoint) {
                gradientStopShape = shape;
                clickedGradientStop = stop;
                break;
              }
            }
          }

          if (parentSpline != null || parentMesh != null) {
            break;
          }
        }

        if (parentSpline != null || parentMesh != null) {
          break;
        }
      }

      final pointMenuItems = <PopupMenuEntry<String>>[];

      if (gradientStopShape != null &&
          clickedGradientStop != null) {
        final gradient = gradientStopShape.gradient;
        final isBaseStop = gradient != null &&
            identical(clickedGradientStop, gradient.startStop);

        pointMenuItems.add(
          const PopupMenuItem(
            value: 'set_stop_color',
            child: Text('Set Gradient Stop Color…'),
          ),
        );

        // The first stop is the gradient's base geometry handle:
        //
        // - Linear: start of the axis.
        // - Circular: center of the radial gradient.
        //
        // Only this stop exposes the geometry-type choice, keeping the other
        // stop menus focused on color and stop removal.
        if (isBaseStop && gradient != null) {
          pointMenuItems.add(
            const PopupMenuDivider(),
          );

          pointMenuItems.add(
            CheckedPopupMenuItem(
              value: 'gradient_type_linear',
              checked: gradient.type == GradientFillType.linear,
              child: const Text('Linear Gradient'),
            ),
          );

          pointMenuItems.add(
            CheckedPopupMenuItem(
              value: 'gradient_type_circular',
              checked: gradient.type == GradientFillType.circular,
              child: const Text('Circular Gradient'),
            ),
          );

          pointMenuItems.add(
            const PopupMenuDivider(),
          );
        }

        pointMenuItems.add(
          const PopupMenuItem(
            value: 'remove_stop',
            child: Text(
              'Remove Gradient Stop',
              style: TextStyle(color: Colors.red),
            ),
          ),
        );
      } else {
        if (parentMesh != null) {
          pointMenuItems.add(
            const PopupMenuItem(
              value: 'set_mesh_color',
              child: Text('Set Node Color…'),
            ),
          );

          pointMenuItems.add(
            const PopupMenuDivider(),
          );
        }

        if (parentSpline != null) {
          pointMenuItems.add(
            PopupMenuItem(
              value: 'toggle_closed',
              child: Text(
                parentSpline.isClosed
                    ? 'Open Spline'
                    : 'Close Spline (Connect Last to First)',
              ),
            ),
          );

          if (clickedNode != null &&
              (clickedNode.handleIn != null ||
                  clickedNode.handleOut != null)) {
            pointMenuItems.add(
              const PopupMenuItem(
                value: 'reset_handles',
                child: Text('Reset Handles (Make Fluid)'),
              ),
            );
          } else {
            pointMenuItems.add(
              const PopupMenuItem(
                value: 'convert_to_bezier',
                child: Text('Convert to Bézier (Edit Handles)'),
              ),
            );
          }

          if (clickedNode != null) {
            pointMenuItems.add(
              const PopupMenuItem(
                value: 'toggle_corner_circle',
                child: Text(
                  'Bind Corner to Circle (Round Pulley)',
                ),
              ),
            );

            pointMenuItems.add(
              const PopupMenuItem(
                value: 'toggle_corner_miter',
                child: Text(
                  'Bind Corner to Miter (Sharp Pulley)',
                ),
              ),
            );

            pointMenuItems.add(
              const PopupMenuItem(
                value: 'fillet_corner',
                child: Text(
                  'Fillet Corner Dialog (Destructive)...',
                ),
              ),
            );
          }

          pointMenuItems.add(
            const PopupMenuDivider(),
          );
        }

        pointMenuItems.add(
          const PopupMenuItem(
            value: 'start_spline',
            child: Text('Start X-Spline from here'),
          ),
        );

        pointMenuItems.add(
          const PopupMenuItem(
            value: 'start_circle',
            child: Text('Start Circle from here'),
          ),
        );

        pointMenuItems.add(
          const PopupMenuDivider(),
        );

        pointMenuItems.add(
          const PopupMenuItem(
            value: 'delete_point',
            child: Text(
              'Delete Point (and dependent shapes)',
              style: TextStyle(color: Colors.red),
            ),
          ),
        );
      }

      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: pointMenuItems,
      );

      if ((selectedAction == 'gradient_type_linear' ||
              selectedAction == 'gradient_type_circular') &&
          gradientStopShape != null &&
          clickedGradientStop != null) {
        final gradient = gradientStopShape.gradient;
        final isBaseStop = gradient != null &&
            identical(clickedGradientStop, gradient.startStop);

        if (gradient != null && isBaseStop) {
          final nextType =
              selectedAction == 'gradient_type_circular'
                  ? GradientFillType.circular
                  : GradientFillType.linear;

          if (gradient.type != nextType) {
            gradient.type = nextType;
            engine.saveSnapshot();
            engine.notifyListeners();
            controller.notifyListeners();
          }
        }
      } else if (selectedAction == 'set_stop_color' &&
          gradientStopShape != null) {
        Color current = Colors.grey;

        final gradient = gradientStopShape.gradient;

        if (gradient != null) {
          for (final stop in gradient.stops) {
            if (stop.point == clickedPoint) {
              current = stop.color;
              break;
            }
          }
        }

        final picked = await showCompassColorPicker(
          context,
          initialColor: current,
        );

        if (picked != null) {
          engine.setGradientStopColor(
            gradientStopShape,
            clickedPoint,
            picked,
          );
        }
      } else if (selectedAction == 'remove_stop' &&
          gradientStopShape != null) {
        engine.removeGradientStop(
          gradientStopShape,
          clickedPoint,
        );

        controller.removePointFromSelection(clickedPoint);
      } else if (selectedAction == 'set_mesh_color' &&
          parentMesh != null) {
        final current =
            parentMesh.colorForPoint(clickedPoint) ?? Colors.grey;

        final picked = await showCompassColorPicker(
          context,
          initialColor: current,
        );

        if (picked != null) {
          engine.setMeshNodeColor(
            parentMesh,
            clickedPoint,
            picked,
          );
        }
      } else if (selectedAction == 'delete_point') {
        engine.removePoint(clickedPoint);
        controller.removePointFromSelection(clickedPoint);
      } else if (selectedAction == 'reset_handles') {
        engine.resetPointHandles(clickedPoint);
      } else if (selectedAction == 'convert_to_bezier') {
        engine.convertPointToBezier(clickedPoint);
      } else if (selectedAction == 'toggle_corner_circle' &&
          clickedNode != null) {
        if (clickedNode.cornerRadius.value > 0.01) {
          clickedNode.cornerRadius.value = 0.0;
        } else {
          clickedNode.miterSize.value = 0.0;
          clickedNode.cornerRadius.value =
              30.0 / controller.canvasScale;
        }

        engine.saveSnapshot();
        engine.notifyListeners();
      } else if (selectedAction == 'toggle_corner_miter' &&
          clickedNode != null) {
        if (clickedNode.miterSize.value > 0.01) {
          clickedNode.miterSize.value = 0.0;
        } else {
          clickedNode.cornerRadius.value = 0.0;
          clickedNode.miterSize.value =
              30.0 / controller.canvasScale;
        }

        engine.saveSnapshot();
        engine.notifyListeners();
      } else if (selectedAction == 'fillet_corner' &&
          parentSpline != null &&
          clickedNode != null) {
        CompassDialogs.showFilletDialog(
          context,
          engine,
          parentSpline,
          clickedNode,
        );
      } else if (selectedAction == 'toggle_closed' &&
          parentSpline != null) {
        engine.toggleSplineClosed(parentSpline);
      } else if (selectedAction == 'start_spline') {
        controller.startSplineFrom(clickedPoint);
      } else if (selectedAction == 'start_circle') {
        controller.startCircleFrom(clickedPoint);
      }
    }

    // =========================================================================
    // 2. GRADIENT AXIS CONTEXT MENU
    // =========================================================================
    else if (clickedGradientAxisShape != null &&
        gradientAxisInsertPosition != null) {
      final axisShape = clickedGradientAxisShape;
      final insertPosition = gradientAxisInsertPosition;
      final insertColor = gradientAxisInsertColor;

      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: const [
          PopupMenuItem(
            value: 'add_gradient_stop_on_axis',
            child: Text('Add Gradient Stop Here'),
          ),
        ],
      );

      if (selectedAction == 'add_gradient_stop_on_axis') {
        engine.selectShape(axisShape);

        engine.addGradientStop(
          axisShape,
          insertPosition,
          color: insertColor,
        );
      }
    }

    // =========================================================================
    // 3. SHAPE CONTEXT MENU
    // =========================================================================
    else if (clickedShape != null) {
      engine.selectShape(clickedShape);

      final menuItems = <PopupMenuEntry<String>>[
        const PopupMenuItem(
          value: 'add_point',
          child: Text('Add Point to Shape'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'add',
          child: Text('Union (Add)'),
        ),
        const PopupMenuItem(
          value: 'subtract',
          child: Text('Subtract'),
        ),
        const PopupMenuItem(
          value: 'intersect',
          child: Text('Intersect'),
        ),
        const PopupMenuItem(
          value: 'none',
          child: Text('None (Construction)'),
        ),
        const PopupMenuDivider(),
      ];

      if (clickedShape is CompassXSpline) {
        menuItems.insert(
          6,
          PopupMenuItem(
            value: 'toggle_closed',
            child: Text(
              clickedShape.isClosed
                  ? 'Open Spline'
                  : 'Close Spline (Connect Last to First)',
            ),
          ),
        );
      } else if (clickedShape is CompassRectangle) {
        menuItems.insert(
          6,
          const PopupMenuItem(
            value: 'convert_to_spline',
            child: Text('Convert to X-Spline'),
          ),
        );

        menuItems.insert(
          7,
          const PopupMenuItem(
            value: 'convert_to_mesh',
            child: Text('Convert to Gradient Mesh'),
          ),
        );
      } else if (clickedShape is CompassCircle) {
        menuItems.insert(
          6,
          const PopupMenuItem(
            value: 'convert_to_spline',
            child: Text('Convert to X-Spline'),
          ),
        );
      }

      // "Make Gradient" creates the first endpoint.
      //
      // While the gradient contains only that seed, a shape click may create
      // the second endpoint and reveal the dotted axis. Once that axis exists,
      // all additional stops are inserted through the axis context menu above.
      final shapeGradient = clickedShape.gradient;

      if (shapeGradient == null) {
        menuItems.add(
          const PopupMenuItem(
            value: 'make_gradient',
            child: Text('Make Gradient'),
          ),
        );
      } else {
        if (shapeGradient.stops.length == 1) {
          menuItems.add(
            const PopupMenuItem(
              value: 'set_gradient_end',
              child: Text('Set Gradient End Here'),
            ),
          );
        }

        menuItems.add(
          const PopupMenuItem(
            value: 'remove_gradient',
            child: Text(
              'Remove Gradient',
              style: TextStyle(color: Colors.orange),
            ),
          ),
        );
      }

      menuItems.add(
        const PopupMenuDivider(),
      );

      menuItems.add(
        const PopupMenuItem(
          value: 'delete',
          child: Text(
            'Delete Shape',
            style: TextStyle(color: Colors.red),
          ),
        ),
      );

      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: menuItems,
      );

      if (selectedAction != null) {
        if (selectedAction == 'delete') {
          engine.removeShape(clickedShape);
        } else if (selectedAction == 'toggle_closed' &&
            clickedShape is CompassXSpline) {
          engine.toggleSplineClosed(clickedShape);
        } else if (selectedAction == 'convert_to_spline' &&
            clickedShape is CompassCircle) {
          engine.convertCircleToSpline(clickedShape);
        } else if (selectedAction == 'convert_to_spline' &&
            clickedShape is CompassRectangle) {
          engine.convertRectangleToSpline(clickedShape);
        } else if (selectedAction == 'convert_to_mesh' &&
            clickedShape is CompassRectangle) {
          engine.convertRectangleToMesh(clickedShape);
        } else if (selectedAction == 'add_point') {
          final newPoint = CompassPoint(
            x: logicalPosition.dx,
            y: logicalPosition.dy,
          );

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

            for (final layer in engine.layers) {
              for (final shape in layer.shapes) {
                if (shape is CompassXSpline &&
                    shape.anchorPoint != null) {
                  final centerX =
                      (clickedShape.p1.x.value +
                              clickedShape.p2.x.value) /
                          2;

                  final centerY =
                      (clickedShape.p1.y.value +
                              clickedShape.p2.y.value) /
                          2;

                  final matchesCenter =
                      (shape.anchorPoint!.x.value - centerX).abs() <
                              0.1 &&
                          (shape.anchorPoint!.y.value - centerY).abs() <
                              0.1;

                  if (matchesCenter) {
                    newSpline = shape;
                    break;
                  }
                }
              }

              if (newSpline != null) {
                break;
              }
            }

            if (newSpline != null) {
              engine.insertPointIntoSpline(
                newPoint,
                newSpline,
              );
            }
          } else if (clickedShape is CompassXSpline) {
            engine.insertPointIntoSpline(
              newPoint,
              clickedShape,
            );
          }
        } else if (selectedAction == 'make_gradient') {
          // The first stop seeds the gradient with the shape's current color.
          // Until an endpoint is set, the shape continues rendering as a solid.
          engine.makeShapeGradient(
            clickedShape,
            seedPos: logicalPosition,
          );
        } else if (selectedAction == 'set_gradient_end') {
          // The second stop establishes the axis endpoint. All later stops are
          // inserted by right-clicking the dotted line.
          engine.addGradientStop(
            clickedShape,
            logicalPosition,
          );
        } else if (selectedAction == 'remove_gradient') {
          engine.removeGradient(clickedShape);
        } else {
          final operation = CompassBooleanOp.values.firstWhere(
            (candidate) => candidate.name == selectedAction,
          );

          engine.changeShapeOperation(
            clickedShape,
            operation,
          );
        }
      }
    }

    // =========================================================================
    // 4. EMPTY CANVAS CONTEXT MENU
    // =========================================================================
    else {
      final mirrorLayer = engine.activeLayer;
      final canMirror =
          mirrorLayer != null && !mirrorLayer.isLocked;

      final items = <PopupMenuEntry<String>>[
        PopupMenuItem(
          value: 'toggle_scaffolding',
          child: Text(
            showScaffolding
                ? 'Hide Scaffolding (Clean View)'
                : 'Show Scaffolding',
          ),
        ),
        PopupMenuItem(
          value: 'toggle_handles',
          child: Text(
            showHandles
                ? 'Hide Handles'
                : 'Show Handles',
          ),
        ),
        PopupMenuItem(
          value: 'toggle_ghost',
          child: Text(
            ghostVertices
                ? 'Show Vertices'
                : 'Ghost Vertices (Hide Dots, Keep Editable)',
          ),
        ),
      ];

      if (canMirror) {
        items.add(
          const PopupMenuDivider(),
        );

        items.add(
          PopupMenuItem(
            value: 'toggle_mirror',
            child: Text(
              mirrorLayer.mirrorEnabled
                  ? 'Disable Mirror (${mirrorLayer.name})'
                  : 'Enable Mirror Here (${mirrorLayer.name})',
            ),
          ),
        );

        if (mirrorLayer.mirrorEnabled) {
          items.add(
            PopupMenuItem(
              value: 'flip_mirror_axis',
              child: Text(
                mirrorLayer.mirrorAxis == MirrorAxis.vertical
                    ? 'Mirror Axis: Vertical → Horizontal'
                    : 'Mirror Axis: Horizontal → Vertical',
              ),
            ),
          );
        }
      }

      final selectedAction = await showMenu<String>(
        context: context,
        position: position,
        items: items,
      );

      if (selectedAction == 'toggle_scaffolding') {
        onToggleScaffolding();
      } else if (selectedAction == 'toggle_handles') {
        onToggleHandles();
      } else if (selectedAction == 'toggle_ghost') {
        onToggleGhostVertices();
      } else if (selectedAction == 'toggle_mirror' &&
          canMirror) {
        mirrorLayer.mirrorEnabled =
            !mirrorLayer.mirrorEnabled;

        if (mirrorLayer.mirrorEnabled) {
          mirrorLayer.mirrorPosition =
              mirrorLayer.mirrorAxis == MirrorAxis.vertical
                  ? logicalPosition.dx
                  : logicalPosition.dy;
        }

        engine.saveSnapshot();
        engine.notifyListeners();
      } else if (selectedAction == 'flip_mirror_axis' &&
          canMirror) {
        mirrorLayer.mirrorAxis =
            mirrorLayer.mirrorAxis == MirrorAxis.vertical
                ? MirrorAxis.horizontal
                : MirrorAxis.vertical;

        mirrorLayer.mirrorPosition =
            mirrorLayer.mirrorAxis == MirrorAxis.vertical
                ? logicalPosition.dx
                : logicalPosition.dy;

        engine.saveSnapshot();
        engine.notifyListeners();
      }
    }
  }
}