// /lib/models/layer.dart

import 'package:flutter/material.dart';
import 'geometry/shape.dart';
import 'geometry/point.dart';
import 'geometry/line.dart';
import 'geometry/circle.dart';
import 'geometry/spiral.dart';
import 'geometry/rectangle.dart';
import 'geometry/spline.dart';
import 'geometry/mesh.dart';
import 'geometry/gradient.dart';
import 'geometry/image.dart';
import 'geometry/stroke_outline.dart';

extension _FastPathState on Path {
  /// Most live Boolean paths have non-zero bounds. In that overwhelmingly
  /// common case getBounds() answers emptiness without walking every contour,
  /// while the metrics fallback preserves exact behavior for degenerate paths.
  bool get isEffectivelyEmpty {
    if (getBounds() != Rect.zero) return false;
    return computeMetrics().isEmpty;
  }

  bool get isEffectivelyNotEmpty => !isEffectivelyEmpty;
}

/// Which axis the mirror modifier reflects across.
/// vertical   => a vertical LINE at x = mirrorPosition (left/right symmetry)
/// horizontal => a horizontal LINE at y = mirrorPosition (top/bottom symmetry)
enum MirrorAxis { vertical, horizontal }

/// Paths the live canvas needs for one layer. Keeping them together lets a
/// controller-only repaint (hover, pan, key preview) reuse the expensive
/// Boolean result as long as the engine document revision has not changed.
class CompassLayerRenderGeometry {
  final Path fillPath;
  final Path outlinePath;
  final Path strokeAreaPath;
  final List<(Path, Color)> strokeOverpaints;
  final Rect bounds;

  CompassLayerRenderGeometry({
    required this.fillPath,
    required this.outlinePath,
    required this.strokeAreaPath,
    required this.strokeOverpaints,
    required this.bounds,
  });
}

class _LayerMasterPaths {
  final Path fillPath;
  final Path outlinePath;
  final Path strokeAreaPath;

  const _LayerMasterPaths({
    required this.fillPath,
    required this.outlinePath,
    required this.strokeAreaPath,
  });
}

class _ResolvedStrokeBand {
  final StrokeRegion region;
  final Path path;

  const _ResolvedStrokeBand({
    required this.region,
    required this.path,
  });
}

class _ResolvedStrokeStack {
  final bool reflowed;
  final List<_ResolvedStrokeBand> bands;

