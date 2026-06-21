// lib/path_baker.dart

import 'dart:math';
import 'dart:ui';

/// One reconstructed node: a point plus the two explicit Bézier handle vectors,
/// using the SAME convention as CompassSplineNode --
///   handleIn  = offset FROM point TO the incoming control point
///   handleOut = offset FROM point TO the outgoing control point
/// A null handle means "no handle on that side" -- only happens at the two
/// endpoints of an OPEN contour. Closed contours always carry both.
class BakedNode {
  final Offset point;
  final Offset? handleIn;
  final Offset? handleOut;
  const BakedNode(this.point, {this.handleIn, this.handleOut});
}

/// One reconstructed contour of a baked boolean result.
///   isClosed -- closed loop (true for every filled boolean contour).
///   isHole   -- sits at ODD nesting depth under the even-odd rule, so the engine
///               emits it as a Subtract spline. Outer fills (even depth, including
///               re-fill islands sitting inside a hole) are false.
/// Contours come back sorted by nesting depth ASCENDING, so the engine can drop
/// them into the new layer in an order getLayerPath reproduces correctly: every
/// outer (add) is present before the hole (subtract) that cuts into it, and any
/// re-fill island (add) comes after the hole it lives in.
class BakedContour {
  final List<BakedNode> nodes;
  final bool isClosed;
  final bool isHole;
  const BakedContour(this.nodes, {required this.isClosed, required this.isHole});
}

/// Turns the opaque combined Path of a layer (from getLayerPath) into a set of
/// editable Bézier contours. Pure: depends only on dart:ui geometry + math, owns
/// no engine state, creates no CompassPoints. The engine consumes the result and
/// does all point-lifecycle / anchor / attach wiring on its side.
class PathBaker {
  /// [sampleSpacing]        -- arc-length gap between raw samples along a contour.
  ///                           Smaller = truer sampling of the real boundary (the
  ///                           fit then sparsifies it anyway).
  /// [fitTolerance]         -- max deviation (logical px) of a fitted cubic from
  ///                           the sampled points. Lower = higher fidelity, more
  ///                           nodes. ~0.6 is sub-pixel at 1x.
  /// [cornerThreshold]      -- turning angle (radians) above which a sample is a
  ///                           true corner, kept sharp (no smoothing across it).
  /// [minSamplesPerContour] -- floor on samples regardless of size, so a small
  ///                           smooth contour (e.g. a tiny circle) can't get so
  ///                           few samples that its gentle per-sample turn trips
  ///                           the corner detector and facets it.
  /// [maxSamplesPerContour] -- safety cap so a pathological giant path can't blow up.
  static List<BakedContour> bake(
    Path path, {
    double sampleSpacing = 3.0,
    double fitTolerance = 0.6,
    double cornerThreshold = 0.6, // ~34 degrees
    int minSamplesPerContour = 32,
    int maxSamplesPerContour = 3000,
  }) {
    final raw = <_RawContour>[];

    for (final metric in path.computeMetrics()) {
      if (metric.length < 1e-3) continue;

      final pts = _sampleContour(
          metric, sampleSpacing, minSamplesPerContour, maxSamplesPerContour);
      if (pts.length < 2) continue;

      final closed = metric.isClosed;
      final corners = _findCorners(pts, closed, cornerThreshold);
      final segs = _fitContour(pts, closed, corners, fitTolerance);
      if (segs.isEmpty) continue;

      final nodes = _segmentsToNodes(segs, closed);
      if (nodes.length < 2) continue;

      raw.add(_RawContour(nodes, closed));
    }

    if (raw.isEmpty) return [];

    // --- Nesting classification (even-odd) -----------------------------------
    // depth = how many OTHER contours contain this one's representative point.
    // Even depth is fill (add), odd is a hole (subtract). Holes from boolean ops
    // are strictly interior, so a single vertex classifies cleanly.
    final classified = <(int, _RawContour)>[];
    for (int i = 0; i < raw.length; i++) {
      final testPt = raw[i].nodes.first.point;
      int depth = 0;
      for (int j = 0; j < raw.length; j++) {
        if (i == j) continue;
        if (_pointInPolygon(testPt, raw[j].nodes)) depth++;
      }
      classified.add((depth, raw[i]));
    }

    // Ascending depth: depth-0 outers first (getLayerPath seeds its master on an
    // `add`), then depth-1 holes cut, then depth-2 islands union back, ... in the
    // exact order the boolean engine needs.
    classified.sort((a, b) => a.$1.compareTo(b.$1));

    return [
      for (final c in classified)
        BakedContour(c.$2.nodes, isClosed: c.$2.closed, isHole: c.$1.isOdd),
    ];
  }

