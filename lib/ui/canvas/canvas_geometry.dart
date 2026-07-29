// /lib/ui/canvas/canvas_geometry.dart

import 'dart:math';
import 'package:flutter/material.dart';

import '../../engine.dart';
import '../../models/geometry/point.dart';
import '../../models/geometry/shape.dart';
import '../../models/geometry/line.dart';
import '../../models/geometry/circle.dart';
import '../../models/geometry/spiral.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/rectangle.dart';
import '../../models/geometry/mesh.dart'; // <--- NEW: gradient mesh
import '../../models/geometry/image.dart';

class CanvasGeometry {
  /// Extracts all structural points from a given shape.
  static List<CompassPoint> getPointsOfShape(CompassShape shape) {
    if (shape is CompassLine) return [shape.start, shape.end];
    if (shape is CompassCircle) return [shape.center, if (shape.radiusPoint != null) shape.radiusPoint!];
    if (shape is CompassSpiral) return [shape.center, shape.startPoint];
    if (shape is CompassRectangle) return [shape.p1, shape.p2];
    if (shape is CompassImage) {
      return [shape.origin, shape.xHandle, shape.yHandle];
    }
    if (shape is CompassXSpline) {
      final points = shape.nodes.map((n) => n.point).toList();
      if (shape.anchorPoint != null) points.add(shape.anchorPoint!);
      return points;
    }
    if (shape is CompassMesh) {
      // Every grid node IS a structural point (dragging one distorts the mesh),
      // plus the centroid anchor -- exactly parallel to the X-Spline case. This is
      // what lets getRigidBody and the selection/rotation machinery pick a mesh up
      // with no further special-casing: they all route through this list and the
      // anchor->node attachment edges.
      // UPGRADE: extract the point from the CompassSplineNode
      final points = shape.nodes.map((n) => n.point).toList();
      if (shape.anchorPoint != null) points.add(shape.anchorPoint!);
      return points;
    }
    return [];
  }

  /// Calculates the mathematical centroid of a shape.
  static Offset? getShapeCentroid(CompassShape shape) {
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
    } else if (shape is CompassMesh) {
      // Anchor is the rotation pivot / rigid-body center, same as a spline. Fall
      // back to the average node position if (defensively) there's no anchor.
      if (shape.anchorPoint != null) {
        return Offset(shape.anchorPoint!.x.value, shape.anchorPoint!.y.value);
      }
      if (shape.nodes.isNotEmpty) {
        double cx = 0, cy = 0;
        for (var n in shape.nodes) {
          cx += n.point.x.value; // <--- UPGRADE: Call .point.x
          cy += n.point.y.value; // <--- UPGRADE: Call .point.y
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
    } else if (shape is CompassImage) {
      return shape.getPath().getBounds().center;
    } else if (shape is CompassLine) {
      return Offset((shape.start.x.value + shape.end.x.value) / 2, (shape.start.y.value + shape.end.y.value) / 2);
    }
    return null;
  }

  /// Traverses the attachment graph to find all points connected in a rigid body.
  static Set<CompassPoint> getRigidBody(CompassEngine engine, CompassShape? shape, CompassPoint? explicitPoint, bool hierarchy) {
    Set<CompassPoint> rigidBody = {};
    
    if (shape != null) {
      rigidBody.addAll(getPointsOfShape(shape));
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
            
            final shapePts = getPointsOfShape(s);
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

  /// Ensures shapes like circles and spirals are kept cohesive during transformations.
  static Set<CompassPoint> expandForShapeCohesion(CompassEngine engine, Set<CompassPoint> pts) {
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

  /// Calculates the centroid of an arbitrary set of points.
  static Offset? centroidOfPoints(Set<CompassPoint> pts) {
    if (pts.isEmpty) return null;
    double cx = 0, cy = 0;
    for (var p in pts) {
      cx += p.x.value;
      cy += p.y.value;
    }
    return Offset(cx / pts.length, cy / pts.length);
  }

  /// Evaluates a cubic bezier curve at parameter t.
  static Offset cubicAt(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
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

  /// Calculates the visual position of a variable-width handle.
  static Offset? getWidthHandlePosition(CompassSplineNode node, bool isLeft, CompassXSpline spline) {
    int i = spline.nodes.indexOf(node);
    if (i == -1) return null;
    
    final controls = spline.getEvaluatedControls();
    int n = spline.nodes.length;
    
    final pt = Offset(node.point.x.value, node.point.y.value);
    Offset prevPt = spline.isClosed ? Offset(spline.nodes[(i - 1 + n) % n].point.x.value, spline.nodes[(i - 1 + n) % n].point.y.value) : (i > 0 ? Offset(spline.nodes[i - 1].point.x.value, spline.nodes[i - 1].point.y.value) : pt);
    Offset nextPt = spline.isClosed ? Offset(spline.nodes[(i + 1) % n].point.x.value, spline.nodes[(i + 1) % n].point.y.value) : (i < n - 1 ? Offset(spline.nodes[i + 1].point.x.value, spline.nodes[i + 1].point.y.value) : pt);

    final hOut = controls[i].$1;
    final hIn = controls[i].$2;

    Offset vOut = hOut;
    if (vOut.distance < 0.001) vOut = nextPt - pt;
    Offset vIn = Offset(-hIn.dx, -hIn.dy);
    if (vIn.distance < 0.001) vIn = pt - prevPt;

    if (!spline.isClosed) {
      if (i == 0) vIn = vOut;
      if (i == n - 1) vOut = vIn;
    }

    double lenOut = vOut.distance;
    double lenIn = vIn.distance;
    Offset tOut = lenOut > 0.001 ? vOut / lenOut : Offset.zero;
    Offset tIn = lenIn > 0.001 ? vIn / lenIn : Offset.zero;

    Offset T = tIn + tOut;
    double lenT = T.distance;
    if (lenT > 0.001) {
      T = T / lenT;
    } else {
      T = tOut; 
    }
    
    Offset N = Offset(-T.dy, T.dx);
    
    if (isLeft) {
      return pt + N * node.widthLeft.value;
    } else {
      return pt - N * node.widthRight.value;
    }
  }
}