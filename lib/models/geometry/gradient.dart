// /lib/models/geometry/gradient.dart

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'point.dart';

/// The shader geometry used by a per-shape gradient fill.
///
/// [linear] uses the first and last stops as the two ends of a straight axis.
///
/// [circular] uses the first stop as the center and the last stop as a radius
/// handle. Interior stops are positioned by their normalized distance from the
/// center and are displayed along the center-to-radius guide.
enum GradientFillType {
  linear,
  circular,
}

/// One color stop of a shape gradient.
///
/// A stop is a real [CompassPoint], just like every other editable point in
/// Compass. Its point lives in the engine's point collection and carries the
/// stop's world-space position, while [color] carries its visual value.
///
/// The first and last stops in a [LinearGradientFill] are the gradient's two
/// geometry handles. Stops between them are interior color stops.
class GradientStop {
  final CompassPoint point;
  Color color;

  GradientStop({
    required this.point,
    required this.color,
  });
}

/// A per-shape linear or circular fill gradient.
///
/// This is independent of the gradient-mesh system. A gradient mesh is a Coons
/// surface, while this class produces a flat shader clipped to an ordinary
/// shape's resolved silhouette.
///
/// The historical class name is intentionally retained so existing constructor
/// calls and serialized document loading paths remain source-compatible.
///
/// ## Stop-list invariant
///
/// When two or more stops exist:
///
/// - `stops.first` is the start/center geometry handle.
/// - `stops.last` is the end/radius geometry handle.
/// - Every stop between them is an interior color stop.
///
/// New interior stops must therefore be inserted before the final stop rather
/// than appended. Use [insertInteriorStop] to preserve that invariant.
///
/// ## Linear stop positions
///
/// A stop's normalized position is calculated by projecting its world-space
/// point onto the start-to-end axis.
///
/// ## Circular stop positions
///
/// The first stop is the center. A stop's normalized position is its distance
/// from that center divided by the center-to-radius-handle distance.
///
/// Interior points are displayed and dragged on the same finite guide segment
/// in both modes. [projectOntoAxis] converts an arbitrary pointer position to
/// the corresponding point on that guide.
///
/// ## Degenerate state
///
/// A gradient with fewer than two stops, or with coincident geometry handles,
/// renders as a solid fill using its first available color.
class LinearGradientFill {
  static const double _axisEpsilon = 1e-9;

  final List<GradientStop> stops;

  /// The current gradient geometry.
  ///
  /// Defaults to [GradientFillType.linear] so documents created before circular
  /// gradients existed keep their original appearance.
  GradientFillType type;

  LinearGradientFill({
    required this.stops,
    this.type = GradientFillType.linear,
  });

  bool get isRenderable => stops.isNotEmpty;

  bool get isLinear => type == GradientFillType.linear;

  bool get isCircular => type == GradientFillType.circular;

  /// The first geometry handle.
  ///
  /// In linear mode this is the start endpoint. In circular mode it is the
  /// gradient center.
  GradientStop? get startStop => stops.isEmpty ? null : stops.first;

  /// The second geometry handle.
  ///
  /// In linear mode this is the end endpoint. In circular mode it controls the
  /// radius. A one-stop gradient does not yet have a distinct second handle.
  GradientStop? get endStop => stops.length < 2 ? null : stops.last;

  /// All color stops between the two geometry handles.
  Iterable<GradientStop> get interiorStops {
    if (stops.length <= 2) {
      return const <GradientStop>[];
    }

    return stops.getRange(1, stops.length - 1);
  }

  Offset _pointOffset(GradientStop stop) {
    return Offset(
      stop.point.x.value,
      stop.point.y.value,
    );
  }

  /// The world-space editing guide from the first stop to the last stop.
  ///
  /// In circular mode this is the center-to-radius guide. It is still exposed as
  /// [axis] so the existing renderer, context menu, and drag code can remain
  /// shared between both gradient types.
  ///
  /// Returns `null` until the gradient has two stops.
  (Offset, Offset)? get axis {
    if (stops.length < 2) {
      return null;
    }

    return (
      _pointOffset(stops.first),
      _pointOffset(stops.last),
    );
  }

