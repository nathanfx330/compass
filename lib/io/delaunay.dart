// /lib/io/delaunay.dart

import 'dart:math';
import 'dart:ui';

/// Pure DELAUNAY TRIANGULATION kernel for a filled 2D region, given the
/// region's boundary as flattened polygon contours -- the exact
/// `List<List<Offset>>` the OBJ exporter already produces via _sampleContour
/// (outer rings and holes alike, classified implicitly by the even-odd rule).
///
/// This is the extraction of the math that was trapped inside
/// ShapeConverter.bakeLayerToSciFiSkeleton (the "Sci-Fi veins" bake): the same
/// point-cloud recipe (boundary samples + seeded Poisson-disc-ish interior
/// scatter), the same Bowyer-Watson sweep, the same centroid-inside filter for
/// concave bays and holes. Differences from the bake, all deliberate:
///
///   * BOUNDARY DENSITY rides the caller's contours instead of a hardcoded
///     30 px respacing -- the exporter flattens at its Curve Resolution
///     (samplingSpacing), so the silhouette fidelity of the triangulation
///     matches the other OBJ modes for free. The contours are used AS GIVEN.
///   * INTERIOR DENSITY is a parameter ([interiorSpacing], the minimum
///     point-to-point distance in logical px) instead of the frozen
///     area/2500 target with a fixed 600 distSq floor.
///   * OUTPUT is welded vertices + 0-based triangle index triples ready for
///     OBJ `f` emission -- not a DFS spline walk. No engine state, no
///     CompassPoints, no listeners: a one-shot geometry computation, exactly
///     parallel to medial_axis.dart next door.
///
/// INSIDE TEST: even-odd across ALL contours at once -- byte-for-byte the rule
/// the OBJ exporter's grid mode and the medial-axis kernel use, so "inside"
/// means the same thing to all three (holes carve identically). Note the
/// Sci-Fi bake tests centroids with Path.contains (the path's own fill rule);
/// for the even-odd geometry Compass produces these agree, and using the
/// shared polygon test here keeps this file free of any Path dependency.
///
/// WINDING: every emitted triangle is normalized to NEGATIVE signed area in
/// the source (Y-down) space. The exporter's Y-flip (ey = -(y - cy)) mirrors
/// the plane, turning that into POSITIVE (counter-clockwise) winding in the
/// OBJ's Y-up space -- so all faces import into Blender facing +Z uniformly,
/// with no per-face normal flips.
///
/// DETERMINISM: the interior scatter uses a caller-suppliable [seed]
/// (default 42, matching the bake), so the same document exports the same
/// mesh every time.
///
/// COST: Bowyer-Watson as implemented is O(n^2) in point count -- identical to
/// the bake's version, brute force on purpose. At export densities (hundreds
/// to a few thousand points) this is comfortably sub-second for a one-shot
/// export; a spatial-hash locate step is the known upgrade if a pathological
/// document ever drags.
///
/// Pure: depends only on dart:ui geometry + dart:math. No engine, no layers.
class DelaunayResult {
  /// Triangulation vertices in the SOURCE coordinate space (Compass logical
  /// px, Y-down, un-recentered). The exporter applies its own recenter +
  /// Y-flip, exactly as it does for the other modes.
  final List<Offset> verts;

  /// 0-based index triples into [verts], one per kept triangle, wound to
  /// negative signed area in source (Y-down) space -- see the class comment.
  final List<(int, int, int)> tris;

  const DelaunayResult(this.verts, this.tris);

  bool get isEmpty => tris.isEmpty;
}