  _ResolvedStrokeStack({
    required this.reflowed,
    required this.bands,
  });
}

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

  int? _renderGeometrySignature;
  CompassLayerRenderGeometry? _renderGeometryCache;

  int? _clipCacheSignature;
  final Map<CompassShape, Path> _selfPaintedClipCache = {};
  final Map<CompassImage, Path> _imagePaintClipCache = {};
  final Map<CompassMesh, Path> _meshClipCache = {};

  int? _strokeReflowTopologySignature;
  final Map<CompassShape, _ResolvedStrokeStack> _strokeReflowCache = {};
  final Map<CompassShape, int> _strokeReflowShapeSignatures = {};
  final Map<CompassShape, Path> _strokeForegroundCoverageCache = {};
  final Map<CompassShape, int> _strokeForegroundCoverageSignatures = {};

  // Shape signatures are expensive for dense splines and meshes. The renderer
  // asks for [geometrySignature] immediately before [getRenderGeometry], so
  // retain that one-pass snapshot and reuse it throughout the render resolve.
  // Non-render callers still compute signatures directly, preserving export and
  // serialization correctness when no canvas frame has run first.
  final Map<CompassShape, int> _shapeGeometrySignatureSnapshot = {};
  int? _shapeGeometrySnapshotLayerSignature;
  bool _useShapeGeometrySignatureSnapshot = false;

  CompassLayer({
    required this.name,
    this.color = const Color(0xFF222222),
    this.strokeColor = Colors.transparent,
    this.strokeWidth = 2.0,
    String? id,
  }) : id = id ?? UniqueKey().toString();

  int _pointSignature(CompassPoint point) => Object.hash(
        point.x.value,
        point.y.value,
      );

  int _shapeGeometrySignature(CompassShape shape) {
    var signature = Object.hash(
      identityHashCode(shape),
      shape.isVisible,
      shape.operation,
      shape.strokeRegions.length,
    );

    for (final region in shape.strokeRegions) {
      signature = Object.hash(
        signature,
        region.op,
        region.width,
        region.color?.value,
      );
    }

    final gradient = shape.gradient;
    if (gradient != null) {
      signature = Object.hash(signature, gradient.type, gradient.stops.length);
      for (final stop in gradient.stops) {
        signature = Object.hash(
          signature,
          _pointSignature(stop.point),
          stop.color.value,
        );
      }
    }

    if (shape is CompassLine) {
      return Object.hash(
        signature,
        _pointSignature(shape.start),
        _pointSignature(shape.end),
      );
    }

    if (shape is CompassCircle) {
      return Object.hash(
        signature,
        _pointSignature(shape.center),
        shape.radius.value,
      );
    }

    if (shape is CompassSpiral) {
      return Object.hash(
        signature,
        _pointSignature(shape.center),
        _pointSignature(shape.startPoint),
        shape.isClockwise,
        shape.revolutions,
      );
    }

    if (shape is CompassRectangle) {
      return Object.hash(
        signature,
        _pointSignature(shape.p1),
        _pointSignature(shape.p2),
        shape.cornerRadius.value,
        shape.isSquare,
      );
    }

    if (shape is CompassImage) {
      return Object.hash(
        signature,
        _pointSignature(shape.origin),
        _pointSignature(shape.xHandle),
        _pointSignature(shape.yHandle),
      );
    }

    if (shape is CompassXSpline) {
      signature = Object.hash(
        signature,
        shape.isClosed,
        shape.nodes.length,
      );
      for (final node in shape.nodes) {
        signature = Object.hash(
          signature,
          _pointSignature(node.point),
          node.tension.value,
          node.widthLeft.value,
          node.widthRight.value,
          node.cornerRadius.value,
          node.miterSize.value,
          node.point.isBeingDragged,
          node.handleIn?.dx,
          node.handleIn?.dy,
          node.handleOut?.dx,
          node.handleOut?.dy,
        );
      }
      return signature;
    }

    if (shape is CompassMesh) {
      signature = Object.hash(
        signature,
        shape.rows,
        shape.cols,
        shape.nodes.length,
      );
      for (final node in shape.nodes) {
        signature = Object.hash(
          signature,
          _pointSignature(node.point),
          node.tension.value,
        );
      }
      return signature;
    }

    return signature;
  }

  int _refreshGeometrySignatureSnapshot() {
    _shapeGeometrySignatureSnapshot.clear();

    var signature = Object.hash(
      mirrorEnabled,
      mirrorAxis,
      mirrorPosition,
      shapes.length,
    );
    for (final shape in shapes) {
      final shapeSignature = _shapeGeometrySignature(shape);
      _shapeGeometrySignatureSnapshot[shape] = shapeSignature;
      signature = Object.hash(signature, shapeSignature);
    }

    _shapeGeometrySnapshotLayerSignature = signature;
    return signature;
  }

  int _shapeGeometrySignatureForResolution(CompassShape shape) {
    if (_useShapeGeometrySignatureSnapshot) {
      final cached = _shapeGeometrySignatureSnapshot[shape];
      if (cached != null) return cached;
    }
    return _shapeGeometrySignature(shape);
  }

  T _withShapeGeometrySignatureSnapshot<T>(
    int signature,
    T Function() action,
  ) {
    if (_shapeGeometrySnapshotLayerSignature != signature) {
      _refreshGeometrySignatureSnapshot();
    }

    final previous = _useShapeGeometrySignatureSnapshot;
    _useShapeGeometrySignatureSnapshot = true;
    try {
      return action();
    } finally {
      _useShapeGeometrySignatureSnapshot = previous;
    }
  }

  /// A layer-local geometry signature. UI-only engine notifications and edits in
  /// other layers no longer invalidate this layer's Boolean or clip caches.
  int get geometrySignature => _refreshGeometrySignatureSnapshot();

  _LayerMasterPaths _resolveRenderMasterPaths({
    required bool needsSeparateOutline,
    required bool hasAreaStrokeSeed,
  }) {
    var fillMaster = Path();
    var outlineMaster = fillMaster;
    var outlineSharesFill = true;
    var strokeAreaMaster = Path();
    final liftedImages = <CompassImage>[];

    for (final shape in shapes) {
      if (!shape.isVisible || shape is CompassMesh) continue;

      // Fill and outline are identical for most of the walk. While they share
      // one master, replay each primary stroke stack only once. They fork only
      // when a lifted fill or a width-profile spline gives the two passes
      // genuinely different semantics.
      if (outlineSharesFill) {
        fillMaster = _applyPrimaryStrokeStack(fillMaster, shape);
        outlineMaster = fillMaster;
      } else {
        fillMaster = _applyPrimaryStrokeStack(fillMaster, shape);
        outlineMaster = _applyPrimaryStrokeStack(outlineMaster, shape);
      }

      if (hasAreaStrokeSeed &&
          !(shape.operation == CompassBooleanOp.none &&
              !_hasCarvingStroke(shape))) {
        strokeAreaMaster = _applyStrokeStack(
          strokeAreaMaster,
          shape,
          addsAllowed: false,
        );
      }

      if (shape.operation == CompassBooleanOp.none) continue;

      Path? sharedShapePath;
      Path? fillContribution;
      Path? outlineContribution;

      final isAddWidthSpline = shape is CompassXSpline &&
          shape.operation == CompassBooleanOp.add &&
          shape.hasWidthProfile;

      // ADD images are lifted into their own paint pass. Their outline uses the
      // final resolved mask and is appended after all disconnected INTERSECT
      // operands have been collected.
      if (shape is CompassImage &&
          shape.operation == CompassBooleanOp.add) {
        liftedImages.add(shape);
      } else if (!isAddWidthSpline) {
        sharedShapePath = shape.getPath();
        outlineContribution = sharedShapePath;
      }

      if (!hasLiftedSelfPaintedFill(shape)) {
        if (isAddWidthSpline) {
          final spline = shape as CompassXSpline;
          if (spline.isClosed) {
            fillContribution = spline.getCenterPath()
              ..fillType = PathFillType.evenOdd;
          }
        } else {
          sharedShapePath ??= shape.getPath();
          fillContribution = sharedShapePath;
        }
      }

      if (!needsSeparateOutline) {
        if (fillContribution != null) {
          fillMaster = _combine(
            fillMaster,
            fillContribution,
            shape.operation,
          );
        }
        outlineMaster = fillMaster;
      } else if (outlineSharesFill &&
          identical(fillContribution, outlineContribution)) {
        if (fillContribution != null) {
          fillMaster = _combine(
            fillMaster,
            fillContribution,
            shape.operation,
          );
        }
        outlineMaster = fillMaster;
      } else {
        final sharedMaster = fillMaster;
        if (fillContribution != null) {
          fillMaster = _combine(
            sharedMaster,
            fillContribution,
            shape.operation,
          );
        }
        if (outlineContribution != null) {
          outlineMaster = _combine(
            outlineSharesFill ? sharedMaster : outlineMaster,
            outlineContribution,
            shape.operation,
          );
        } else if (outlineSharesFill) {
          outlineMaster = sharedMaster;
        }
        outlineSharesFill = false;
      }

      if (!hasAreaStrokeSeed) continue;

      sharedShapePath ??= shape.getPath();
      if (sharedShapePath.isEffectivelyEmpty) continue;

      if (shape.operation == CompassBooleanOp.add) {
        if (shape is CompassXSpline &&
            shape.hasWidthProfile &&
            !hasLiftedGradientFill(shape)) {
          strokeAreaMaster = strokeAreaMaster.isEffectivelyEmpty
              ? sharedShapePath
              : Path.combine(
                  PathOperation.union,
                  strokeAreaMaster,
                  sharedShapePath,
                );
        }
      } else if (strokeAreaMaster.isEffectivelyNotEmpty) {
        if (shape.operation == CompassBooleanOp.subtract) {
          strokeAreaMaster = Path.combine(
            PathOperation.difference,
            strokeAreaMaster,
            sharedShapePath,
          );
        } else if (shape.operation == CompassBooleanOp.intersect) {
          strokeAreaMaster = Path.combine(
            PathOperation.intersect,
            strokeAreaMaster,
            sharedShapePath,
          );
        }
      }
    }

    if (needsSeparateOutline && liftedImages.isNotEmpty) {
      if (outlineSharesFill) {
        outlineMaster = fillMaster;
        outlineSharesFill = false;
      }
      for (final image in liftedImages) {
        final imageMask = getLayerImageMaskPath(image);
        if (imageMask.isEffectivelyEmpty) continue;
        outlineMaster = outlineMaster.isEffectivelyEmpty
            ? imageMask
            : Path.combine(
                PathOperation.union,
                outlineMaster,
                imageMask,
              );
      }
    }

    if (outlineSharesFill || !needsSeparateOutline) {
      fillMaster = _applyPostBooleanStrokeReflow(fillMaster);
      outlineMaster = fillMaster;
    } else {
      fillMaster = _applyPostBooleanStrokeReflow(fillMaster);
      outlineMaster = _applyPostBooleanStrokeReflow(outlineMaster);
    }

    if (mirrorEnabled) {
      if (identical(fillMaster, outlineMaster)) {
        fillMaster = applyMirror(fillMaster);
        outlineMaster = fillMaster;
      } else {
        fillMaster = applyMirror(fillMaster);
        outlineMaster = applyMirror(outlineMaster);
      }
      strokeAreaMaster = applyMirror(strokeAreaMaster);
    }

    return _LayerMasterPaths(
      fillPath: fillMaster,
      outlinePath: outlineMaster,
      strokeAreaPath: strokeAreaMaster,
    );
  }

  /// Resolves the three expensive master paths once per engine revision.
  ///
  /// The canvas repaints for many controller-only events that do not mutate the
  /// document. Before this cache every hover and pan recomputed the full layer
  /// Boolean graph, including all spline stroke bands.
  CompassLayerRenderGeometry getRenderGeometry({int? signature}) {
    var resolvedSignature = signature;
    if (resolvedSignature == null ||
        _shapeGeometrySnapshotLayerSignature != resolvedSignature) {
      resolvedSignature = _refreshGeometrySignatureSnapshot();
    }

    if (_renderGeometrySignature == resolvedSignature &&
        _renderGeometryCache != null) {
      return _renderGeometryCache!;
    }

    final previousShapeSignatureSnapshotState =
        _useShapeGeometrySignatureSnapshot;
    _useShapeGeometrySignatureSnapshot = true;
    try {
      _prepareStrokeReflowCache();

      // In the ordinary case the flat fill and outline silhouettes are
      // identical. The combined resolver keeps them aliased until a lifted fill
      // or width-profile spline genuinely requires separate semantics.
      final needsSeparateOutline = shapes.any((shape) {
        if (!shape.isVisible || shape is CompassMesh) return false;
        return hasLiftedSelfPaintedFill(shape) ||
            (shape is CompassXSpline &&
                shape.operation == CompassBooleanOp.add &&
                shape.hasWidthProfile &&
                shape.isClosed);
      });

      // Area-stroke resolution only has a seed when an ADD variable-width
      // spline exists. Ordinary fills and outline-region stacks cannot produce
      // an area-stroke master.
      final hasAreaStrokeSeed = shapes.any((shape) =>
          shape.isVisible &&
          shape is CompassXSpline &&
          shape.operation == CompassBooleanOp.add &&
          shape.hasWidthProfile &&
          !hasLiftedGradientFill(shape));

      final masters = _resolveRenderMasterPaths(
        needsSeparateOutline: needsSeparateOutline,
        hasAreaStrokeSeed: hasAreaStrokeSeed,
      );
      final fillPath = masters.fillPath;
      final outlinePath = masters.outlinePath;
      final strokeAreaPath = masters.strokeAreaPath;

      final hasColoredStrokeBands = shapes.any((shape) =>
          shape.isVisible &&
          shape.strokeRegions.any((region) =>
              region.op == CompassBooleanOp.add && region.color != null));

      final strokeOverpaints = hasColoredStrokeBands
          ? getStrokeAddBandOverpaints(fillPath)
          : const <(Path, Color)>[];

      Rect bounds = Rect.zero;
      void include(Path path) {
        if (path.isEffectivelyEmpty) return;
        final next = path.getBounds();
        bounds = bounds == Rect.zero ? next : bounds.expandToInclude(next);
      }

      include(fillPath);
      include(outlinePath);
      include(strokeAreaPath);
      for (final (path, _) in strokeOverpaints) {
        include(path);
      }
      for (final shape in shapes) {
        if (shape is! CompassMesh || !shape.isVisible) continue;
        final meshBounds = shape.getBounds();
        if (meshBounds == Rect.zero) continue;
        bounds = bounds == Rect.zero
            ? meshBounds
            : bounds.expandToInclude(meshBounds);
      }

      final resolved = CompassLayerRenderGeometry(
        fillPath: fillPath,
        outlinePath: outlinePath,
        strokeAreaPath: strokeAreaPath,
        strokeOverpaints: strokeOverpaints,
        bounds: bounds,
      );

      _renderGeometrySignature = resolvedSignature;
      _renderGeometryCache = resolved;
      return resolved;
    } finally {
      _useShapeGeometrySignatureSnapshot =
          previousShapeSignatureSnapshotState;
    }
  }

  void _prepareClipCache(int signature) {
    if (_clipCacheSignature == signature) return;
    _clipCacheSignature = signature;
    _selfPaintedClipCache.clear();
    _imagePaintClipCache.clear();
    _meshClipCache.clear();
  }

  int get _strokeReflowTopologySignatureValue {
    var signature = Object.hash(shapes.length, 0);
    for (var index = 0; index < shapes.length; index++) {
      signature = Object.hash(
        signature,
        index,
        identityHashCode(shapes[index]),
      );
    }
    return signature;
  }

  /// Stroke reflow geometry only depends on the stroked owner and later
  /// SUBTRACT / INTERSECT operands. A moving ADD shape must not invalidate the
  /// expensive offset contour for an earlier stroked spline.
  int _strokeReflowShapeSignature(CompassShape target) {
    final targetIndex = shapes.indexOf(target);
    if (targetIndex < 0) return identityHashCode(target);

    var signature = Object.hash(
      targetIndex,
      _shapeGeometrySignatureForResolution(target),
      _shapeIsBeingDragged(target),
    );

    for (var index = targetIndex + 1; index < shapes.length; index++) {
      final laterShape = shapes[index];
      final hasCarvingOperation =
          laterShape.operation == CompassBooleanOp.subtract ||
              laterShape.operation == CompassBooleanOp.intersect ||
              laterShape.strokeRegions.any(
                (region) =>
                    region.op == CompassBooleanOp.subtract ||
                    region.op == CompassBooleanOp.intersect,
              );

      if (!hasCarvingOperation) continue;

      signature = Object.hash(
        signature,
        index,
        _shapeGeometrySignatureForResolution(laterShape),
        _shapeIsBeingDragged(laterShape),
      );
    }

    return signature;
  }

  Rect _strokeStackBounds(_ResolvedStrokeStack stack) {
    var bounds = Rect.zero;
    for (final band in stack.bands) {
      if (band.path.isEffectivelyEmpty) continue;
      final bandBounds = band.path.getBounds();
      bounds = bounds == Rect.zero
          ? bandBounds
          : bounds.expandToInclude(bandBounds);
    }
    return bounds;
  }

  Rect _shapeForegroundCandidateBounds(CompassShape shape) {
    if (!shape.isVisible || shape is CompassMesh) return Rect.zero;

    final basePath = shape.getPath();
    var bounds = basePath.isEffectivelyEmpty
        ? Rect.zero
        : basePath.getBounds();

    var accumulatedWidth = 0.0;
    var hasFlatAddBand = false;
    for (final region in shape.strokeRegions) {
      accumulatedWidth += region.width.abs();
      hasFlatAddBand = hasFlatAddBand ||
          (region.op == CompassBooleanOp.add && region.color == null);
    }

    if (hasFlatAddBand && bounds != Rect.zero && accumulatedWidth > 0.0) {
      bounds = bounds.inflate(accumulatedWidth);
    }

    return bounds;
  }

  bool _shapeContributesForegroundCoverage(CompassShape shape) {
    if (!shape.isVisible || shape is CompassMesh) return false;

    if (shape.operation == CompassBooleanOp.add) return true;

    // A null-color ADD band participates in the layer's flat master and can
    // therefore cover an earlier reflowed/colored ring. Custom-colored bands
    // are painted later in their own ordered pass and do not belong here.
    return shape.strokeRegions.any(
      (region) =>
          region.op == CompassBooleanOp.add && region.color == null,
    );
  }

  /// Colored stroke overpaints are rendered in a late pass and therefore need
  /// the current visible suffix above their owner. Hash only geometry that can
  /// actually occlude that ring. Later carvers invalidate this cache through
  /// [_strokeReflowShapeSignature], so they do not need to be folded into this
  /// second O(n) signature as well.
  int _strokeForegroundCoverageSignature(
    CompassShape target,
    Rect targetBounds,
  ) {
    final targetIndex = shapes.indexOf(target);
    if (targetIndex < 0) return identityHashCode(target);

    var signature = Object.hash(
      targetIndex,
      shapes.length,
      targetBounds.left,
      targetBounds.top,
      targetBounds.right,
      targetBounds.bottom,
    );
    for (var index = targetIndex + 1; index < shapes.length; index++) {
      final laterShape = shapes[index];
      if (!_shapeContributesForegroundCoverage(laterShape)) continue;

      // A later ADD object that is spatially unrelated to this stroke cannot
      // cover it. Excluding it from the signature means dragging that object
      // elsewhere in the layer no longer invalidates the expensive suffix
      // coverage cache.
      final candidateBounds = _shapeForegroundCandidateBounds(laterShape);
      if (candidateBounds == Rect.zero ||
          !candidateBounds.overlaps(targetBounds)) {
        continue;
      }

      signature = Object.hash(
        signature,
        index,
        _shapeGeometrySignatureForResolution(laterShape),
      );
    }
    return signature;
  }

  void _prepareStrokeReflowCache() {
    final topologySignature = _strokeReflowTopologySignatureValue;
    if (_strokeReflowTopologySignature == topologySignature) return;

    _strokeReflowTopologySignature = topologySignature;
    _strokeReflowCache.clear();
    _strokeReflowShapeSignatures.clear();
    _strokeForegroundCoverageCache.clear();
    _strokeForegroundCoverageSignatures.clear();
  }

  void _syncStrokeReflowCache() {
    _prepareStrokeReflowCache();
  }

  Path getCachedSelfPaintedClipPath(
    CompassShape target,
    int signature,
  ) {
    _prepareClipCache(signature);
    return _selfPaintedClipCache.putIfAbsent(
      target,
      () => _withShapeGeometrySignatureSnapshot(
        signature,
        () => getLayerSelfPaintedClipPath(target),
      ),
    );
  }

  Path getCachedImagePaintClipPath(
    CompassImage target,
    int signature,
  ) {
    _prepareClipCache(signature);
    return _imagePaintClipCache.putIfAbsent(
      target,
      () => _withShapeGeometrySignatureSnapshot(
        signature,
        () => getLayerImagePaintClipPath(target),
      ),
    );
  }

  Path getCachedMeshClipPath(
    CompassMesh target,
    int signature,
  ) {
    _prepareClipCache(signature);
    return _meshClipCache.putIfAbsent(
      target,
      () => _withShapeGeometrySignatureSnapshot(
        signature,
        () => getLayerMeshClipPath(target),
      ),
    );
  }

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
    if (master.isEffectivelyEmpty) return master;

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
    if (contribution.isEffectivelyEmpty) return master;

    if (master.isEffectivelyEmpty) {
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

  bool _shapeSupportsPostBooleanStrokeReflow(CompassShape shape) {
    if (!shape.isVisible || shape.operation != CompassBooleanOp.add) {
      return false;
    }

    if (shape.strokeRegions.isEmpty ||
        shape.strokeRegions.any(
          (region) => region.op == CompassBooleanOp.intersect,
        )) {
      return false;
    }

    if (shape is CompassCircle || shape is CompassRectangle) {
      return true;
    }

    if (shape is CompassXSpline) {
      return shape.isClosed || shape.hasWidthProfile;
    }

    return false;
  }

  bool _shapeIsBeingDragged(CompassShape shape) {
    if (shape is CompassCircle) {
      return shape.center.isBeingDragged ||
          (shape.radiusPoint?.isBeingDragged ?? false);
    }

    if (shape is CompassRectangle) {
      return shape.p1.isBeingDragged || shape.p2.isBeingDragged;
    }

    if (shape is CompassXSpline) {
      return shape.nodes.any((node) => node.point.isBeingDragged);
    }

    if (shape is CompassImage) {
      return shape.origin.isBeingDragged ||
          shape.xHandle.isBeingDragged ||
          shape.yHandle.isBeingDragged;
    }

    return false;
  }

  Path _applyCarverToStrokeSource(
    Path source,
    Path operand,
    CompassBooleanOp operation,
  ) {
    if (source.isEffectivelyEmpty || operand.isEffectivelyEmpty) {
      return operation == CompassBooleanOp.intersect ? Path() : source;
    }

    if (operation == CompassBooleanOp.subtract &&
        !source.getBounds().overlaps(operand.getBounds())) {
      return source;
    }

    if (operation != CompassBooleanOp.subtract &&
        operation != CompassBooleanOp.intersect) {
      return source;
    }

    final resolved = Path.combine(
      operation == CompassBooleanOp.subtract
          ? PathOperation.difference
          : PathOperation.intersect,
      source,
      operand,
    );
    resolved.fillType = PathFillType.evenOdd;
    return resolved;
  }

  _ResolvedStrokeStack _buildResolvedStrokeStack(CompassShape shape) {
    final sourceBands = _strokeBands(shape);
    if (sourceBands.isEmpty) {
      return _ResolvedStrokeStack(
        reflowed: false,
        bands: [],
      );
    }

    List<_ResolvedStrokeBand> exactBands() => sourceBands
        .map(
          (band) => _ResolvedStrokeBand(
            region: band.region,
            path: shape.getStrokeOutlinePath(
              band.width,
              band.innerOffset,
            ),
          ),
        )
        .toList(growable: false);

    if (!_shapeSupportsPostBooleanStrokeReflow(shape)) {
      return _ResolvedStrokeStack(
        reflowed: false,
        bands: exactBands(),
      );
    }

    final targetIndex = shapes.indexOf(shape);
    if (targetIndex < 0 || targetIndex == shapes.length - 1) {
      return _ResolvedStrokeStack(
        reflowed: false,
        bands: exactBands(),
      );
    }

    var visibleSource = Path.from(shape.getPath())
      ..fillType = PathFillType.evenOdd;
    var wasCarved = false;
    var interactive = _shapeIsBeingDragged(shape);

    for (var index = targetIndex + 1; index < shapes.length; index++) {
      final laterShape = shapes[index];
      if (!laterShape.isVisible || laterShape is CompassMesh) continue;

      interactive = interactive || _shapeIsBeingDragged(laterShape);

      for (final bandData in _strokeBands(laterShape)) {
        final operation = bandData.region.op;
        if (operation != CompassBooleanOp.subtract &&
            operation != CompassBooleanOp.intersect) {
          continue;
        }

        final operand = laterShape.getStrokeOutlinePath(
          bandData.width,
          bandData.innerOffset,
        );
        final mayAffect = operation == CompassBooleanOp.intersect ||
            visibleSource.getBounds().overlaps(operand.getBounds());
        visibleSource = _applyCarverToStrokeSource(
          visibleSource,
          operand,
          operation,
        );
        wasCarved = wasCarved || mayAffect;
      }

      if (laterShape.operation != CompassBooleanOp.subtract &&
          laterShape.operation != CompassBooleanOp.intersect) {
        continue;
      }

      final operand = laterShape.getPath();
      final mayAffect = laterShape.operation == CompassBooleanOp.intersect ||
          visibleSource.getBounds().overlaps(operand.getBounds());
      visibleSource = _applyCarverToStrokeSource(
        visibleSource,
        operand,
        laterShape.operation,
      );
      wasCarved = wasCarved || mayAffect;

      if (visibleSource.isEffectivelyEmpty) break;
    }

    if (!wasCarved) {
      return _ResolvedStrokeStack(
        reflowed: false,
        bands: exactBands(),
      );
    }

    if (visibleSource.isEffectivelyEmpty) {
      return _ResolvedStrokeStack(
        reflowed: true,
        bands: sourceBands
            .map(
              (band) => _ResolvedStrokeBand(
                region: band.region,
                path: Path()..fillType = PathFillType.evenOdd,
              ),
            )
            .toList(growable: false),
      );
    }

    final geometry = StrokeOutlineBuilder.prepare(
      visibleSource,
      sourceIsArea: true,
      interactive: interactive,
      // Exact source-union cleanup is valuable for the finalized contour but
      // is one of the heaviest combines in the drag loop. The lightweight
      // interactive contour is replaced automatically when dragging ends.
      cleanAreaDilation: !interactive,
    );

    return _ResolvedStrokeStack(
      reflowed: true,
      bands: sourceBands
          .map(
            (band) => _ResolvedStrokeBand(
              region: band.region,
              path: StrokeOutlineBuilder.buildBandFromGeometry(
                geometry,
                band.width,
                band.innerOffset,
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  /// Resolves the geometry introduced after [targetIndex] that must remain
  /// visually above an earlier shape's post-Boolean stroke.
  ///
  /// Stroke reflow is calculated after later cutters so it can wrap the newly
  /// created boundary. Replaying that result blindly at the end of the layer,
  /// however, would also cut or recolor later ADD objects. This suffix walk
  /// captures the final visible contribution of those later objects so reflow
  /// can be restricted to the geometry genuinely owned by the earlier shape.
  Path _buildLaterVisibleAddCoverage(
    int targetIndex,
    Rect targetBounds,
  ) {
    var foreground = Path()..fillType = PathFillType.evenOdd;

    for (var index = targetIndex + 1; index < shapes.length; index++) {
      final shape = shapes[index];
      if (!shape.isVisible || shape is CompassMesh) continue;

      final basePath = shape.getPath();
      final baseBounds = basePath.isEffectivelyEmpty
          ? Rect.zero
          : basePath.getBounds();
      for (final bandData in _strokeBands(shape)) {
        final operation = bandData.region.op;
        final isFlatAdd = operation == CompassBooleanOp.add &&
            bandData.region.color == null;
        final isCarver = operation == CompassBooleanOp.subtract ||
            operation == CompassBooleanOp.intersect;
        if (!isFlatAdd && !isCarver) continue;

        final bandBounds = baseBounds == Rect.zero
            ? Rect.zero
            : baseBounds.inflate(
                bandData.innerOffset + bandData.width.abs(),
              );

        if (isFlatAdd &&
            (bandBounds == Rect.zero ||
                !bandBounds.overlaps(targetBounds))) {
          continue;
        }
        if (operation == CompassBooleanOp.subtract &&
            (foreground.isEffectivelyEmpty ||
                bandBounds == Rect.zero ||
                !bandBounds.overlaps(foreground.getBounds()))) {
          continue;
        }
        if (operation == CompassBooleanOp.intersect) {
          if (foreground.isEffectivelyEmpty) continue;
          if (bandBounds == Rect.zero ||
              !bandBounds.overlaps(targetBounds)) {
            foreground = Path()..fillType = PathFillType.evenOdd;
            continue;
          }
        }

        final band = shape.getStrokeOutlinePath(
          bandData.width,
          bandData.innerOffset,
        );
        foreground = _combine(foreground, band, operation);
      }

      if (shape.operation == CompassBooleanOp.none) continue;

      if (shape.operation == CompassBooleanOp.add &&
          (baseBounds == Rect.zero || !baseBounds.overlaps(targetBounds))) {
        continue;
      }
      if (shape.operation == CompassBooleanOp.subtract &&
          (foreground.isEffectivelyEmpty ||
              baseBounds == Rect.zero ||
              !baseBounds.overlaps(foreground.getBounds()))) {
        continue;
      }
      if (shape.operation == CompassBooleanOp.intersect) {
        if (foreground.isEffectivelyEmpty) continue;
        if (baseBounds == Rect.zero || !baseBounds.overlaps(targetBounds)) {
          foreground = Path()..fillType = PathFillType.evenOdd;
          continue;
        }
      }

      Path? contribution;

      if (shape is CompassImage &&
          shape.operation == CompassBooleanOp.add) {
        contribution = getLayerImagePaintClipPath(shape);
      } else if (hasLiftedGradientFill(shape)) {
        contribution = getLayerSelfPaintedClipPath(shape);
      } else {
        contribution = basePath;
      }

      if (contribution == null || contribution.isEffectivelyEmpty) continue;
      foreground = _combine(
        foreground,
        contribution,
        shape.operation,
      )..fillType = PathFillType.evenOdd;
    }

    return foreground;
  }

  Path _laterVisibleAddCoverage(
    CompassShape shape,
    Rect targetBounds,
  ) {
    if (targetBounds == Rect.zero) return Path();

    _prepareStrokeReflowCache();
    final signature = _strokeForegroundCoverageSignature(
      shape,
      targetBounds,
    );
    if (_strokeForegroundCoverageSignatures[shape] == signature) {
      return _strokeForegroundCoverageCache[shape] ?? Path();
    }

    final index = shapes.indexOf(shape);
    final coverage = index < 0
        ? Path()
        : _buildLaterVisibleAddCoverage(index, targetBounds);
    _strokeForegroundCoverageSignatures[shape] = signature;
    _strokeForegroundCoverageCache[shape] = coverage;
    return coverage;
  }

  _ResolvedStrokeStack _resolvedStrokeStack(CompassShape shape) {
    _prepareStrokeReflowCache();
    final signature = _strokeReflowShapeSignature(shape);
    if (_strokeReflowShapeSignatures[shape] == signature) {
      final cached = _strokeReflowCache[shape];
      if (cached != null) return cached;
    }

    final previousSignature = _strokeReflowShapeSignatures[shape];
    final resolved = _buildResolvedStrokeStack(shape);
    _strokeReflowShapeSignatures[shape] = signature;
    _strokeReflowCache[shape] = resolved;

    // A changed carver can alter which parts of later ADD geometry remain
    // visible even though the narrowed foreground signature intentionally does
    // not hash carvers. Drop the companion cache whenever the reflow signature
    // changes so the next use rebuilds the exact visible suffix.
    if (previousSignature != null && previousSignature != signature) {
      _strokeForegroundCoverageCache.remove(shape);
      _strokeForegroundCoverageSignatures.remove(shape);
    }

    return resolved;
  }

  /// Replays post-Boolean stroke stacks after later cutters have created the
  /// contour they must wrap. Later ADD geometry is restored once per stack,
  /// rather than subtracting that foreground from every individual band. This
  /// preserves Z-order while avoiding the expensive `band - foreground`
  /// Boolean that previously scaled with the number of rings.
  Path _applyPostBooleanStrokeReflow(Path master) {
    for (final shape in shapes) {
      if (!shape.isVisible || shape.strokeRegions.isEmpty) continue;

      final stack = _resolvedStrokeStack(shape);
      if (!stack.reflowed) continue;

      var appliedCarvingBand = false;

      for (final band in stack.bands) {
        final operation = band.region.op;
        if (operation != CompassBooleanOp.add &&
            operation != CompassBooleanOp.subtract) {
          continue;
        }

        if (band.path.isEffectivelyEmpty) continue;
        master = _combine(master, band.path, operation);
        appliedCarvingBand =
            appliedCarvingBand || operation == CompassBooleanOp.subtract;
      }

      // ADD rings cannot erase later geometry. Only a Cut ring requires the
      // suffix above its owner to be restored, and it is restored once after
      // the entire stack rather than protected band-by-band.
      if (appliedCarvingBand) {
        final foreground = _laterVisibleAddCoverage(
          shape,
          _strokeStackBounds(stack),
        );
        if (foreground.isEffectivelyNotEmpty) {
          master = _combine(master, foreground, CompassBooleanOp.add);
        }
      }
    }

    return master;
  }

  /// Applies the ordinary stroke stack during the primary Boolean walk unless
  /// that shape has a post-Boolean reflow result. Reflowed stacks are replayed
  /// once, after their later cutters are known, so the original low-level band
  /// is not duplicated underneath the corrected contour.
  Path _applyPrimaryStrokeStack(
    Path master,
    CompassShape shape,
  ) {
    final resolved = _resolvedStrokeStack(shape);
    if (resolved.reflowed) return master;
    return _applyStrokeStack(
      master,
      shape,
      addsAllowed: true,
    );
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
      } else if (master.isEffectivelyNotEmpty &&
          band.isEffectivelyNotEmpty) {
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

  /// Whether [shape] paints raster pixels instead of the layer's flat color.
  ///
  /// The image remains a normal Boolean operand for subtract/intersect. Only an
  /// ADD image is lifted into the dedicated self-painted pass.
  static bool hasLiftedImageFill(CompassShape shape) {
    return shape is CompassImage &&
        shape.operation == CompassBooleanOp.add;
  }

  /// Self-painted ADD fills are omitted from the flat layer-color union and draw
  /// their own content through a Boolean-resolved clip path.
  static bool hasLiftedSelfPaintedFill(CompassShape shape) {
    return hasLiftedGradientFill(shape) || hasLiftedImageFill(shape);
  }

  /// The master Boolean path intended to receive the uniform outline stroke.
  ///
  /// Gradient meshes are excluded because they are self-painted. Linear-gradient
  /// shapes remain included so the layer hairline still follows their boundary.
  Path getLayerPath() {
    _syncStrokeReflowCache();
    var master = Path();
    final liftedImages = <CompassImage>[];

    for (final shape in shapes) {
      if (!shape.isVisible) continue;

      if (shape is CompassMesh) {
        continue;
      }

      master = _applyPrimaryStrokeStack(master, shape);

      if (shape.operation == CompassBooleanOp.none) {
        continue;
      }

      // ADD images paint separately and their outline must follow the resolved
      // mask rather than the original rectangular frame. Defer those masks so
      // disconnected INTERSECT operands can union before clipping the image.
      if (shape is CompassImage &&
          shape.operation == CompassBooleanOp.add) {
        liftedImages.add(shape);
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

    for (final image in liftedImages) {
      final imageMask = getLayerImageMaskPath(image);
      if (imageMask.isEffectivelyEmpty) {
        continue;
      }

      master = master.isEffectivelyEmpty
          ? imageMask
          : Path.combine(PathOperation.union, master, imageMask);
    }

    master = _applyPostBooleanStrokeReflow(master);
    return applyMirror(master);
  }

  /// The master Boolean path intended to receive the flat layer fill.
  ///
  /// Linear-gradient ADD fills and gradient meshes are excluded because they
  /// paint themselves in dedicated renderer passes. Stroke regions belonging to
  /// gradient shapes still participate here.
  Path getLayerFillPath() {
    _syncStrokeReflowCache();
    var master = Path();

    for (final shape in shapes) {
      if (!shape.isVisible) continue;

      if (shape is CompassMesh) {
        continue;
      }

      master = _applyPrimaryStrokeStack(master, shape);

      if (shape.operation == CompassBooleanOp.none ||
          hasLiftedSelfPaintedFill(shape)) {
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

    master = _applyPostBooleanStrokeReflow(master);
    return applyMirror(master);
  }

  /// Returns custom-colored ADD stroke bands in their painting order.
  ///
  /// The paths are clipped against the resolved flat-fill master so colored
  /// bands cannot repaint portions removed by later Boolean operations.
  List<(Path, Color)> getStrokeAddBandOverpaints(
    Path fillMaster,
  ) {
    _syncStrokeReflowCache();
    if (fillMaster.isEffectivelyEmpty) {
      return const [];
    }

    final output = <(Path, Color)>[];

    for (final shape in shapes) {
      if (!shape.isVisible) continue;
      if (shape is CompassMesh) continue;

      final resolvedStack = _resolvedStrokeStack(shape);
      final stackBounds = _strokeStackBounds(resolvedStack);
      Path? foregroundCoverage;
      for (final resolvedBand in resolvedStack.bands) {
        if (resolvedBand.region.op != CompassBooleanOp.add) {
          continue;
        }

        final color = resolvedBand.region.color;
        if (color == null) continue;

        var band = resolvedBand.path;

        if (band.isEffectivelyEmpty) {
          continue;
        }

        // Colored stroke bands are painted in a late pass. Remove geometry
        // introduced after their owner so the late paint pass does not recolor
        // unrelated ADD shapes that should sit above the ring.
        foregroundCoverage ??= _laterVisibleAddCoverage(
          shape,
          stackBounds,
        );
        final foreground = foregroundCoverage!;
        if (foreground.isEffectivelyNotEmpty &&
            band.getBounds().overlaps(foreground.getBounds())) {
          band = Path.combine(
            PathOperation.difference,
            band,
            foreground,
          )..fillType = PathFillType.evenOdd;
        }

        if (band.isEffectivelyEmpty) continue;

        final clipped = Path.combine(
          PathOperation.intersect,
          fillMaster,
          band,
        );

        if (clipped.isEffectivelyEmpty) {
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
      if (shapePath.isEffectivelyEmpty) {
        continue;
      }

      if (shape.operation == CompassBooleanOp.add) {
        if (shape is CompassXSpline &&
            shape.hasWidthProfile &&
            !hasLiftedGradientFill(shape)) {
          if (master.isEffectivelyEmpty) {
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

      if (master.isEffectivelyEmpty) {
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

    if (clip.isEffectivelyEmpty) {
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

        if (cutter.isEffectivelyEmpty) {
          continue;
        }

        clip = Path.combine(
          PathOperation.difference,
          clip,
          cutter,
        );
      } else if (shape.operation == CompassBooleanOp.intersect) {
        final cutter = shape.getPath();

        if (cutter.isEffectivelyEmpty) {
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
  Path getLayerSelfPaintedClipPath(CompassShape target) {
    final targetIndex = shapes.indexOf(target);

    if (targetIndex == -1 || !target.isVisible) {
      return Path();
    }

    var clip = target.getPath();

    if (clip.isEffectivelyEmpty) {
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

        if (band.isEffectivelyEmpty) {
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

        if (clip.isEffectivelyEmpty) {
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
          if (hasLiftedSelfPaintedFill(shape)) {
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
              occluder.isEffectivelyNotEmpty) {
            clip = Path.combine(
              PathOperation.difference,
              clip,
              occluder,
            );
          }
          break;

        case CompassBooleanOp.subtract:
          final cutter = shape.getPath();

          if (cutter.isEffectivelyNotEmpty) {
            clip = Path.combine(
              PathOperation.difference,
              clip,
              cutter,
            );
          }
          break;

        case CompassBooleanOp.intersect:
          final cutter = shape.getPath();

          if (cutter.isEffectivelyNotEmpty) {
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

      if (clip.isEffectivelyEmpty) {
        return clip;
      }
    }

    return clip;
  }

  /// The live Boolean mask for one IMG object.
  ///
  /// IMG masking uses a mask-set interpretation rather than replaying every
  /// INTERSECT sequentially:
  ///
  /// - all later INTERSECT shapes and stroke bands are unioned into one keep
  ///   region, allowing disconnected pieces such as a logo body and leaf;
  /// - all later SUBTRACT shapes and stroke bands are unioned into one cut
  ///   region and punch transparent holes through the kept image;
  /// - later ADD shapes do not change the mask -- they remain ordinary objects
  ///   layered above the image.
  ///
  /// In set terms, the result is:
  ///
  ///   (IMG ∩ union(all INTERSECT operands)) - union(all SUBTRACT operands)
  ///
  /// If no INTERSECT operand exists, the complete IMG frame is retained before
  /// subtraction. The returned path is not mirrored; callers transform the
  /// mask and pixels together.
  Path getLayerImageMaskPath(CompassImage target) {
    final targetIndex = shapes.indexOf(target);

    if (targetIndex == -1 || !target.isVisible) {
      return Path();
    }

    final imageFrame = target.getPath();
    imageFrame.fillType = PathFillType.evenOdd;

    if (imageFrame.isEffectivelyEmpty) {
      return imageFrame;
    }

    var intersectionRegion = Path();
    var subtractionRegion = Path();
    var hasIntersection = false;

    Path union(Path accumulated, Path operand) {
      if (operand.isEffectivelyEmpty) {
        return accumulated;
      }

      if (accumulated.isEffectivelyEmpty) {
        return operand;
      }

      final result = Path.combine(
        PathOperation.union,
        accumulated,
        operand,
      );
      result.fillType = PathFillType.evenOdd;
      return result;
    }

    void collect(Path operand, CompassBooleanOp operation) {
      if (operand.isEffectivelyEmpty) {
        return;
      }

      if (operation == CompassBooleanOp.intersect) {
        intersectionRegion = union(intersectionRegion, operand);
        hasIntersection = true;
      } else if (operation == CompassBooleanOp.subtract) {
        subtractionRegion = union(subtractionRegion, operand);
      }
    }

    for (var index = targetIndex + 1; index < shapes.length; index++) {
      final shape = shapes[index];

      if (!shape.isVisible || shape is CompassMesh) {
        continue;
      }

      for (final bandData in _strokeBands(shape)) {
        final operation = bandData.region.op;
        if (operation != CompassBooleanOp.subtract &&
            operation != CompassBooleanOp.intersect) {
          continue;
        }

        collect(
          shape.getStrokeOutlinePath(
            bandData.width,
            bandData.innerOffset,
          ),
          operation,
        );
      }

      if (shape.operation == CompassBooleanOp.subtract ||
          shape.operation == CompassBooleanOp.intersect) {
        collect(shape.getPath(), shape.operation);
      }
    }

    var mask = imageFrame;

    if (hasIntersection &&
        intersectionRegion.isEffectivelyNotEmpty) {
      mask = Path.combine(
        PathOperation.intersect,
        mask,
        intersectionRegion,
      );
      mask.fillType = PathFillType.evenOdd;
    }

    if (mask.isEffectivelyNotEmpty &&
        subtractionRegion.isEffectivelyNotEmpty) {
      mask = Path.combine(
        PathOperation.difference,
        mask,
        subtractionRegion,
      );
      mask.fillType = PathFillType.evenOdd;
    }

    return mask;
  }

  Path _applyImageForegroundOcclusion(
    CompassImage target,
    Path source,
  ) {
    final targetIndex = shapes.indexOf(target);
    var clip = source;

    if (targetIndex == -1 || clip.isEffectivelyEmpty) {
      return clip;
    }

    Path occlude(Path current, Path occluder) {
      final result = Path.combine(
        PathOperation.difference,
        current,
        occluder,
      );
      result.fillType = PathFillType.evenOdd;
      return result;
    }

    for (var index = targetIndex + 1; index < shapes.length; index++) {
      final shape = shapes[index];

      if (!shape.isVisible || shape is CompassMesh) continue;

      for (final bandData in _strokeBands(shape)) {
        final region = bandData.region;

        // A null-color ADD ring belongs to the early flat layer-color pass.
        // Custom-colored rings paint later and naturally composite above IMG.
        if (region.op != CompassBooleanOp.add || region.color != null) {
          continue;
        }

        final band = shape.getStrokeOutlinePath(
          bandData.width,
          bandData.innerOffset,
        );
        if (band.isEffectivelyNotEmpty) {
          clip = occlude(clip, band);
        }
      }

      if (shape.operation != CompassBooleanOp.add ||
          hasLiftedSelfPaintedFill(shape)) {
        continue;
      }

      Path? occluder;
      if (shape is CompassXSpline && shape.hasWidthProfile) {
        if (shape.isClosed) {
          occluder = shape.getCenterPath()
            ..fillType = PathFillType.evenOdd;
        }
      } else {
        occluder = shape.getPath();
      }

      if (occluder != null && occluder.isEffectivelyNotEmpty) {
        clip = occlude(clip, occluder);
      }

      if (clip.isEffectivelyEmpty) return clip;
    }

    return clip;
  }

  /// A defensive, export-specific resolution of one IMG's visible surface.
  ///
  /// The live renderer normally uses [getLayerImagePaintClipPath]. OBJ export is
  /// less forgiving: if a combined Path ever arrives with the raw IMG frame, the
  /// triangulator will faithfully build a rectangle. This method reconstructs the
  /// mask from first principles so every INTERSECT operand (a circle, logo body,
  /// detached leaf, and so on) is explicitly applied before tessellation.
  ///
  /// Normal Boolean order is preserved: operators after the IMG are authoritative.
  /// As a safety net for a manually reordered dedicated IMG layer, when no mask
  /// operator exists above the IMG we also accept operators immediately below it,
  /// stopping at the next IMG object so separate raster surfaces cannot leak into
  /// one another. ADD objects remain foreground occluders rather than texture mask
  /// contributors.
  Path getLayerImageExportMaskPath(CompassImage target) {
    final targetIndex = shapes.indexOf(target);
    if (targetIndex == -1 || !target.isVisible) return Path();

    var intersectionRegion = Path();
    var subtractionRegion = Path();
    var hasIntersection = false;
    var hasSubtraction = false;
    var foundLaterMaskOperator = false;

    Path union(Path accumulated, Path operand) {
      if (operand.isEffectivelyEmpty) return accumulated;
      if (accumulated.isEffectivelyEmpty) {
        final copy = Path.from(operand)..fillType = PathFillType.evenOdd;
        return copy;
      }
      final result = Path.combine(
        PathOperation.union,
        accumulated,
        operand,
      );
      result.fillType = PathFillType.evenOdd;
      return result;
    }

    void collectOperand(Path operand, CompassBooleanOp operation) {
      if (operand.isEffectivelyEmpty) return;
      if (operation == CompassBooleanOp.intersect) {
        intersectionRegion = union(intersectionRegion, operand);
        hasIntersection = true;
      } else if (operation == CompassBooleanOp.subtract) {
        subtractionRegion = union(subtractionRegion, operand);
        hasSubtraction = true;
      }
    }

    void collectShape(CompassShape shape) {
      if (!shape.isVisible || shape is CompassMesh || shape is CompassImage) {
        return;
      }

      for (final bandData in _strokeBands(shape)) {
        final operation = bandData.region.op;
        if (operation != CompassBooleanOp.intersect &&
            operation != CompassBooleanOp.subtract) {
          continue;
        }
        collectOperand(
          shape.getStrokeOutlinePath(
            bandData.width,
            bandData.innerOffset,
          ),
          operation,
        );
      }

      if (shape.operation == CompassBooleanOp.intersect ||
          shape.operation == CompassBooleanOp.subtract) {
        collectOperand(shape.getPath(), shape.operation);
      }
    }

    // Primary mask scope: shapes above the IMG in Boolean / visual order.
    for (var index = targetIndex + 1; index < shapes.length; index++) {
      final shape = shapes[index];
      if (shape is CompassImage) break;

      final beforeIntersection = hasIntersection;
      final beforeSubtraction = hasSubtraction;
      collectShape(shape);
      if (hasIntersection != beforeIntersection ||
          hasSubtraction != beforeSubtraction) {
        foundLaterMaskOperator = true;
      }
    }

    // Dedicated IMG layers are often manually restacked. If there is no mask
    // operator above the IMG, accept the adjacent mask group below it as a
    // defensive export fallback. The canvas ordering remains otherwise intact.
    if (!foundLaterMaskOperator) {
      for (var index = targetIndex - 1; index >= 0; index--) {
        final shape = shapes[index];
        if (shape is CompassImage) break;
        collectShape(shape);
      }
    }

    var clip = Path.from(target.getPath())
      ..fillType = PathFillType.evenOdd;

    if (hasIntersection &&
        intersectionRegion.isEffectivelyNotEmpty) {
      clip = Path.combine(
        PathOperation.intersect,
        clip,
        intersectionRegion,
      )..fillType = PathFillType.evenOdd;
    }

    if (hasSubtraction &&
        clip.isEffectivelyNotEmpty &&
        subtractionRegion.isEffectivelyNotEmpty) {
      clip = Path.combine(
        PathOperation.difference,
        clip,
        subtractionRegion,
      )..fillType = PathFillType.evenOdd;
    }

    return _applyImageForegroundOcclusion(target, clip);
  }

  /// The final canvas clip for an IMG object.
  ///
  /// Boolean masking is resolved first by [getLayerImageMaskPath]. Later ADD
  /// objects are then removed only from this paint clip because the current
  /// renderer paints flat fills before self-painted IMG pixels. Removing those
  /// occupied regions makes the ADD objects remain visually above the IMG; it
  /// does not make them part of the image's mathematical mask.
  Path getLayerImagePaintClipPath(CompassImage target) {
    return _applyImageForegroundOcclusion(
      target,
      getLayerImageMaskPath(target),
    );
  }

  /// Backward-compatible gradient-specific name used by existing callers.
  Path getLayerGradientClipPath(CompassShape target) {
    return getLayerSelfPaintedClipPath(target);
  }

  /// Fully resolved vector silhouette for geometry-only exports and baking.
  ///
  /// Unlike [getLayerFillPath], this includes ADD shapes whose appearance is
  /// self-painted (gradients and IMG pixels). Raster pixels themselves are not
  /// represented here; an IMG contributes only its resolved mathematical mask.
  Path getLayerMeshExportPath({bool useExportImageMasks = false}) {
    _syncStrokeReflowCache();
    var master = Path();
    final liftedImages = <CompassImage>[];

    for (final shape in shapes) {
      if (!shape.isVisible) continue;
      if (shape is CompassMesh) continue;

      master = _applyPrimaryStrokeStack(master, shape);

      if (shape.operation == CompassBooleanOp.none) {
        continue;
      }

      // An ADD image is represented in geometry-only exports by its resolved
      // vector mask, not by its unmasked rectangular frame. Resolve those masks
      // after the ordinary vector walk so disconnected INTERSECT operands can
      // union into one image silhouette. SUBTRACT/INTERSECT image objects still
      // act as ordinary rectangular Boolean operands.
      if (shape is CompassImage &&
          shape.operation == CompassBooleanOp.add) {
        liftedImages.add(shape);
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
        master = _combine(master, fillPath, shape.operation);
      }
    }

    for (final image in liftedImages) {
      final imageMask = useExportImageMasks
          ? getLayerImageExportMaskPath(image)
          : getLayerImageMaskPath(image);
      if (imageMask.isEffectivelyEmpty) {
        continue;
      }

      master = master.isEffectivelyEmpty
          ? imageMask
          : Path.combine(PathOperation.union, master, imageMask);
    }

    master = _applyPostBooleanStrokeReflow(master);
    return applyMirror(master);
  }

}