  double get _axisLengthSquared {
    final currentAxis = axis;
    if (currentAxis == null) {
      return 0.0;
    }

    final direction = currentAxis.$2 - currentAxis.$1;
    return direction.dx * direction.dx +
        direction.dy * direction.dy;
  }

  double get _axisLength {
    final lengthSquared = _axisLengthSquared;
    if (lengthSquared < _axisEpsilon) {
      return 0.0;
    }

    return math.sqrt(lengthSquared);
  }

  bool get hasUsableAxis =>
      stops.length >= 2 &&
      _axisLengthSquared >= _axisEpsilon;

  /// The circular gradient radius in world-space units.
  ///
  /// Returns `null` when the gradient has not yet established a usable guide.
  double? get circularRadius {
    if (!hasUsableAxis) {
      return null;
    }

    return _axisLength;
  }

  /// The single color to paint when no usable shader geometry exists.
  ///
  /// Returns `null` when a real linear or circular shader can be built.
  Color? get solidColor {
    if (stops.isEmpty) {
      return null;
    }

    if (!hasUsableAxis) {
      return stops.first.color;
    }

    return null;
  }

  /// Whether [stop] is one of the two geometry handles.
  bool isEndpoint(GradientStop stop) {
    if (stops.isEmpty) {
      return false;
    }

    if (identical(stop, stops.first)) {
      return true;
    }

    return stops.length >= 2 &&
        identical(stop, stops.last);
  }

  /// Projects a world-space position into the gradient's normalized range.
  ///
  /// Linear mode uses orthogonal projection onto the guide.
  ///
  /// Circular mode uses radial distance from the first stop divided by the
  /// current radius. This means dragging around the center changes a stop's
  /// radius naturally; [projectOntoAxis] then places the visible stop back onto
  /// the center-to-radius guide.
  ///
  /// With [clampToAxis] enabled, the result is constrained to `[0, 1]`.
  ///
  /// Returns `0` when the gradient has no usable guide.
  double projectPosition(
    Offset worldPosition, {
    bool clampToAxis = true,
  }) {
    final currentAxis = axis;
    if (currentAxis == null) {
      return 0.0;
    }

    final (start, end) = currentAxis;
    final direction = end - start;
    final lengthSquared =
        direction.dx * direction.dx +
        direction.dy * direction.dy;

    if (lengthSquared < _axisEpsilon) {
      return 0.0;
    }

    double projected;

    if (isCircular) {
      projected =
          (worldPosition - start).distance /
          math.sqrt(lengthSquared);
    } else {
      final relative = worldPosition - start;
      projected =
          (relative.dx * direction.dx +
              relative.dy * direction.dy) /
          lengthSquared;
    }

    if (!clampToAxis) {
      return projected;
    }

    return projected.clamp(0.0, 1.0).toDouble();
  }

  /// Returns the normalized position of [stop].
  double positionOf(GradientStop stop) {
    return projectPosition(_pointOffset(stop));
  }

  /// Returns the world-space point at normalized position [t] on the editing
  /// guide.
  ///
  /// With [clampToAxis] enabled, values outside `[0, 1]` are clamped to the
  /// nearest geometry handle.
  Offset pointAt(
    double t, {
    bool clampToAxis = true,
  }) {
    final currentAxis = axis;
    if (currentAxis == null) {
      return stops.isEmpty
          ? Offset.zero
          : _pointOffset(stops.first);
    }

    final (start, end) = currentAxis;
    final resolvedT = clampToAxis
        ? t.clamp(0.0, 1.0).toDouble()
        : t;

    return Offset.lerp(start, end, resolvedT) ?? start;
  }

