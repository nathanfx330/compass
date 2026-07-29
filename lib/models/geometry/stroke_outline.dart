// lib/models/geometry/stroke_outline.dart

import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A compact, reusable flattened representation of a path for outward stroke
/// expansion.
///
/// The previous implementation represented every sampled segment as a capsule
/// (a quad plus many circles). That was robust, but it produced paths containing
/// hundreds or thousands of overlapping subpaths. Those paths were extremely
/// expensive whenever the layer Boolean engine combined them during a repaint.
///
/// This representation samples each contour once and builds one compact offset
/// contour for each requested distance. Adjacent stroke rings can therefore
/// share their cumulative dilations, and subsequent Path.combine calls operate
/// on simple polygons instead of a pile of overlapping capsules.
class StrokeOutlineGeometry {
  final Path _source;
  final bool sourceIsArea;
  final bool cleanAreaDilation;
  final List<_StrokeContour> _contours;

  // A multi-ring stack repeatedly asks for the same cumulative distances
  // (for example w1 is band 1's outer edge and band 2's inner edge). Cache
  // those dilations on the prepared contour set so each distance is offset and
  // Boolean-cleaned at most once.
  final Map<double, Path> _dilationCache = <double, Path>{};

  StrokeOutlineGeometry._(
    this._source,
    this.sourceIsArea,
    this.cleanAreaDilation,
    this._contours,
  );

  /// Returns the source expanded by [distance].
  ///
  /// Filled silhouettes expand their outer boundaries and shrink their holes.
  /// Open centerlines become round-capped ribbons.
  Path buildDilation(double distance) {
    final cacheKey = distance <= StrokeOutlineBuilder.epsilon
        ? 0.0
        : distance;
    final cached = _dilationCache[cacheKey];
    if (cached != null) return cached;

    final dilation = cacheKey == 0.0
        ? (sourceIsArea ? Path.from(_source) : Path())
        : (sourceIsArea
            ? _buildAreaDilation(cacheKey)
            : _buildCenterlineRibbon(cacheKey));

    _dilationCache[cacheKey] = dilation;
    return dilation;
  }

  Path _buildAreaDilation(double distance) {
    final result = Path()..fillType = PathFillType.evenOdd;

    for (final contour in _contours) {
      if (!contour.isClosed || contour.points.length < 3) continue;

      final expanded = <Offset>[];
      final count = contour.points.length;

      for (var i = 0; i < count; i++) {
        final tangent = contour.tangents[i];
        final leftNormal = Offset(-tangent.dy, tangent.dx);
        expanded.add(
          contour.points[i] +
              leftNormal * (distance * contour.outwardNormalSign),
        );
      }

      if (expanded.length >= 3) {
        _addSmoothClosedContour(
          result,
          expanded,
          contour.tangents,
        );
      }
    }

    if (!cleanAreaDilation || _isPathEmpty(result)) {
      return result;
    }

    // Boolean results can contain tight concavities and newly-created hole
    // contours. Unioning the smooth offset shell with the exact source cleans
    // small self-crossings and guarantees the dilation never loses source area.
    final cleaned = Path.combine(
      PathOperation.union,
      _source,
      result,
    )..fillType = PathFillType.evenOdd;
    return cleaned;
  }

  static bool _isPathEmpty(Path path) {
    if (path.getBounds() != Rect.zero) return false;
    return path.computeMetrics().isEmpty;
  }

  /// Emits a compact cubic contour instead of a visibly faceted polygon.
  ///
  /// The source PathMetric already provides a tangent at every sample. Using
  /// those tangents for cubic handles preserves smooth circle/spline curvature
  /// after a Boolean cut while a conservative alignment test falls back to a
  /// straight segment at genuine corners, preventing loops and overshoot.
  static void _addSmoothClosedContour(
    Path path,
    List<Offset> points,
    List<Offset> tangents,
  ) {
    if (points.length < 3 || tangents.length != points.length) return;

    path.moveTo(points.first.dx, points.first.dy);

    for (var i = 0; i < points.length; i++) {
      final next = (i + 1) % points.length;
      final a = points[i];
      final b = points[next];
      final delta = b - a;
      final chord = delta.distance;
      if (chord <= StrokeOutlineBuilder.epsilon) continue;

      final direction = delta / chord;
      final ta = tangents[i];
      final tb = tangents[next];
      final aAlignment = ta.dx * direction.dx + ta.dy * direction.dy;
      final bAlignment = tb.dx * direction.dx + tb.dy * direction.dy;

      // A tangent that points away from the next sample signals a hard Boolean
      // corner or a numerically unstable cusp. A line is safer and preserves the
      // intended corner instead of producing a cubic hook.
      if (aAlignment < 0.15 || bAlignment < 0.15) {
        path.lineTo(b.dx, b.dy);
        continue;
      }

      final handle = chord / 3.0;
      final c1 = a + ta * handle;
      final c2 = b - tb * handle;
      path.cubicTo(
        c1.dx,
        c1.dy,
        c2.dx,
        c2.dy,
        b.dx,
        b.dy,
      );
    }

    path.close();
  }

