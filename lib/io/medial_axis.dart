// /lib/io/medial_axis.dart

import 'dart:math';
import 'dart:ui';

/// Extracts an approximate MEDIAL AXIS (skeleton) of a filled 2D region, given
/// the region's boundary as flattened polygon contours -- the exact
/// `List<List<Offset>>` the OBJ exporter already produces via _sampleContour,
/// outer rings and holes alike, classified implicitly by the even-odd rule.
///
/// METHOD -- a discrete Voronoi sweep with lambda pruning:
///
///   1. Every contour vertex is a boundary SAMPLE (a Voronoi "site"). The
///      contours arrive already densely flattened (samplingSpacing apart), so no
///      re-sampling happens here; skeleton fidelity follows the exporter's
///      Curve Resolution setting for free.
///   2. A uniform grid is swept over the bounding box (same cell-sizing rule as
///      the exporter's grid mode: `gridCount` square cells across the LONGEST
///      side). Only cell centers INSIDE the region (even-odd across all
///      contours, so holes are excluded) are considered.
///   3. MEDIAL AXIS TEST, with LAMBDA PRUNING built in: a cell center is on the
///      skeleton when at least two boundary samples are (near-)equidistant
///      nearest neighbors AND those samples are far apart from EACH OTHER --
///      i.e. the point "sees" two different walls, not two adjacent samples on
///      the same smooth wall. Concretely: find the nearest sample distance d1,
///      gather every sample within d1 + tol (tol = one cell, the discretization
///      limit), and keep the cell iff some gathered sample sits >= [lambda]
///      away from the nearest one. Raising lambda kills short, unstable
///      branches (the medial axis's infamous noise) and leaves the primary
///      frame; lowering it keeps finer twigs.
///   4. Surviving cells are linked 8-connected into an edge graph; isolated
///      (degree-0) cells are dropped as noise. Vertices are welded on the cell
///      lattice so the graph is index-clean for OBJ `l` emission.
///   5. SNAP TIPS: Terminal leaf nodes (degree-1) are moved directly onto the 
///      nearest boundary sample. This guarantees the skeleton reaches the 
///      perimeter smoothly without sharp bridging kinks.
///
/// COST: two O(samples) passes per interior cell -- brute force on purpose. At
/// the exporter's scales (grid <= ~96, samples in the low thousands) this is
/// tens of milliseconds-to-subsecond territory for a one-shot export; a spatial
/// hash is the known upgrade if a pathological document ever drags.
///
/// OUTPUT: raw-coordinate vertices + 0-BASED edge index pairs. The exporter owns
/// the recenter / Y-flip / 1-based OBJ indexing, exactly as it does for faces --
/// this file stays a pure geometry kernel with no serialization opinions.
///
/// Pure: depends only on dart:ui geometry + math. No engine, no layers.
class MedialAxisResult {
  /// Skeleton vertices in the SOURCE coordinate space (Compass logical px,
  /// Y-down, un-recentered). The exporter applies its own recenter + Y-flip.
  final List<Offset> verts;

  /// 0-based index pairs into [verts], each an undirected skeleton edge,
  /// emitted once (no duplicates, no self-edges).
  final List<(int, int)> edges;

  const MedialAxisResult(this.verts, this.edges);

  bool get isEmpty => edges.isEmpty;
}

