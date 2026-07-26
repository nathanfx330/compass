// /lib/models/layer.dart

import 'package:flutter/material.dart';
import 'geometry/shape.dart';
import 'geometry/spline.dart';
import 'geometry/mesh.dart';
import 'geometry/gradient.dart';

/// Which axis the mirror modifier reflects across.
/// vertical   => a vertical LINE at x = mirrorPosition (left/right symmetry)
/// horizontal => a horizontal LINE at y = mirrorPosition (top/bottom symmetry)
enum MirrorAxis { vertical, horizontal }

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

  // ==========================================================================
  // MIRROR MODIFIER (Blender-style, non-destructive)
  // ==========================================================================
  // When enabled, the RESOLVED boolean result of this layer is unioned with its
  // reflection across the axis line -- at path-getter level, so the canvas,
  // PNG, SVG, area strokes, colored bands, and OBJ export all inherit symmetry
  // for free, and "Bake to X-Spline" doubles as Blender's "apply modifier".
  //
  // The reflection is a RULE evaluated per frame, never baked points: no
  // duplicate geometry to manage, and toggling off restores the original half
  // untouched. The axis line itself is draggable on the canvas (scaffolding),
  // which just writes mirrorPosition.
  //
  // Mirroring happens AFTER the full boolean walk (post-resolve), so a
  // subtract on the master half carves the mirrored half symmetrically --
  // exactly the Blender mental model of "model one half, get both".
  bool mirrorEnabled = false;
  MirrorAxis mirrorAxis = MirrorAxis.vertical;
  double mirrorPosition = 0.0;

  final List<CompassShape> shapes = [];

  CompassLayer({
    required this.name,
    this.color = const Color(0xFF222222),
    this.strokeColor = Colors.transparent,
    this.strokeWidth = 2.0,
    String? id,
  }) : id = id ?? UniqueKey().toString();

  /// The affine reflection for the current axis, as a Matrix4.
  /// Vertical axis at x=p:   x' = 2p - x
  /// Horizontal axis at y=p: y' = 2p - y
  ///
  /// Exposed publicly so the renderer can replay self-painted geometry through
  /// the same transform and exporters can reuse the exact mirror rule.
  Matrix4 get mirrorMatrix {
    final matrix = Matrix4.identity();

    if (mirrorAxis == MirrorAxis.vertical) {
      matrix.translate(mirrorPosition, 0.0);
      matrix.scale(-1.0, 1.0, 1.0);
      matrix.translate(-mirrorPosition, 0.0);
    } else {
      matrix.translate(0.0, mirrorPosition);
      matrix.scale(1.0, -1.0, 1.0);
      matrix.translate(0.0, -mirrorPosition);
    }

    return matrix;
  }

  /// Applies the mirror modifier to a fully resolved master path.
  ///
  /// Plain union is used intentionally: the mirror replicates the completed
  /// result, so the normal empty-master seeding rules do not apply here.
  Path applyMirror(Path master) {
    if (!mirrorEnabled) return master;
    if (master.computeMetrics().isEmpty) return master;

    final reflected = master.transform(mirrorMatrix.storage);
    return Path.combine(
      PathOperation.union,
      master,
      reflected,
    );
  }

  /// Applies one `(path, operation)` contribution to [master].
  ///
  /// An ADD operation seeds an empty master. SUBTRACT and INTERSECT cannot
  /// establish geometry when nothing exists yet.
  Path _combine(
    Path master,
    Path contribution,
    CompassBooleanOp operation,
  ) {
    if (operation == CompassBooleanOp.none) return master;
    if (contribution.computeMetrics().isEmpty) return master;

    if (master.computeMetrics().isEmpty) {
      return operation == CompassBooleanOp.add
          ? contribution
          : master;
    }

    switch (operation) {
      case CompassBooleanOp.add:
        return Path.combine(
          PathOperation.union,
          master,
          contribution,
        );

      case CompassBooleanOp.subtract:
        return Path.combine(
          PathOperation.difference,
          master,
          contribution,
        );

      case CompassBooleanOp.intersect:
        return Path.combine(
          PathOperation.intersect,
          master,
          contribution,
        );

      case CompassBooleanOp.none:
        return master;
    }
  }

  /// Resolves the outward-stacked stroke regions belonging to [shape].
  ///
  /// Each record contains the region, its width, and the accumulated inner
  /// offset. The first region begins directly at the shape boundary.
  List<
      ({
        StrokeRegion region,
        double width,
        double innerOffset,
      })> _strokeBands(CompassShape shape) {
    final output = <
        ({
          StrokeRegion region,
          double width,
          double innerOffset,
        })>[];

    var offset = 0.0;

    for (final region in shape.strokeRegions) {
      final width = region.width;
      if (width <= 0) continue;

      output.add((
        region: region,
        width: width,
        innerOffset: offset,
      ));

      offset += width;
    }

    return output;
  }

  /// Applies a shape's stroke stack to [master] in list order.
  ///
  /// With [addsAllowed] disabled, ADD regions are ignored while SUBTRACT and
  /// INTERSECT regions may only carve an existing master.
  Path _applyStrokeStack(
    Path master,
    CompassShape shape, {
    required bool addsAllowed,
  }) {
    for (final bandData in _strokeBands(shape)) {
      final operation = bandData.region.op;

      final shouldApply = addsAllowed ||
          operation == CompassBooleanOp.subtract ||
          operation == CompassBooleanOp.intersect;

      if (!shouldApply) continue;

      final band = shape.getStrokeOutlinePath(
        bandData.width,
        bandData.innerOffset,
      );

      if (addsAllowed) {
        master = _combine(
          master,
          band,
          operation,
        );
      } else if (master.computeMetrics().isNotEmpty &&
          band.computeMetrics().isNotEmpty) {
        master = operation == CompassBooleanOp.subtract
            ? Path.combine(
                PathOperation.difference,
                master,
                band,
              )
            : Path.combine(
                PathOperation.intersect,
                master,
                band,
              );
      }
    }

    return master;
  }

  /// Whether any stroke region on [shape] can carve geometry.
  bool _hasCarvingStroke(CompassShape shape) {
    for (final region in shape.strokeRegions) {
      if (region.op == CompassBooleanOp.subtract ||
          region.op == CompassBooleanOp.intersect) {
        return true;
      }
    }

    return false;
  }

  /// Whether [shape]'s fill is painted separately in the linear-gradient pass.
  ///
  /// Only ADD shapes with at least one gradient stop are lifted. A subtract or
  /// intersect shape remains a Boolean operator and does not paint a gradient.
  static bool hasLiftedGradientFill(CompassShape shape) {
    return shape.operation == CompassBooleanOp.add &&
        shape.gradient != null &&
        shape.gradient!.isRenderable;
  }

  /// The master Boolean path intended to receive the uniform outline stroke.
  ///
  /// Gradient meshes are excluded because they are self-painted. Linear-gradient
  /// shapes remain included so the layer hairline still follows their boundary.
  Path getLayerPath() {
    var master = Path();

    for (final shape in shapes) {
      if (!shape.isVisible) continue;

      if (shape is CompassMesh) {
        continue;
      }

      master = _applyStrokeStack(
        master,
        shape,
        addsAllowed: true,
      );

      if (shape.operation == CompassBooleanOp.none) {
        continue;
      }

      final isAddWidthSpline =
          shape.operation == CompassBooleanOp.add &&
              shape is CompassXSpline &&
              shape.hasWidthProfile;

      if (!isAddWidthSpline) {
        master = _combine(
          master,
          shape.getPath(),
          shape.operation,
        );
      }
    }

    return applyMirror(master);
  }

  /// The master Boolean path intended to receive the flat layer fill.
  ///
  /// Linear-gradient ADD fills and gradient meshes are excluded because they
  /// paint themselves in dedicated renderer passes. Stroke regions belonging to
  /// gradient shapes still participate here.
  Path getLayerFillPath() {
    var master = Path();

    for (final shape in shapes) {
      if (!shape.isVisible) continue;

      if (shape is CompassMesh) {
        continue;
      }

      master = _applyStrokeStack(
        master,
        shape,
        addsAllowed: true,
      );

      if (shape.operation == CompassBooleanOp.none ||
          hasLiftedGradientFill(shape)) {
        continue;
      }

      Path? fillPath;

      if (shape is CompassXSpline &&
          shape.hasWidthProfile &&
          shape.operation == CompassBooleanOp.add) {
        if (shape.isClosed) {
          fillPath = shape.getCenterPath()
            ..fillType = PathFillType.evenOdd;
        }
      } else {
        fillPath = shape.getPath();
      }

      if (fillPath != null) {
        master = _combine(
          master,
          fillPath,
          shape.operation,
        );
      }
    }

    return applyMirror(master);
  }

  /// Returns custom-colored ADD stroke bands in their painting order.
  ///
  /// The paths are clipped against the resolved flat-fill master so colored
  /// bands cannot repaint portions removed by later Boolean operations.
  List<(Path, Color)> getStrokeAddBandOverpaints(
    Path fillMaster,
  ) {
    if (fillMaster.computeMetrics().isEmpty) {
      return const [];
    }

    final output = <(Path, Color)>[];

    for (final shape in shapes) {
      if (!shape.isVisible) continue;
      if (shape is CompassMesh) continue;

      for (final bandData in _strokeBands(shape)) {
        if (bandData.region.op != CompassBooleanOp.add) {
          continue;
        }

        final color = bandData.region.color;
        if (color == null) continue;

        final band = shape.getStrokeOutlinePath(
          bandData.width,
          bandData.innerOffset,
        );

        if (band.computeMetrics().isEmpty) {
          continue;
        }

        final clipped = Path.combine(
          PathOperation.intersect,
          fillMaster,
          band,
        );

        if (clipped.computeMetrics().isEmpty) {
          continue;
        }

        output.add((
          applyMirror(clipped),
          color,
        ));
      }
    }

    return output;
  }

  /// The resolved path for variable-width area strokes.
  Path getLayerStrokeAreaPath() {
    var master = Path();

    for (final shape in shapes) {
      if (!shape.isVisible) continue;

      if (shape.operation == CompassBooleanOp.none &&
          !_hasCarvingStroke(shape)) {
        continue;
      }

      master = _applyStrokeStack(
        master,
        shape,
        addsAllowed: false,
      );

      if (shape.operation == CompassBooleanOp.none) {
        continue;
      }

      final shapePath = shape.getPath();
      if (shapePath.computeMetrics().isEmpty) {
        continue;
      }

      if (shape.operation == CompassBooleanOp.add) {
        if (shape is CompassXSpline &&
            shape.hasWidthProfile &&
            !hasLiftedGradientFill(shape)) {
          if (master.computeMetrics().isEmpty) {
            master = shapePath;
          } else {
            master = Path.combine(
              PathOperation.union,
              master,
              shapePath,
            );
          }
        }

        continue;
      }

      if (master.computeMetrics().isEmpty) {
        continue;
      }

      if (shape.operation == CompassBooleanOp.subtract) {
        master = Path.combine(
          PathOperation.difference,
          master,
          shapePath,
        );
      } else if (shape.operation == CompassBooleanOp.intersect) {
        master = Path.combine(
          PathOperation.intersect,
          master,
          shapePath,
        );
      }
    }

    return applyMirror(master);
  }

  /// The clip silhouette for one gradient mesh.
  ///
  /// This path is deliberately not mirrored. The renderer mirrors the clip and
  /// mesh vertices together in a transformed second drawing pass.
  Path getLayerMeshClipPath(CompassMesh mesh) {
    var clip = mesh.getPath();

    if (clip.computeMetrics().isEmpty) {
      return clip;
    }

    for (final shape in shapes) {
      if (!shape.isVisible) continue;

      if (shape is CompassMesh) {
        continue;
      }

      clip = _applyStrokeStack(
        clip,
        shape,
        addsAllowed: false,
      );

      if (shape.operation == CompassBooleanOp.subtract) {
        final cutter = shape.getPath();

        if (cutter.computeMetrics().isEmpty) {
          continue;
        }

        clip = Path.combine(
          PathOperation.difference,
          clip,
          cutter,
        );
      } else if (shape.operation == CompassBooleanOp.intersect) {
        final cutter = shape.getPath();

        if (cutter.computeMetrics().isEmpty) {
          continue;
        }

        clip = Path.combine(
          PathOperation.intersect,
          clip,
          cutter,
        );
      }
    }

    return clip;
  }

  /// The visible clip silhouette for one lifted gradient-fill [target].
  ///
  /// The renderer paints flat layer geometry first and lifted gradients in a
  /// later pass. Without compensating here, a lower gradient would overpaint an
  /// ordinary ADD shape that appears later in [shapes], making the gradient look
  /// as though it had jumped to the top of the layer.
  ///
  /// Only shapes after [target] are replayed because those are the shapes above
  /// it in this layer's Boolean and Z-order:
  ///
  /// - A later ordinary ADD fill occludes the gradient.
  /// - A later SUBTRACT or INTERSECT carves the gradient.
  /// - A later lifted gradient naturally paints afterward and remains unclipped,
  ///   preserving normal alpha compositing.
  /// - A gradient mesh naturally paints after gradients and remains unclipped.
  ///
  /// Stroke regions follow the same stroke-before-fill ordering as the primary
  /// Boolean walk. Null-color ADD bands belong to the early flat-fill pass and
  /// therefore occlude the gradient. Custom-colored ADD bands paint after the
  /// gradient and composite naturally. SUBTRACT and INTERSECT bands carve.
  ///
  /// The returned clip is deliberately not mirrored. The renderer reflects the
  /// clip path and reuses the same world-space shader for the mirrored half.
  Path getLayerGradientClipPath(CompassShape target) {
    final targetIndex = shapes.indexOf(target);

    if (targetIndex == -1 || !target.isVisible) {
      return Path();
    }

    var clip = target.getPath();

    if (clip.computeMetrics().isEmpty) {
      return clip;
    }

    for (var index = targetIndex + 1;
        index < shapes.length;
        index++) {
      final shape = shapes[index];

      if (!shape.isVisible) {
        continue;
      }

      // Meshes paint after the gradient pass and already composite correctly.
      // They also never act as Boolean cutters.
      if (shape is CompassMesh) {
        continue;
      }

      // -----------------------------------------------------------------------
      // Later shape's stroke stack
      // -----------------------------------------------------------------------
      for (final bandData in _strokeBands(shape)) {
        final region = bandData.region;

        if (region.op == CompassBooleanOp.none) {
          continue;
        }

        final band = shape.getStrokeOutlinePath(
          bandData.width,
          bandData.innerOffset,
        );

        if (band.computeMetrics().isEmpty) {
          continue;
        }

        switch (region.op) {
          case CompassBooleanOp.add:
            // Null-color bands are painted in the early layer-color pass. Remove
            // their area from this later gradient pass so they remain above it.
            //
            // Custom-colored bands repaint after gradients and should naturally
            // alpha-composite over them, so those are not removed here.
            if (region.color == null) {
              clip = Path.combine(
                PathOperation.difference,
                clip,
                band,
              );
            }
            break;

          case CompassBooleanOp.subtract:
            clip = Path.combine(
              PathOperation.difference,
              clip,
              band,
            );
            break;

          case CompassBooleanOp.intersect:
            clip = Path.combine(
              PathOperation.intersect,
              clip,
              band,
            );
            break;

          case CompassBooleanOp.none:
            break;
        }

        if (clip.computeMetrics().isEmpty) {
          return clip;
        }
      }

      // -----------------------------------------------------------------------
      // Later shape's fill
      // -----------------------------------------------------------------------
      switch (shape.operation) {
        case CompassBooleanOp.add:
          // A later lifted gradient paints later in the same gradient pass, so
          // retaining the lower gradient beneath it preserves alpha compositing.
          if (hasLiftedGradientFill(shape)) {
            break;
          }

          Path? occluder;

          // Match getLayerFillPath for ADD width splines. Only a closed center
          // fill belongs to the early flat-fill pass. The ribbon area is painted
          // later and already sits above gradients through normal compositing.
          if (shape is CompassXSpline &&
              shape.hasWidthProfile) {
            if (shape.isClosed) {
              occluder = shape.getCenterPath()
                ..fillType = PathFillType.evenOdd;
            }
          } else {
            occluder = shape.getPath();
          }

          if (occluder != null &&
              occluder.computeMetrics().isNotEmpty) {
            clip = Path.combine(
              PathOperation.difference,
              clip,
              occluder,
            );
          }
          break;

        case CompassBooleanOp.subtract:
          final cutter = shape.getPath();

          if (cutter.computeMetrics().isNotEmpty) {
            clip = Path.combine(
              PathOperation.difference,
              clip,
              cutter,
            );
          }
          break;

        case CompassBooleanOp.intersect:
          final cutter = shape.getPath();

          if (cutter.computeMetrics().isNotEmpty) {
            clip = Path.combine(
              PathOperation.intersect,
              clip,
              cutter,
            );
          }
          break;

        case CompassBooleanOp.none:
          break;
      }

      if (clip.computeMetrics().isEmpty) {
        return clip;
      }
    }

    return clip;
  }
}