  Path _buildCenterlineRibbon(double radius) {
    final result = Path()..fillType = PathFillType.evenOdd;

    for (final contour in _contours) {
      if (contour.points.isEmpty) continue;

      if (contour.points.length == 1) {
        result.addOval(
          Rect.fromCircle(center: contour.points.first, radius: radius),
        );
        continue;
      }

      final left = <Offset>[];
      final right = <Offset>[];

      for (var i = 0; i < contour.points.length; i++) {
        final tangent = contour.tangents[i];
        final normal = Offset(-tangent.dy, tangent.dx) * radius;
        left.add(contour.points[i] + normal);
        right.add(contour.points[i] - normal);
      }

      if (contour.isClosed) {
        final polygon = <Offset>[...left, ...right.reversed];
        if (polygon.length >= 3) result.addPolygon(polygon, true);
        continue;
      }

      result.moveTo(left.first.dx, left.first.dy);
      for (var i = 1; i < left.length; i++) {
        result.lineTo(left[i].dx, left[i].dy);
      }

      result.arcToPoint(
        right.last,
        radius: Radius.circular(radius),
        clockwise: false,
      );

      for (var i = right.length - 2; i >= 0; i--) {
        result.lineTo(right[i].dx, right[i].dy);
      }

      result.arcToPoint(
        left.first,
        radius: Radius.circular(radius),
        clockwise: false,
      );
      result.close();
    }

    return result;
  }
}

class _StrokeContour {
  final List<Offset> points;
  final List<Offset> tangents;
  final bool isClosed;

  /// +1 means the tangent's left normal points outside the filled area; -1
  /// means its right normal does. It is only used for area contours.
  final double outwardNormalSign;

  const _StrokeContour({
    required this.points,
    required this.tangents,
    required this.isClosed,
    required this.outwardNormalSign,
  });
}

/// Geometry helpers for outward-stacked filled stroke regions.
class StrokeOutlineBuilder {
  StrokeOutlineBuilder._();

  static const double epsilon = 0.0001;
  static const double _finalSpacing = 2.0;
  static const double _interactiveSpacing = 12.0;
  static const int _maxSamplesPerContour = 900;
  static const int _maxInteractiveSamplesPerContour = 120;

  /// Flattens [source] once so several ring widths can reuse the same contour
  /// samples.
  static StrokeOutlineGeometry prepare(
    Path source, {
    required bool sourceIsArea,
    bool interactive = false,
    bool cleanAreaDilation = false,
  }) {
    final contours = <_StrokeContour>[];
    final spacing = interactive ? _interactiveSpacing : _finalSpacing;
    final maxSamples = interactive
        ? _maxInteractiveSamplesPerContour
        : _maxSamplesPerContour;

    for (final metric in source.computeMetrics(forceClosed: false)) {
      final length = metric.length;
      if (!length.isFinite || length <= epsilon) continue;

      var segmentCount = (length / spacing).ceil();
      segmentCount = segmentCount.clamp(1, maxSamples).toInt();
      if (metric.isClosed && segmentCount < 12) segmentCount = 12;

      final points = <Offset>[];
      final tangents = <Offset>[];
      final sampleCount = metric.isClosed ? segmentCount : segmentCount + 1;

      for (var i = 0; i < sampleCount; i++) {
        final t = i / segmentCount;
        final metricOffset = (length * t).clamp(0.0, length).toDouble();
        final sample = metric.getTangentForOffset(metricOffset);
        if (sample == null) continue;

        final vectorLength = sample.vector.distance;
        final tangent = vectorLength <= epsilon
            ? const Offset(1.0, 0.0)
            : sample.vector / vectorLength;

        if (points.isNotEmpty &&
            (sample.position - points.last).distance <= epsilon) {
          tangents[tangents.length - 1] = tangent;
          continue;
        }

        points.add(sample.position);
        tangents.add(tangent);
      }

      if (points.isEmpty) continue;

      final outwardSign = sourceIsArea && metric.isClosed
          ? _resolveOutwardNormalSign(
              source,
              points,
              tangents,
              maxProbes: interactive ? 6 : 24,
            )
          : 1.0;

      contours.add(
        _StrokeContour(
          points: points,
          tangents: tangents,
          isClosed: metric.isClosed,
          outwardNormalSign: outwardSign,
        ),
      );
    }

    return StrokeOutlineGeometry._(
      Path.from(source)..fillType = source.fillType,
      sourceIsArea,
      cleanAreaDilation,
      contours,
    );
  }

