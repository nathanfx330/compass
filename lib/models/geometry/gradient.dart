// lib/models/geometry/gradient.dart

import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import 'point.dart';

/// One color stop of a shape gradient. A stop is a POINT (source of truth, like
/// everything else in Compass) carrying a color. The point lives in
/// engine.points and is attached to the owning shape's primary structural point,
/// so it drags, rotates, coheres, serializes, and undoes through the exact same
/// machinery every other point uses -- no bespoke drag path, no bespoke GC.
class GradientStop {
  final CompassPoint point;
  Color color;

  GradientStop({required this.point, required this.color});
}

/// A per-shape LINEAR fill gradient. Independent of the layer fill color AND of
/// the gradient MESH system (that is a Coons surface; this is a flat fill shader
/// on an ordinary shape's silhouette).
///
/// AXIS MODEL: the gradient runs along the line from the FIRST stop to the LAST
/// stop (in list order). Every stop's parametric position t is its scalar
/// projection onto that axis, clamped to [0,1]; the two endpoints are therefore
/// t=0 and t=1 by construction. The (position,color) pairs are sorted ascending
/// before the shader is built, satisfying ui.Gradient.linear's non-decreasing
/// stops contract even if the user has dragged stops out of projection order.
///
/// DEGENERATE: a gradient with <2 stops renders as a SOLID fill of its single
/// stop color -- the "Make Gradient" seed state before a second stop is added.
/// 0 stops should never occur (Make Gradient always seeds one).
///
/// FUTURE (radial): add a `type` discriminant selecting ui.Gradient.radial with
/// the first stop as center and |last-first| as radius. The stop list and the
/// entire interaction/render/serialize layer are already type-agnostic, so
/// radial is a shader swap here, not a rebuild upstream.
class LinearGradientFill {
  final List<GradientStop> stops;

  LinearGradientFill({required this.stops});

  bool get isRenderable => stops.isNotEmpty;

  /// The single color to paint when the gradient is degenerate (<2 stops), else
  /// null (a real shader is available). Caller paints a solid fill with this.
  Color? get solidColor =>
      stops.length >= 2 ? null : (stops.isEmpty ? null : stops.first.color);

  Offset _pt(GradientStop s) => Offset(s.point.x.value, s.point.y.value);

  /// The axis endpoints in world space (first -> last stop). Meaningful only
  /// when there are >=2 stops; returned for the renderer's dashed axis line.
  (Offset, Offset)? get axis =>
      stops.length >= 2 ? (_pt(stops.first), _pt(stops.last)) : null;

  /// Projection of every stop onto the first->last axis, clamped [0,1], paired
  /// with its color and sorted ascending -- exactly the form ui.Gradient.linear
  /// consumes. Endpoints land at 0 and 1 by construction; a stop dragged past an
  /// endpoint simply clamps.
  List<(double, Color)> _resolvedStops() {
    if (stops.length < 2) return const [];
    final a = _pt(stops.first);
    final b = _pt(stops.last);
    final axis = b - a;
    final len2 = axis.dx * axis.dx + axis.dy * axis.dy;

    final out = <(double, Color)>[];
    for (final s in stops) {
      double t;
      if (len2 < 1e-9) {
        t = 0.0; // coincident endpoints: degenerate axis, everything at 0
      } else {
        final rel = _pt(s) - a;
        t = ((rel.dx * axis.dx + rel.dy * axis.dy) / len2).clamp(0.0, 1.0);
      }
      out.add((t, s.color));
    }
    out.sort((x, y) => x.$1.compareTo(y.$1));
    return out;
  }

  /// Builds the fill shader, or null when the gradient is degenerate (<2 stops)
  /// -- the caller then paints a solid [solidColor]. Equal adjacent positions
  /// are legal (they read as a hard color transition); only decreasing order is
  /// illegal, and the sort above forbids that.
  ui.Shader? buildShader() {
    if (stops.length < 2) return null;
    final (a, b) = axis!;
    final resolved = _resolvedStops();
    final positions = [for (final r in resolved) r.$1];
    final colors = [for (final r in resolved) r.$2];
    return ui.Gradient.linear(a, b, colors, positions);
  }
}