class MedialAxisExtractor {
  /// Computes the lambda-pruned medial axis of the region bounded by
  /// [contours] (outer rings + holes, even-odd).
  ///
  /// [gridCount] -- skeleton resolution: number of sweep cells across the
  ///   LONGEST bounding-box side (same meaning as the exporter's grid mode).
  ///   Higher = finer skeleton, smoother branches, more segments.
  /// [lambda] -- pruning strength in LOGICAL PX: the minimum separation two
  ///   near-equidistant boundary samples must have for their midpoint cell to
  ///   count as skeleton. Intuition: branches induced by boundary features
  ///   smaller than lambda are removed. Must be comfortably larger than the
  ///   boundary sampling spacing or every wall cell self-qualifies via its own
  ///   neighboring samples; the exporter's dialog should keep the floor above
  ///   ~4x samplingSpacing.
  static MedialAxisResult extract(
    List<List<Offset>> contours, {
    int gridCount = 64,
    double lambda = 20.0,
  }) {
    if (contours.isEmpty || gridCount < 2) {
      return const MedialAxisResult([], []);
    }

    // ---- 1. Flatten samples + bounding box. -------------------------------
    final samples = <Offset>[];
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final poly in contours) {
      for (final p in poly) {
        samples.add(p);
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    if (samples.length < 3) return const MedialAxisResult([], []);

    final w = maxX - minX;
    final h = maxY - minY;
    if (w <= 0 || h <= 0) return const MedialAxisResult([], []);

    // Square cells, `gridCount` across the longest side (grid-mode rule).
    final cell = (w >= h ? w : h) / gridCount;
    if (cell <= 0) return const MedialAxisResult([], []);
    final cols = (w / cell).ceil();
    final rows = (h / cell).ceil();

    // Equidistance tolerance: one cell. Tighter than this and the lattice
    // itself can't resolve "equidistant"; looser and walls start passing.
    final tol = cell;
    final lambdaSq = lambda * lambda;

    // ---- 2. Sweep: mark skeleton cells. -----------------------------------
    // survivors[r * cols + c] = true when the cell center passes the medial
    // test. Kept as a flat list so the 8-connectivity pass below is O(1) per
    // neighbor probe.
    final survivors = List<bool>.filled(rows * cols, false);

    for (int r = 0; r < rows; r++) {
      final cy = minY + (r + 0.5) * cell;
      for (int c = 0; c < cols; c++) {
        final cx = minX + (c + 0.5) * cell;
        final p = Offset(cx, cy);

        if (!_pointInRegion(p, contours)) continue;

        // Pass 1: nearest boundary sample.
        double d1Sq = double.infinity;
        Offset nearest = samples[0];
        for (final s in samples) {
          final dSq = (s - p).distanceSquared;
          if (dSq < d1Sq) {
            d1Sq = dSq;
            nearest = s;
          }
        }
        final d1 = sqrt(d1Sq);

        // Cells hugging the wall closer than the pruning scale can never be
        // skeleton at this lambda; skip pass 2 for them. (d1 < lambda/2 means
        // even a perfectly opposite wall pair would subtend < lambda... not
        // exactly, but it is a safe conservative floor: the inscribed-circle
        // diameter 2*d1 bounds the separation of any two equidistant samples.)
        if (2 * d1 + tol < lambda) continue;

        // Pass 2: does any sample nearly as close as d1 sit >= lambda away
        // from the nearest one? (The "two different walls" test.)
        final reach = d1 + tol;
        final reachSq = reach * reach;
        bool onAxis = false;
        for (final s in samples) {
          if ((s - p).distanceSquared > reachSq) continue;
          if ((s - nearest).distanceSquared >= lambdaSq) {
            onAxis = true;
            break;
          }
        }

        if (onAxis) survivors[r * cols + c] = true;
      }
    }

    // ---- 3. Link surviving cells 8-connected into an edge graph. ----------
    // Each undirected edge emitted ONCE by only probing the four "forward"
    // neighbors (E, S, SE, SW) from every survivor. Vertices are welded on the
    // lattice via the (r,c) -> index map, so shared endpoints share an index.
    final verts = <Offset>[];
    final vIndex = <int, int>{}; // (r * cols + c) -> vert index (0-based)
    final edges = <(int, int)>[];

    int vid(int r, int c) {
      final key = r * cols + c;
      final existing = vIndex[key];
      if (existing != null) return existing;
      verts.add(Offset(minX + (c + 0.5) * cell, minY + (r + 0.5) * cell));
      final id = verts.length - 1;
      vIndex[key] = id;
      return id;
    }

    bool alive(int r, int c) {
      if (r < 0 || r >= rows || c < 0 || c >= cols) return false;
      return survivors[r * cols + c];
    }

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        if (!survivors[r * cols + c]) continue;
        // Forward neighbors only: E, SW, S, SE.
        if (alive(r, c + 1)) edges.add((vid(r, c), vid(r, c + 1)));
        if (alive(r + 1, c - 1)) edges.add((vid(r, c), vid(r + 1, c - 1)));
        if (alive(r + 1, c)) edges.add((vid(r, c), vid(r + 1, c)));
        if (alive(r + 1, c + 1)) edges.add((vid(r, c), vid(r + 1, c + 1)));
      }
    }

    if (edges.isEmpty) return const MedialAxisResult([], []);

    // ---- 4. Drop degree-0 vertices (isolated noise cells). ----------------
    // Every vertex in vIndex was minted by an edge, so degree >= 1 already
    // holds for all EMITTED verts -- but survivors with no living neighbor
    // never minted a vertex at all, so nothing further is needed. The compact
    // remap below exists only to guarantee the verts list carries no stragglers
    // if the emission logic above ever changes; today it is a cheap identity
    // pass kept for safety.
    final used = List<bool>.filled(verts.length, false);
    for (final e in edges) {
      used[e.$1] = true;
      used[e.$2] = true;
    }
    final remap = List<int>.filled(verts.length, -1);
    final outVerts = <Offset>[];
    for (int i = 0; i < verts.length; i++) {
      if (!used[i]) continue;
      remap[i] = outVerts.length;
      outVerts.add(verts[i]);
    }
    final outEdges = <(int, int)>[
      for (final e in edges) (remap[e.$1], remap[e.$2]),
    ];

    // ---- 5. Snap branch tips (leaf nodes) to the boundary. ----------------
    // Because the skeleton is extracted on a discrete grid, pruning leaves
    // the tips of the branches floating inside the shape. If an exporter
    // just bridges them with a new line, it creates a harsh angle (a kink).
    // By moving the actual terminal node directly onto the nearest boundary
    // sample, the final skeleton segment stretches smoothly to the edge.
    final degrees = List<int>.filled(outVerts.length, 0);
    for (final e in outEdges) {
      degrees[e.$1]++;
      degrees[e.$2]++;
    }

    for (int i = 0; i < outVerts.length; i++) {
      if (degrees[i] == 1) { // It's a leaf node!
        final leafPt = outVerts[i];
        double minDistSq = double.infinity;
        Offset nearest = leafPt;
        
        for (final s in samples) {
          final distSq = (s - leafPt).distanceSquared;
          if (distSq < minDistSq) {
            minDistSq = distSq;
            nearest = s;
          }
        }
        // Move the node coordinate exactly onto the outline
        outVerts[i] = nearest;
      }
    }

    return MedialAxisResult(outVerts, outEdges);
  }

  // Even-odd point-in-region across ALL contours at once -- byte-for-byte the
  // rule the OBJ exporter's grid mode uses, so "inside" means the same thing to
  // the skeleton as it does to the fill mesh (holes carve both identically).
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