  /// Convenience API for callers that only need one band. X-splines use
  /// [prepare] directly and cache the prepared geometry plus cumulative
  /// dilations across the entire stroke stack.
  static Path buildOutwardStrokeBand(
    Path source,
    double width,
    double innerOffset, {
    required bool sourceIsArea,
  }) {
    final geometry = prepare(source, sourceIsArea: sourceIsArea);
    return buildBandFromGeometry(
      geometry,
      width,
      innerOffset,
    );
  }

  static Path buildBandFromGeometry(
    StrokeOutlineGeometry geometry,
    double width,
    double innerOffset,
  ) {
    final empty = Path()..fillType = PathFillType.evenOdd;
    if (width <= epsilon) return empty;

    final innerDistance = math.max(0.0, innerOffset).toDouble();
    final outerDistance = innerDistance + width;
    final outer = geometry.buildDilation(outerDistance);

    if (_isEmpty(outer)) return empty;

    final inner = innerDistance <= epsilon
        ? (geometry.sourceIsArea ? geometry.buildDilation(0.0) : Path())
        : geometry.buildDilation(innerDistance);

    if (_isEmpty(inner)) {
      outer.fillType = PathFillType.evenOdd;
      return outer;
    }

    if (geometry.cleanAreaDilation) {
      // Reflow contours come from a Boolean-resolved silhouette and may contain
      // nested holes, concave turns, and touching islands. Let Skia canonicalize
      // the actual band instead of relying on compound-path parity, which can
      // expose tiny loops or spikes around a newly subtracted spline boundary.
      return Path.combine(
        PathOperation.difference,
        outer,
        inner,
      )..fillType = PathFillType.evenOdd;
    }

    // inner is guaranteed to lie inside outer for cumulative dilations. An
    // even-odd compound path therefore represents outer-minus-inner directly,
    // avoiding one of Skia's most expensive Path.combine calls per stroke ring.
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(outer, Offset.zero)
      ..addPath(inner, Offset.zero);
  }

  static bool _isEmpty(Path path) {
    if (path.getBounds() != Rect.zero) return false;
    return path.computeMetrics().isEmpty;
  }

  static double _resolveOutwardNormalSign(
    Path source,
    List<Offset> points,
    List<Offset> tangents, {
    required int maxProbes,
  }) {
    const probeDistance = 0.75;
    var leftVotes = 0;
    var rightVotes = 0;

    // Sampling every point is unnecessary and can make complex paths expensive.
    // During a drag, six probes are enough for a stable preview; the finalized
    // contour restores the full probe budget.
    final probeBudget = math.max(1, maxProbes).toInt();
    final stride = math.max(1, (points.length / probeBudget).ceil()).toInt();
    for (var i = 0; i < points.length; i += stride) {
      final tangent = tangents[i];
      final left = Offset(-tangent.dy, tangent.dx);
      final leftInside = source.contains(points[i] + left * probeDistance);
      final rightInside = source.contains(points[i] - left * probeDistance);

      if (!leftInside && rightInside) {
        leftVotes++;
      } else if (leftInside && !rightInside) {
        rightVotes++;
      }
    }

    if (leftVotes != rightVotes) {
      return leftVotes > rightVotes ? 1.0 : -1.0;
    }

    // Fallback for very thin/self-touching contours where both probes can land
    // on the same fill side. In Flutter's downward-positive coordinate system,
    // positive signed area corresponds to a visually clockwise contour whose
    // left normal points outward.
    var signedAreaTwice = 0.0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      signedAreaTwice += a.dx * b.dy - b.dx * a.dy;
    }

    return signedAreaTwice >= 0.0 ? 1.0 : -1.0;
  }
}