class DelaunayTriangulator {
  /// Triangulates the region bounded by [contours] (outer rings + holes,
  /// even-odd).
  ///
  /// [interiorSpacing] -- minimum distance (logical px) between interior
  ///   scatter points, and thus the approximate edge length of interior
  ///   triangles. Smaller = denser, more uniform mesh. The scatter is
  ///   rejection-sampled against BOTH the boundary samples and previously
  ///   accepted interior points, so triangles stay roughly equilateral at
  ///   the requested scale.
  /// [seed] -- RNG seed for the interior scatter (deterministic exports).
  /// [maxInteriorPoints] -- hard cap on scattered points, a safety valve so a
  ///   huge region with a tiny spacing can't run away. The attempt budget is
  ///   15x the target, mirroring the bake.
  static DelaunayResult triangulate(
    List<List<Offset>> contours, {
    double interiorSpacing = 25.0,
    int seed = 42,
    int maxInteriorPoints = 4000,
  }) {
    if (contours.isEmpty) return const DelaunayResult([], []);

    // ---- 1. Point cloud: boundary samples (as given) + bounding box. ------
    final cloud = <Offset>[];
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final poly in contours) {
      for (final p in poly) {
        cloud.add(p);
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    if (cloud.length < 3) return const DelaunayResult([], []);

    final w = maxX - minX;
    final h = maxY - minY;
    if (w <= 0 || h <= 0) return const DelaunayResult([], []);

    // ---- 2. Interior scatter (seeded, spacing-enforced). -------------------
    // Target count from area at the requested spacing (hex-packing-ish
    // estimate: one point per spacing^2 cell), clamped to the safety cap.
    final spacing = interiorSpacing < 1.0 ? 1.0 : interiorSpacing;
    final spacingSq = spacing * spacing;
    int target = (w * h / spacingSq).ceil();
    if (target > maxInteriorPoints) target = maxInteriorPoints;

    final random = Random(seed);
    int added = 0;
    int attempt = 0;
    final int attemptBudget = target * 15;

    while (added < target && attempt < attemptBudget) {
      attempt++;
      final pt = Offset(
        minX + random.nextDouble() * w,
        minY + random.nextDouble() * h,
      );

      if (!_pointInRegion(pt, contours)) continue;

      bool tooClose = false;
      for (final q in cloud) {
        if ((q - pt).distanceSquared < spacingSq) {
          tooClose = true;
          break;
        }
      }
      if (tooClose) continue;

      cloud.add(pt);
      added++;
    }

    // ---- 3. Bowyer-Watson Delaunay over the whole cloud. -------------------
    final triangles = _bowyerWatson(cloud);
    if (triangles.isEmpty) return const DelaunayResult([], []);

    // ---- 4. Weld vertices + emit inside triangles, winding-normalized. -----
    // Round-keyed weld map (0.01 px lattice), matching the bake's dedup: the
    // triangulator hands back raw Offsets, and shared corners must share an
    // OBJ index. Only vertices actually referenced by a KEPT triangle are
    // emitted, so culled-bay/hole scatter never leaves stray `v` lines.
    final verts = <Offset>[];
    final vIndex = <(int, int), int>{};
    final tris = <(int, int, int)>[];

    int vid(Offset o) {
      final key = ((o.dx * 100).round(), (o.dy * 100).round());
      final existing = vIndex[key];
      if (existing != null) return existing;
      verts.add(o);
      final id = verts.length - 1;
      vIndex[key] = id;
      return id;
    }

    for (final t in triangles) {
      // Concave-bay / hole filter: keep only triangles whose centroid is
      // inside the even-odd region -- the same rule that carves the Sci-Fi
      // bake and the grid/skeleton modes.
      if (!_pointInRegion(t.centroid, contours)) continue;

      final ia = vid(t.a);
      final ib = vid(t.b);
      final ic = vid(t.c);
      if (ia == ib || ib == ic || ia == ic) continue; // degenerate after weld

      // Normalize winding: signed area NEGATIVE in Y-down source space, so
      // the exporter's Y-flip yields uniform CCW (+Z-facing) faces.
      final area2 = (t.b.dx - t.a.dx) * (t.c.dy - t.a.dy) -
          (t.c.dx - t.a.dx) * (t.b.dy - t.a.dy);
      if (area2.abs() < 1e-9) continue; // zero-area sliver
      if (area2 < 0) {
        tris.add((ia, ib, ic));
      } else {
        tris.add((ia, ic, ib));
      }
    }

    return DelaunayResult(verts, tris);
  }

  // ---------------------------------------------------------------------------
  // BOWYER-WATSON (lifted from the Sci-Fi bake, classes made file-public)
  // ---------------------------------------------------------------------------

  static List<DelaunayTriangle> _bowyerWatson(List<Offset> points) {
    if (points.length < 3) return [];

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }

    final dx = maxX - minX;
    final dy = maxY - minY;
    final deltaMax = max(dx, dy);
    final midX = (minX + maxX) / 2;
    final midY = (minY + maxY) / 2;

    // Super-triangle enveloping all points.
    final p1 = Offset(midX - 20 * deltaMax, midY - deltaMax);
    final p2 = Offset(midX, midY + 20 * deltaMax);
    final p3 = Offset(midX + 20 * deltaMax, midY - deltaMax);

    final triangles = <DelaunayTriangle>[DelaunayTriangle(p1, p2, p3)];

    for (final pt in points) {
      final bad = <DelaunayTriangle>[];
      for (final t in triangles) {
        if (t.circumcircleContains(pt)) bad.add(t);
      }

      // Boundary of the star-shaped cavity: edges NOT shared by two bad tris.
      final polygon = <DelaunayEdge>[];
      for (final t in bad) {
        for (final e1 in t.edges) {
          bool shared = false;
          for (final other in bad) {
            if (identical(t, other)) continue;
            for (final e2 in other.edges) {
              if (e1.equals(e2)) {
                shared = true;
                break;
              }
            }
            if (shared) break;
          }
          if (!shared) polygon.add(e1);
        }
      }

      triangles.removeWhere(bad.contains);

      for (final edge in polygon) {
        triangles.add(DelaunayTriangle(edge.p1, edge.p2, pt));
      }
    }

    // Drop every triangle touching the super-triangle's corners.
    triangles.removeWhere((t) =>
        t.a == p1 || t.a == p2 || t.a == p3 ||
        t.b == p1 || t.b == p2 || t.b == p3 ||
        t.c == p1 || t.c == p2 || t.c == p3);

    return triangles;
  }