  // ---------------------------------------------------------------------------
  // SAMPLING
  // ---------------------------------------------------------------------------

  static List<Offset> _sampleContour(
      PathMetric metric, double spacing, int minSamples, int maxSamples) {
    final length = metric.length;
    // Never sample the closing point at d == length: on a closed loop it equals
    // the start, and the fitter handles the seam itself.
    int count = (length / spacing).floor();
    if (count < minSamples) count = minSamples;
    if (count > maxSamples) count = maxSamples;

    final step = length / count;
    final out = <Offset>[];
    for (int i = 0; i < count; i++) {
      final t = metric.getTangentForOffset(i * step);
      if (t == null) continue;
      final p = t.position;
      // Drop exact consecutive duplicates (degenerate zero-length stretches).
      if (out.isNotEmpty && (p - out.last).distanceSquared < 1e-12) continue;
      out.add(p);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // CORNER DETECTION
  // ---------------------------------------------------------------------------

  static List<int> _findCorners(List<Offset> pts, bool closed, double threshold) {
    final corners = <int>[];
    final n = pts.length;
    if (n < 3) return corners;

    final start = closed ? 0 : 1;
    final end = closed ? n : n - 1;

    for (int i = start; i < end; i++) {
      final a = pts[(i - 1 + n) % n];
      final b = pts[i % n];
      final c = pts[(i + 1) % n];
      if (_turningAngle(a, b, c) > threshold) corners.add(i % n);
    }
    return corners;
  }

  static double _turningAngle(Offset a, Offset b, Offset c) {
    final v1 = _norm(b - a);
    final v2 = _norm(c - b);
    if (v1 == Offset.zero || v2 == Offset.zero) return 0.0;
    final dot = (v1.dx * v2.dx + v1.dy * v2.dy).clamp(-1.0, 1.0);
    return acos(dot);
  }

  // ---------------------------------------------------------------------------
  // CONTOUR FIT -> list of cubic segments (each = [P0, P1, P2, P3])
  // ---------------------------------------------------------------------------

  static List<List<Offset>> _fitContour(
      List<Offset> pts, bool closed, List<int> corners, double tol) {
    final segs = <List<Offset>>[];

    if (!closed) {
      final bounds = <int>[
        0,
        ...corners.where((c) => c > 0 && c < pts.length - 1),
        pts.length - 1
      ]..sort();
      for (int k = 0; k < bounds.length - 1; k++) {
        _fitRun(pts, bounds[k], bounds[k + 1], tol, segs);
      }
      return segs;
    }

    // Closed.
    final n = pts.length;
    if (corners.isEmpty) {
      // No real corner to break at. Use sample 0 as the seam, repeat it at the
      // end, and force G1 across the seam with one centered tangent so the loop
      // closes smoothly (one node, not a kink).
      final ext = [...pts, pts[0]];
      final seamTan = _norm(pts[1] - pts[n - 1]);
      _fitCubic(ext, 0, n, seamTan, -seamTan, tol, segs);
      return segs;
    }

    // Has corners: rotate so the loop STARTS at a corner, repeat that corner at
    // the end, and fit corner-to-corner runs. Both ends are the same sharp
    // corner, so node[0] gets independent in/out handles -> corner stays crisp.
    final s = corners.reduce((a, b) => a < b ? a : b);
    final rotated = <Offset>[for (int i = 0; i < n; i++) pts[(s + i) % n]];
    final ext = [...rotated, rotated[0]];

    final interior = <int>{};
    for (final c in corners) {
      final idx = (c - s) % n;
      if (idx > 0 && idx < n) interior.add(idx);
    }
    final bounds = <int>[0, ...interior, n]..sort();
    for (int k = 0; k < bounds.length - 1; k++) {
      _fitRun(ext, bounds[k], bounds[k + 1], tol, segs);
    }
    return segs;
  }

  // Fits an open run pts[first..last] with endpoint tangents taken from the run's
  // own end chords (independent at corners -> sharp).
  static void _fitRun(
      List<Offset> pts, int first, int last, double tol, List<List<Offset>> segs) {
    if (last - first < 1) return;
    final tan1 = _norm(pts[first + 1] - pts[first]);
    final tan2 = _norm(pts[last - 1] - pts[last]);
    _fitCubic(pts, first, last, tan1, tan2, tol, segs);
  }

  // ---------------------------------------------------------------------------
  // SCHNEIDER CUBIC FITTING (Graphics Gems), adapted to Offset math.
  // tHat1 leaves P0 forward; tHat2 leaves P3 backward (toward the interior).
  // ---------------------------------------------------------------------------

  static void _fitCubic(List<Offset> pts, int first, int last, Offset tHat1,
      Offset tHat2, double error, List<List<Offset>> out) {
    final nPts = last - first + 1;

    if (nPts == 2) {
      final dist = (pts[last] - pts[first]).distance / 3.0;
      out.add([
        pts[first],
        pts[first] + tHat1 * dist,
        pts[last] + tHat2 * dist,
        pts[last],
      ]);
      return;
    }

    var u = _chordLengthParameterize(pts, first, last);
    var bez = _generateBezier(pts, first, last, u, tHat1, tHat2);

    var (maxErrSq, split) = _computeMaxError(pts, first, last, bez, u);
    final errSq = error * error;

    if (maxErrSq < errSq) {
      out.add(bez);
      return;
    }

    // Within striking distance: a few reparameterization passes before giving up
    // and subdividing. Trims node count on long smooth runs.
    if (maxErrSq < errSq * 9.0) {
      for (int i = 0; i < 4; i++) {
        final uPrime = _reparameterize(pts, first, last, u, bez);
        bez = _generateBezier(pts, first, last, uPrime, tHat1, tHat2);
        (maxErrSq, split) = _computeMaxError(pts, first, last, bez, uPrime);
        if (maxErrSq < errSq) {
          out.add(bez);
          return;
        }
        u = uPrime;
      }
    }

    // Subdivide at the worst point and recurse, smoothing across the split.
    final tHatCenter = _centerTangent(pts, split);
    _fitCubic(pts, first, split, tHat1, tHatCenter, error, out);
    _fitCubic(pts, split, last, -tHatCenter, tHat2, error, out);
  }

  static List<Offset> _generateBezier(List<Offset> pts, int first, int last,
      List<double> u, Offset tHat1, Offset tHat2) {
    final nPts = last - first + 1;
    final p0 = pts[first];
    final p3 = pts[last];

    double c00 = 0, c01 = 0, c11 = 0, x0 = 0, x1 = 0;

    for (int i = 0; i < nPts; i++) {
      final ui = u[i];
      final b0 = _b0(ui), b1 = _b1(ui), b2 = _b2(ui), b3 = _b3(ui);
      final a0 = tHat1 * b1;
      final a1 = tHat2 * b2;

      c00 += a0.dx * a0.dx + a0.dy * a0.dy;
      c01 += a0.dx * a1.dx + a0.dy * a1.dy;
      c11 += a1.dx * a1.dx + a1.dy * a1.dy;

      final tmp = pts[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3));
      x0 += a0.dx * tmp.dx + a0.dy * tmp.dy;
      x1 += a1.dx * tmp.dx + a1.dy * tmp.dy;
    }

    final detC = c00 * c11 - c01 * c01;
    double alphaL = 0, alphaR = 0;
    if (detC.abs() > 1e-12) {
      alphaL = (x0 * c11 - c01 * x1) / detC;
      alphaR = (c00 * x1 - x0 * c01) / detC;
    }

    final segLen = (p3 - p0).distance;
    final eps = 1e-6 * segLen;
    if (alphaL < eps || alphaR < eps) {
      // Wu/Barsky heuristic fallback when the least-squares solve is degenerate.
      final d = segLen / 3.0;
      alphaL = d;
      alphaR = d;
    }

    return [p0, p0 + tHat1 * alphaL, p3 + tHat2 * alphaR, p3];
  }

  static (double, int) _computeMaxError(
      List<Offset> pts, int first, int last, List<Offset> bez, List<double> u) {
    double maxDistSq = 0;
    int split = (first + last) ~/ 2;
    for (int i = first + 1; i < last; i++) {
      final p = _bezier(3, bez, u[i - first]);
      final dSq = (p - pts[i]).distanceSquared;
      if (dSq >= maxDistSq) {
        maxDistSq = dSq;
        split = i;
      }
    }
    return (maxDistSq, split);
  }

  static List<double> _reparameterize(
      List<Offset> pts, int first, int last, List<double> u, List<Offset> bez) {
    final out = <double>[];
    for (int i = first; i <= last; i++) {
      out.add(_newton(bez, pts[i], u[i - first]));
    }
    return out;
  }

  static double _newton(List<Offset> q, Offset p, double u) {
    final q1 = [(q[1] - q[0]) * 3.0, (q[2] - q[1]) * 3.0, (q[3] - q[2]) * 3.0];
    final q2 = [(q1[1] - q1[0]) * 2.0, (q1[2] - q1[1]) * 2.0];

    final qu = _bezier(3, q, u);
    final q1u = _bezier(2, q1, u);
    final q2u = _bezier(1, q2, u);

    final numr = (qu.dx - p.dx) * q1u.dx + (qu.dy - p.dy) * q1u.dy;
    final den = q1u.dx * q1u.dx + q1u.dy * q1u.dy +
        (qu.dx - p.dx) * q2u.dx + (qu.dy - p.dy) * q2u.dy;

    if (den.abs() < 1e-12) return u;
    return u - numr / den;
  }

  static List<double> _chordLengthParameterize(
      List<Offset> pts, int first, int last) {
    final u = <double>[0.0];
    for (int i = first + 1; i <= last; i++) {
      u.add(u.last + (pts[i] - pts[i - 1]).distance);
    }
    final total = u.last;
    if (total > 1e-12) {
      for (int i = 0; i < u.length; i++) {
        u[i] /= total;
      }
    }
    return u;
  }

  static Offset _centerTangent(List<Offset> pts, int center) {
    final v1 = pts[center - 1] - pts[center];
    final v2 = pts[center] - pts[center + 1];
    return _norm((v1 + v2) * 0.5);
  }

  // de Casteljau evaluation of a degree-`degree` Bézier.
  static Offset _bezier(int degree, List<Offset> v, double t) {
    final tmp = List<Offset>.of(v);
    for (int i = 1; i <= degree; i++) {
      for (int j = 0; j <= degree - i; j++) {
        tmp[j] = tmp[j] * (1.0 - t) + tmp[j + 1] * t;
      }
    }
    return tmp[0];
  }

  static double _b0(double u) => (1 - u) * (1 - u) * (1 - u);
  static double _b1(double u) => 3 * u * (1 - u) * (1 - u);
  static double _b2(double u) => 3 * u * u * (1 - u);
  static double _b3(double u) => u * u * u;

  // ---------------------------------------------------------------------------
  // SEGMENTS -> NODES
  // ---------------------------------------------------------------------------

  static List<BakedNode> _segmentsToNodes(List<List<Offset>> segs, bool closed) {
    final nodes = <BakedNode>[];
    final m = segs.length;
    if (m == 0) return nodes;

    if (closed) {
      // m nodes: node i sits at segs[i].P0; handleIn comes from the PREVIOUS
      // segment (wrapping), handleOut from its own. The closing segment segs[m-1]
      // (whose P3 == segs[0].P0) supplies node[0].handleIn.
      for (int i = 0; i < m; i++) {
        final cur = segs[i];
        final prev = segs[(i - 1 + m) % m];
        nodes.add(BakedNode(
          cur[0],
          handleIn: prev[2] - prev[3],
          handleOut: cur[1] - cur[0],
        ));
      }
    } else {
      for (int i = 0; i < m; i++) {
        final cur = segs[i];
        nodes.add(BakedNode(
          cur[0],
          handleIn: i > 0 ? segs[i - 1][2] - segs[i - 1][3] : null,
          handleOut: cur[1] - cur[0],
        ));
      }
      final last = segs[m - 1];
      nodes.add(BakedNode(last[3], handleIn: last[2] - last[3], handleOut: null));
    }
    return nodes;
  }

  // ---------------------------------------------------------------------------
  // NESTING (even-odd point-in-polygon over node points; straight edges are fine
  // for containment classification since holes sit well inside their outers).
  // ---------------------------------------------------------------------------

  static bool _pointInPolygon(Offset p, List<BakedNode> poly) {
    bool inside = false;
    final n = poly.length;
    for (int i = 0, j = n - 1; i < n; j = i++) {
      final a = poly[i].point;
      final b = poly[j].point;
      final intersects = ((a.dy > p.dy) != (b.dy > p.dy)) &&
          (p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx);
      if (intersects) inside = !inside;
    }
    return inside;
  }

  static Offset _norm(Offset v) {
    final d = v.distance;
    return d > 1e-12 ? v / d : Offset.zero;
  }
}

class _RawContour {
  final List<BakedNode> nodes;
  final bool closed;
  _RawContour(this.nodes, this.closed);
}