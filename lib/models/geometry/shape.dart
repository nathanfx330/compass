// lib/models/geometry/shape.dart

import 'package:flutter/material.dart';

import 'gradient.dart'; // <--- NEW: per-shape linear fill gradient

/// Defines how this shape interacts with the shapes below it
enum CompassBooleanOp { add, subtract, intersect, none }

/// One stroke region in a shape's outward-stacked stroke stack.
///
/// A shape owns an ORDERED list of these (CompassShape.strokeRegions). Each is a
/// band carved/unioned against the geometry beneath the shape, applied in list
/// order BEFORE the shape's fill. Each region has its own [op], its own [width]
/// (its own slider in the Properties panel), and -- for ADD bands -- its own
/// [color]. They are NOT keyed off the layer stroke width or fill color.
///
/// GEOMETRY -- the stack marches OUTWARD from the shape's outline. The layer feeds
/// each region a running inner offset: region 0 straddles the outline (inner edge
/// at r - w0/2 via the primitive's own centering... see below), and each later
/// region's inner edge butts against the previous region's outer edge. The exact
/// placement is the primitive's job in getStrokeOutlinePath(width, innerOffset);
/// for a circle the band is the annulus [r + innerOffset .. r + innerOffset + w].
///
/// [op] here is only ever add / subtract / intersect. There is no `none`: a region
/// that should do nothing is simply removed from the list (deleting the row in the
/// layers panel is the off-switch). `none` remains in CompassBooleanOp only for the
/// FILL [operation].
///
/// [color] PAINT semantics -- only an ADD band paints, so only an ADD band uses
/// [color]:
///   * add       -> paints a filled ring; [color] is the ring's fill. null means
///                  "inherit the layer fill color" (the original behavior, so old
///                  stacks and any band left uncolored look exactly as before).
///   * subtract  -> removes area, paints nothing; [color] is inert.
///   * intersect -> a stacking/masking op, paints nothing here; [color] is inert.
/// A colored add band STILL participates in the boolean silhouette (it is real
/// geometry that shapes above/below can carve) -- the only thing [color] changes is
/// what that additive band is painted with. op decides presence vs absence; [color]
/// decides what an additive band looks like.
class StrokeRegion {
  CompassBooleanOp op;
  double width;

  /// Fill color for an ADD band. null => inherit the owning layer's fill color.
  /// Ignored for subtract/intersect (those paint nothing).
  Color? color;

  StrokeRegion({
    this.op = CompassBooleanOp.subtract,
    this.width = 8.0,
    this.color,
  });

  StrokeRegion copy() => StrokeRegion(op: op, width: width, color: color);
}

/// Abstract base class for all visual geometry.
abstract class CompassShape {
  /// How this shape's FILL participates in the layer's boolean walk.
  CompassBooleanOp operation;

  /// The shape's OUTWARD-STACKED stroke stack: an ordered list of bands, each with
  /// its own op and width, applied in order BEFORE the fill. Empty = no stroke
  /// (the opt-in default, so every pre-existing shape is untouched).
  ///
  /// Independent of [operation]: a circle can be fill-ADD (a disk) while its stroke
  /// stack carves one or more annuli out of the geometry beneath it -- the Ubuntu
  /// rim break is a single subtract region; concentric tree-rings are several
  /// regions with alternating ops, each ADD band optionally its own color.
  ///
  /// ORDER vs FILL: the layer applies the whole stroke stack (in list order) BEFORE
  /// the fill op, so a stroke-subtract carves the LOWER geometry and a shape's
  /// stroke never carves its own fill. Within the stack, region i+1 stacks OUTWARD
  /// from region i (see StrokeRegion + getStrokeOutlinePath).
  ///
  /// Each region carries its OWN width (its own Properties-panel slider) and, for
  /// ADD bands, its OWN color. This is unrelated to the layer's hairline strokeWidth
  /// and to the W-key variable-width ribbon (CompassSplineNode.widthLeft/
  /// widthRight), both untouched.
  List<StrokeRegion> strokeRegions;

  /// OPTIONAL per-shape LINEAR FILL GRADIENT. null (the default) => this shape
  /// fills flat with the layer color, exactly as before: nothing is touched for
  /// any pre-existing shape.
  ///
  /// When non-null AND renderable (>=2 stops -> a real shader; a lone seed stop
  /// paints a solid of its own color), the shape leaves the layer's FLAT boolean
  /// fill union entirely and is painted in its own pass, clipped to its own
  /// boolean-carved silhouette -- the SAME render category the gradient MESH uses
  /// (getLayerMeshClipPath / the renderer's separate mesh pass). This is what lets
  /// one shape carry a fill the single layer-color union cannot express, and it
  /// inherits the mesh's one caveat: a gradient `add` shape does NOT merge
  /// silhouettes with a neighboring solid `add` shape -- each paints independently.
  ///
  /// This is UNRELATED to:
  ///   * the layer fill color (a flat, whole-layer property);
  ///   * the gradient MESH (a Coons color surface, a different shape type);
  ///   * stroke-region ADD-band colors (those paint rings, not the fill).
  /// The gradient's stops are POINTS in engine.points, attached to the shape's
  /// primary structural point, so they drag / rotate / cohere / serialize / undo
  /// through the ordinary point machinery -- see gradient.dart.
  LinearGradientFill? gradient;

  bool isVisible;

  CompassShape({
    this.operation = CompassBooleanOp.add,
    List<StrokeRegion>? strokeRegions,
    this.gradient,
    this.isVisible = true,
  }) : strokeRegions = strokeRegions ?? [];

  Path getPath();

  /// The shape's stroke expressed as a FILLED REGION (outline -> area): a band of
  /// thickness [width] whose INNER edge sits [innerOffset] outboard of the shape's
  /// outline. This is the seam that lets an outline act as a boolean operand, and
  /// the [innerOffset] is what lets the layer stack regions outward -- it passes
  /// the cumulative outer reach of the regions already placed.
  ///
  /// For region 0 the layer passes innerOffset = -width/2, so the first band
  /// straddles the outline (inner edge r - w/2, outer edge r + w/2) exactly as the
  /// single-stroke design did. For each later region the layer passes the previous
  /// region's outer edge, so bands butt outward with no gap or overlap.
  ///
  /// Base implementation returns an EMPTY Path: a shape gains stroke-region
  /// behavior only once it overrides this. The layer's boolean walk treats an empty
  /// contribution as a no-op, so a shape that has not overridden this contributes
  /// nothing no matter how many regions are in its list.
  ///
  /// Each primitive builds this exactly -- circle -> annulus, rect -> outer rrect
  /// minus inner, line -> capsule, spiral/xspline -> constant-width ribbon -- since
  /// dart:ui exposes no public stroke-to-fill.
  Path getStrokeOutlinePath(double width, double innerOffset) => Path();

  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false});
}