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

  /// Applies one (path, op) to the running [master], preserving the ORIGINAL
  /// seeding rule the boolean walk has always used: an `add` against an empty
  /// master ESTABLISHES the base region; a subtract/intersect against nothing
  /// yields nothing (you cannot carve what is not there). An empty contribution
  /// or a `none` op is a no-op.
  ///
  /// This is the single chokepoint that BOTH a shape's fill op and its stroke
  /// regions route through, so the committed "stroke before fill" ordering is
  /// simply the order of the calls within a shape's turn -- no per-call casing.
  ///
  /// The contribution is always a freshly-built Path (getPath / getCenterPath /
  /// getStrokeOutlinePath all return new paths), so returning it directly when
  /// seeding cannot alias a shape's internal state, and Path.combine never mutates
  /// its inputs.
  Path _combine(Path master, Path contribution, CompassBooleanOp op) {
    if (op == CompassBooleanOp.none) return master;
    if (contribution.computeMetrics().isEmpty) return master;

    if (master.computeMetrics().isEmpty) {
      return op == CompassBooleanOp.add ? contribution : master;
    }

    switch (op) {
      case CompassBooleanOp.add:
        return Path.combine(PathOperation.union, master, contribution);
      case CompassBooleanOp.subtract:
        return Path.combine(PathOperation.difference, master, contribution);
      case CompassBooleanOp.intersect:
        return Path.combine(PathOperation.intersect, master, contribution);
      case CompassBooleanOp.none:
        return master;
    }
  }

  /// Walks a shape's OUTWARD-STACKED stroke stack and yields one record per
  /// non-zero-width region, in list order, carrying that region plus its band
  /// geometry inputs (width + innerOffset). This is the SINGLE source of the
  /// stacking-cursor math: region 0 starts exactly at the shape's boundary (0.0).
  ///
  /// Starting at 0.0 means the custom ring touches the base shape perfectly, 
  /// allowing the boolean engine to merge them into a single continuous object.
  List<({StrokeRegion region, double width, double innerOffset})> _strokeBands(
      CompassShape shape) {
    final out = <({StrokeRegion region, double width, double innerOffset})>[];
    
    // Start exactly at the shape's boundary (0.0 offset).
    // This pushes the strokes purely OUTWARD without leaving a mathematical gap.
    double offset = 0.0; 
    
    for (final region in shape.strokeRegions) {
      final w = region.width;
      if (w <= 0) continue;
      
      out.add((region: region, width: w, innerOffset: offset));
      offset += w;
    }
    return out;
  }

  /// Applies a shape's stroke stack to [master], in list order, returning the
  /// updated path. The stacking geometry comes from _strokeBands (shared with the
  /// overpaint collector), so all four boolean walks and the paint pass agree on
  /// where every band sits.
  ///
  /// [addsAllowed] false means only subtract/intersect regions are applied (the
  /// ribbon-area and mesh-clip walks, which can only be CARVED, never seeded, by a
  /// stroke). When true (the fill/outline walks) all three ops apply through
  /// _combine, which also handles seeding an empty master from an `add`. An add
  /// region skipped under addsAllowed:false still advanced the cursor inside
  /// _strokeBands, so later subtract/intersect bands land at the right radii.
  Path _applyStrokeStack(Path master, CompassShape shape, {required bool addsAllowed}) {
    for (final b in _strokeBands(shape)) {
      final op = b.region.op;
      final apply = addsAllowed ||
          op == CompassBooleanOp.subtract ||
          op == CompassBooleanOp.intersect;
      if (!apply) continue;

      final band = shape.getStrokeOutlinePath(b.width, b.innerOffset);
      if (addsAllowed) {
        master = _combine(master, band, op);
      } else if (master.computeMetrics().isNotEmpty &&
          band.computeMetrics().isNotEmpty) {
        // Carve-only path: never seed, only difference/intersect an existing master.
        master = op == CompassBooleanOp.subtract
            ? Path.combine(PathOperation.difference, master, band)
            : Path.combine(PathOperation.intersect, master, band);
      }
    }
    return master;
  }

  /// True if any of the shape's stroke regions can CARVE (subtract/intersect) --
  /// the cheap gate the ribbon-area walk uses to decide a shape is interesting.
  bool _hasCarvingStroke(CompassShape shape) {
    for (final r in shape.strokeRegions) {
      if (r.op == CompassBooleanOp.subtract || r.op == CompassBooleanOp.intersect) {
        return true;
      }
    }
    return false;
  }

  /// The master boolean path intended to be OUTLINED with the uniform stroke.
  /// Excludes Variable-Width Splines, which live in their own Stroke Area Path.
  Path getLayerPath() {
    Path master = Path();
    for (var shape in shapes) {
      if (!shape.isVisible) continue;

      // Gradient meshes are their own render category.
      if (shape is CompassMesh) continue;

      // --- STROKE STACK (before fill) ---
      master = _applyStrokeStack(master, shape, addsAllowed: true);

      // --- FILL CONTRIBUTION ---
      if (shape.operation != CompassBooleanOp.none) {
        final bool isAddWidthSpline = shape.operation == CompassBooleanOp.add &&
            shape is CompassXSpline &&
            shape.hasWidthProfile;
        
        if (!isAddWidthSpline) {
          master = _combine(master, shape.getPath(), shape.operation);
        }
      }
    }
    return master;
  }

  /// The master boolean path intended to be FILLED.
  Path getLayerFillPath() {
    Path master = Path();
    for (var shape in shapes) {
      if (!shape.isVisible) continue;

      // Gradient meshes never join the flat fill union -- they're a separate
      // self-painted, separately-clipped render category.
      if (shape is CompassMesh) continue;

      // --- STROKE STACK (before fill) ---
      master = _applyStrokeStack(master, shape, addsAllowed: true);

      // --- FILL CONTRIBUTION ---
      if (shape.operation != CompassBooleanOp.none) {
        Path? fillPath;
        if (shape is CompassXSpline &&
            shape.hasWidthProfile &&
            shape.operation == CompassBooleanOp.add) {
          if (shape.isClosed) {
            fillPath = shape.getCenterPath()..fillType = PathFillType.evenOdd;
          }
        } else {
          fillPath = shape.getPath();
        }

        if (fillPath != null) {
          master = _combine(master, fillPath, shape.operation);
        }
      }
    }
    return master;
  }

  /// The colored ADD-band overpaints for this layer, in paint order (Z-order across
  /// shapes, then stack order -- innermost first -- within a shape), as (path,
  /// color) pairs. The renderer/PNG paint these on TOP of the flat layer fill so a
  /// custom-colored band shows in its own color instead of the layer fill color.
  List<(Path, Color)> getStrokeAddBandOverpaints(Path fillMaster) {
    if (fillMaster.computeMetrics().isEmpty) return const [];

    final out = <(Path, Color)>[];
    for (var shape in shapes) {
      if (!shape.isVisible) continue;
      if (shape is CompassMesh) continue; // meshes carry no stroke bands

      for (final b in _strokeBands(shape)) {
        if (b.region.op != CompassBooleanOp.add) continue;
        final color = b.region.color;
        if (color == null) continue; // null-color add bands ride the master

        final band = shape.getStrokeOutlinePath(b.width, b.innerOffset);
        if (band.computeMetrics().isEmpty) continue;

        final clipped = Path.combine(PathOperation.intersect, fillMaster, band);
        if (clipped.computeMetrics().isEmpty) continue;

        out.add((clipped, color));
      }
    }
    return out;
  }

  /// The master boolean path for Variable-Width Area Strokes.
  Path getLayerStrokeAreaPath() {
    Path master = Path();
    for (var shape in shapes) {
      if (!shape.isVisible) continue;
      if (shape.operation == CompassBooleanOp.none && !_hasCarvingStroke(shape)) {
        continue;
      }

      // --- STROKE STACK carve (before fill) --- carve-only: never seeds the master.
      master = _applyStrokeStack(master, shape, addsAllowed: false);

      // --- FILL handling (original area-stroke logic) ---
      if (shape.operation == CompassBooleanOp.none) continue;

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
  /// outer ring, carved by the layer's boolean stack. The renderer clips the
  /// mesh's drawVertices output to this path each frame.
  Path getLayerMeshClipPath(CompassMesh mesh) {
    Path clip = mesh.getPath();
    if (clip.computeMetrics().isEmpty) return clip;

    for (var shape in shapes) {
      if (!shape.isVisible) continue;
      if (shape is CompassMesh) continue; // self + siblings: meshes never carve

      // --- STROKE STACK cut (before fill) --- carve-only: add regions do nothing.
      clip = _applyStrokeStack(clip, shape, addsAllowed: false);

      // --- FILL cut ---
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