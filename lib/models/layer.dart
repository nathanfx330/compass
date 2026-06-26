// lib/models/layer.dart

import 'package:flutter/material.dart';
import 'geometry/shape.dart';
import 'geometry/spline.dart'; // <--- Needed to identify variable width splines
import 'geometry/mesh.dart';   // <--- NEW: Needed to exclude/clip gradient meshes

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

      // Gradient meshes are their own render category: they paint themselves via
      // drawVertices, clipped to the boolean-carved silhouette in the renderer's
      // dedicated mesh pass. They must never join the flat fill/stroke boolean
      // union (that would stroke the mesh's quad outline as if it were a normal
      // shape boundary), so skip them here.
      if (shape is CompassMesh) continue;

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

      // Gradient meshes never join the flat fill union -- they're a separate
      // self-painted, separately-clipped render category. Skipping them here is
      // what keeps a mesh from being painted as a solid `layer.color` block
      // (renderer step 1a) underneath its own gradient surface.
      if (shape is CompassMesh) continue;

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
  ///
  /// Meshes need no special handling here: a mesh is always `add` and is not a
  /// width spline, so it falls through the `add` branch's inner check and is
  /// never unioned in; and being `add` it is never a subtract/intersect cutter
  /// either. So it can neither contribute to nor carve the area-stroke master.
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

  /// The clip silhouette for a SINGLE gradient mesh on this layer: the mesh's own
  /// outer ring, carved by the layer's boolean stack. This is the "shape it with
  /// booleans like Illustrator, but non-destructive" mechanism -- the renderer
  /// clips the mesh's drawVertices output to this path each frame.
  ///
  /// Construction: seed with mesh.getPath() (the deformable outer-ring quad), then
  /// walk the layer's shapes IN Z-ORDER, applying every `subtract` shape as a
  /// difference and every `intersect` shape as an intersection -- the same
  /// order-dependent semantics getLayerFillPath uses, so a mesh carves the way a
  /// fill carves. Drop a circle on `subtract` and it bites a hole; set a shape to
  /// `intersect` and the mesh is masked to that shape's interior.
  ///
  /// Meshes are skipped as cutters entirely (the `is CompassMesh` guard covers
  /// both THIS mesh -- a mesh can't carve itself -- and any sibling mesh, since a
  /// mesh is always additive content and never a subtractor). Construction guides
  /// (`none`) and hidden shapes don't cut, matching the fill path. If nothing
  /// carves, this returns the bare quad, so an uncut mesh fills its full frame.
  Path getLayerMeshClipPath(CompassMesh mesh) {
    Path clip = mesh.getPath();
    if (clip.computeMetrics().isEmpty) return clip;

    for (var shape in shapes) {
      if (!shape.isVisible || shape.operation == CompassBooleanOp.none) continue;
      if (shape is CompassMesh) continue; // self + siblings: meshes never carve

      if (shape.operation == CompassBooleanOp.subtract) {
        final cutter = shape.getPath();
        if (cutter.computeMetrics().isEmpty) continue;
        clip = Path.combine(PathOperation.difference, clip, cutter);
      } else if (shape.operation == CompassBooleanOp.intersect) {
        final cutter = shape.getPath();
        if (cutter.computeMetrics().isEmpty) continue;
        clip = Path.combine(PathOperation.intersect, clip, cutter);
      }
    }
    return clip;
  }
}