  /// Returns the corresponding world-space point on the finite editing guide.
  ///
  /// For a linear gradient this is the closest orthogonal point on the axis.
  /// For a circular gradient it is the point on the center-to-radius guide with
  /// the same normalized radial distance.
  Offset projectOntoAxis(Offset worldPosition) {
    return pointAt(projectPosition(worldPosition));
  }

  /// Inserts [stop] as an interior color stop without replacing the existing
  /// final geometry handle.
  ///
  /// The stop is placed in normalized gradient order. Its [CompassPoint] should
  /// already be positioned at the intended world-space location, preferably
  /// using [projectOntoAxis].
  ///
  /// When the gradient has zero or one stops, the new stop is appended because
  /// it is still establishing the initial geometry.
  void insertInteriorStop(GradientStop stop) {
    if (stops.contains(stop)) {
      return;
    }

    if (stops.length < 2) {
      stops.add(stop);
      return;
    }

    final newPosition = positionOf(stop);
    var insertionIndex = stops.length - 1;

    for (var index = 1;
        index < stops.length - 1;
        index++) {
      final existingPosition = positionOf(stops[index]);

      if (newPosition < existingPosition) {
        insertionIndex = index;
        break;
      }
    }

    stops.insert(insertionIndex, stop);
  }

  /// Returns the currently rendered color at normalized position [t].
  ///
  /// This lets the context-menu interaction create a new stop without changing
  /// the appearance of the gradient: sample the existing color first, then add
  /// the new stop using that color.
  Color? colorAt(double t) {
    if (stops.isEmpty) {
      return null;
    }

    if (stops.length == 1) {
      return stops.first.color;
    }

    final resolved = resolvedStops();
    if (resolved.isEmpty) {
      return stops.first.color;
    }

    final clampedT = t.clamp(0.0, 1.0).toDouble();

    if (clampedT <= resolved.first.$1) {
      return resolved.first.$2;
    }

    for (var index = 0;
        index < resolved.length - 1;
        index++) {
      final left = resolved[index];
      final right = resolved[index + 1];

      if (clampedT > right.$1) {
        continue;
      }

      final span = right.$1 - left.$1;

      if (span.abs() < _axisEpsilon) {
        return right.$2;
      }

      final localT =
          (clampedT - left.$1) / span;

      return Color.lerp(
            left.$2,
            right.$2,
            localT,
          ) ??
          right.$2;
    }

    return resolved.last.$2;
  }

  /// Returns the currently rendered color at [worldPosition].
  Color? colorAtPosition(Offset worldPosition) {
    return colorAt(projectPosition(worldPosition));
  }

  /// Resolves every stop into a sorted `(position, color)` pair suitable for
  /// Flutter's linear and radial gradient shader constructors.
  ///
  /// Equal adjacent positions are valid and create a hard color transition.
  List<(double, Color)> resolvedStops() {
    if (stops.length < 2) {
      return const <(double, Color)>[];
    }

    final output = <(double, Color)>[];

    for (final stop in stops) {
      output.add((
        positionOf(stop),
        stop.color,
      ));
    }

    output.sort(
      (left, right) =>
          left.$1.compareTo(right.$1),
    );

    return output;
  }

  /// Builds the active linear or circular fill shader.
  ///
  /// Returns `null` when fewer than two stops exist or the two geometry handles
  /// are coincident. The caller should use [solidColor] in that state.
  ui.Shader? buildShader() {
    final currentAxis = axis;

    if (currentAxis == null || !hasUsableAxis) {
      return null;
    }

    final (start, end) = currentAxis;
    final resolved = resolvedStops();

    final positions = <double>[
      for (final stop in resolved) stop.$1,
    ];

    final colors = <Color>[
      for (final stop in resolved) stop.$2,
    ];

    switch (type) {
      case GradientFillType.linear:
        return ui.Gradient.linear(
          start,
          end,
          colors,
          positions,
        );

      case GradientFillType.circular:
        return ui.Gradient.radial(
          start,
          (end - start).distance,
          colors,
          positions,
        );
    }
  }
}