  // Even-odd point-in-region across ALL contours at once -- byte-for-byte the
  // rule the OBJ exporter's grid mode and medial_axis.dart use, so holes carve
  // this mode exactly as they carve the fill mesh and the skeleton.
  static bool _pointInRegion(Offset p, List<List<Offset>> contours) {
    bool inside = false;
    for (final poly in contours) {
      final n = poly.length;
      for (int i = 0, j = n - 1; i < n; j = i++) {
        final a = poly[i];
        final b = poly[j];
        final hits = ((a.dy > p.dy) != (b.dy > p.dy)) &&
            (p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx);
        if (hits) inside = !inside;
      }
    }
    return inside;
  }
}

/// One undirected edge of a candidate triangle during the Bowyer-Watson sweep.
/// Tolerance-matched (1e-4) rather than exact-equality so the cavity-boundary
/// test survives floating-point drift between the two windings of a shared edge.
class DelaunayEdge {
  final Offset p1, p2;
  DelaunayEdge(this.p1, this.p2);

  bool equals(DelaunayEdge other) {
    return ((p1.dx - other.p1.dx).abs() < 1e-4 && (p1.dy - other.p1.dy).abs() < 1e-4 &&
            (p2.dx - other.p2.dx).abs() < 1e-4 && (p2.dy - other.p2.dy).abs() < 1e-4) ||
           ((p1.dx - other.p2.dx).abs() < 1e-4 && (p1.dy - other.p2.dy).abs() < 1e-4 &&
            (p2.dx - other.p1.dx).abs() < 1e-4 && (p2.dy - other.p1.dy).abs() < 1e-4);
  }
}

/// One triangle of the sweep. circumcircleContains is the Delaunay in-circle
/// test via the explicit circumcenter (guarded against collinear degeneracy).
class DelaunayTriangle {
  final Offset a, b, c;
  DelaunayTriangle(this.a, this.b, this.c);

  bool circumcircleContains(Offset pt) {
    final double ax = a.dx, ay = a.dy;
    final double bx = b.dx, by = b.dy;
    final double cx = c.dx, cy = c.dy;

    final double d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
    if (d.abs() < 1e-9) return false;

    final double ux = ((ax * ax + ay * ay) * (by - cy) +
            (bx * bx + by * by) * (cy - ay) +
            (cx * cx + cy * cy) * (ay - by)) / d;
    final double uy = ((ax * ax + ay * ay) * (cx - bx) +
            (bx * bx + by * by) * (ax - cx) +
            (cx * cx + cy * cy) * (bx - ax)) / d;

    final double rSq = (ax - ux) * (ax - ux) + (ay - uy) * (ay - uy);
    final double distSq = (pt.dx - ux) * (pt.dx - ux) + (pt.dy - uy) * (pt.dy - uy);

    return distSq <= rSq + 1e-5;
  }

  List<DelaunayEdge> get edges =>
      [DelaunayEdge(a, b), DelaunayEdge(b, c), DelaunayEdge(c, a)];

  Offset get centroid =>
      Offset((a.dx + b.dx + c.dx) / 3, (a.dy + b.dy + c.dy) / 3);
}