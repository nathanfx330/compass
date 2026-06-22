// lib/models/layer.dart

import 'package:flutter/material.dart';
import 'geometry/shape.dart';
import 'geometry/spline.dart'; // <--- NEW: Needed to identify variable width splines

/// Represents a distinct Z-layer of geometry.
class CompassLayer {
  final String id;
  String name;
  bool isVisible = true;
  bool isExpanded = true;
  bool isLocked = false;
  Color color;
  Color strokeColor;
  double strokeWidth;

  final List<CompassShape> shapes = [];

  CompassLayer({
    required this.name,
    this.color = const Color(0xFF222222),
    this.strokeColor = Colors.transparent,
    this.strokeWidth = 2.0,
    String? id,
  }) : id = id ?? UniqueKey().toString();

  /// The master boolean path intended to be OUTLINED with the uniform stroke.
  /// Excludes Variable-Width Splines, which live in their own Stroke Area Path.
  ///
  /// NOTE: this is deliberately NOT the fill path anymore. It still excludes
  /// width splines so the uniform stroke pass (renderer step 1b) never paints a
  /// hairline along the inner edge of a fat ribbon. The actual fill region --
  /// which DOES include a closed width spline's centerline -- comes from
  /// getLayerFillPath() below. Kept byte-for-byte identical to its old self so
  /// nothing that already depends on it (the uniform stroke) shifts.
  Path getLayerPath() {
    Path master = Path();
    for (var shape in shapes) {
      if (!shape.isVisible || shape.operation == CompassBooleanOp.none) continue;

      // Variable-width splines are treated as area strokes. They do not add to the fill.
      if (shape.operation == CompassBooleanOp.add) {
        if (shape is CompassXSpline && shape.hasWidthProfile) continue;
      }

      final shapePath = shape.getPath();
      if (shapePath.computeMetrics().isEmpty) continue;

      if (master.computeMetrics().isEmpty && shape.operation == CompassBooleanOp.add) {
        master = shapePath;
        continue;
      }

      if (shape.operation == CompassBooleanOp.add) {
        master = Path.combine(PathOperation.union, master, shapePath);
      } else if (shape.operation == CompassBooleanOp.subtract) {
        master = Path.combine(PathOperation.difference, master, shapePath);
      } else if (shape.operation == CompassBooleanOp.intersect) {
        master = Path.combine(PathOperation.intersect, master, shapePath);
      }
    }
    return master;
  }

  /// The master boolean path intended to be FILLED.
  ///
  /// Identical to getLayerPath() for every non-width shape, with ONE addition: a
  /// variable-width spline that is `add` AND CLOSED contributes its centerline
  /// region (getCenterPath) to the fill. This is what promotes an area stroke to
  /// a first-class stroke -- the centerline is the fill, the ribbon (from
  /// getLayerStrokeAreaPath) is the centered stroke, and the two coexist.
  ///
  /// An OPEN width spline encloses no area, so it contributes nothing here; its
  /// ribbon still draws as a capsule via the stroke-area path. Because the fill
  /// region is derived live from `isClosed` and never stored, an
  /// open -> close -> open round-trip is lossless: close fills, open empties,
  /// close fills again, with nothing to persist or rebuild.
  ///
  /// Subtract/intersect semantics are unchanged from getLayerPath() -- a width
  /// spline used as a subtractor still carves with its ribbon (getPath), exactly
  /// as before. The ONLY behavioral difference between the two methods is the
  /// closed-width-spline centerline union.
  Path getLayerFillPath() {
    Path master = Path();
    for (var shape in shapes) {
      if (!shape.isVisible || shape.operation == CompassBooleanOp.none) continue;

      // Decide what this shape contributes to the FILL.
      Path shapePath;
      if (shape is CompassXSpline &&
          shape.hasWidthProfile &&
          shape.operation == CompassBooleanOp.add) {
        // Closed: the centerline loop is the fill region. Open: no enclosed
        // area, so skip (the ribbon still strokes via getLayerStrokeAreaPath).
        if (!shape.isClosed) continue;
        shapePath = shape.getCenterPath()..fillType = PathFillType.evenOdd;
      } else {
        shapePath = shape.getPath();
      }

      if (shapePath.computeMetrics().isEmpty) continue;

      if (master.computeMetrics().isEmpty && shape.operation == CompassBooleanOp.add) {
        master = shapePath;
        continue;
      }

      if (shape.operation == CompassBooleanOp.add) {
        master = Path.combine(PathOperation.union, master, shapePath);
      } else if (shape.operation == CompassBooleanOp.subtract) {
        master = Path.combine(PathOperation.difference, master, shapePath);
      } else if (shape.operation == CompassBooleanOp.intersect) {
        master = Path.combine(PathOperation.intersect, master, shapePath);
      }
    }
    return master;
  }

  /// The master boolean path for Variable-Width Area Strokes.
  /// Unions all variable-width splines together, while still respecting
  /// subtractions and intersections from ALL other shapes on the layer.
  Path getLayerStrokeAreaPath() {
    Path master = Path();
    for (var shape in shapes) {
      if (!shape.isVisible || shape.operation == CompassBooleanOp.none) continue;

      final shapePath = shape.getPath();
      if (shapePath.computeMetrics().isEmpty) continue;

      // Only Add if it is an explicitly defined Area Stroke
      if (shape.operation == CompassBooleanOp.add) {
        if (shape is CompassXSpline && shape.hasWidthProfile) {
          if (master.computeMetrics().isEmpty) {
            master = shapePath;
          } else {
            master = Path.combine(PathOperation.union, master, shapePath);
          }
        }
        continue; // Normal fills don't add to the stroke master
      }

      // Subtractions and Intersections cut through Area Strokes just like Fills!
      if (master.computeMetrics().isNotEmpty) {
        if (shape.operation == CompassBooleanOp.subtract) {
          master = Path.combine(PathOperation.difference, master, shapePath);
        } else if (shape.operation == CompassBooleanOp.intersect) {
          master = Path.combine(PathOperation.intersect, master, shapePath);
        }
      }
    }
    return master;
  }
}