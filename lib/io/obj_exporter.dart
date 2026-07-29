// /lib/io/obj_exporter.dart

import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart'; // debugPrint (diagnostics; harmless to keep)

import '../models/layer.dart';
import '../models/geometry/image.dart';
import 'medial_axis.dart';
import 'delaunay.dart';

/// A portable textured OBJ export package.
///
/// [objData] references [materialLibraryFileName], while [mtlData] references
/// [textureFileName]. The caller writes both text files beside a copy of
/// [textureSourcePath].
class OBJTextureExport {
  final String objData;
  final String mtlData;
  final String materialLibraryFileName;
  final String textureFileName;
  final String textureSourcePath;
  final String? error;

  const OBJTextureExport({
    required this.objData,
    required this.mtlData,
    required this.materialLibraryFileName,
    required this.textureFileName,
    required this.textureSourcePath,
    this.error,
  });

  bool get isEmpty => objData.isEmpty;

  factory OBJTextureExport.empty(String message) {
    return OBJTextureExport(
      objData: '',
      mtlData: '',
      materialLibraryFileName: '',
      textureFileName: '',
      textureSourcePath: '',
      error: message,
    );
  }
}

/// Exports a SINGLE layer's resolved boolean fill to a Wavefront .obj mesh,
/// flat on the Z=0 plane. This is the "layer -> object" export: it takes what
/// the layer *collapses into* after all its add/subtract/intersect operations
/// (exactly the silhouette the renderer fills) and triangulates the filled
/// region -- holes and all -- into a triangle mesh.
///
/// WHY a mesh instead of just leaning on Blender's SVG import:
///   * Compass resolves booleans with Path.combine BEFORE export, so a subtract
///     becomes real absence-of-geometry. The SVG exporter expresses subtraction
///     as an SVG <mask>, which Blender's importer ignores -- so holes silently
///     fill on SVG import. OBJ carries them.
///   * A triangle mesh is universal (Godot, any engine); SVG->curve is Blender-only.
///
/// FOUR EXPORT MODES (chosen by the caller):
///
///   SCANLINE (default; all mode flags false) -- a trapezoidal decomposition of
///     the filled region under the EVEN-ODD rule. Robust and follows the curve
///     smoothly, but produces many thin horizontal bands: correct, ugly
///     topology. This was the design that finally cut holes cleanly after a
///     hand-rolled ear-clipper (with zero-width hole bridges) kept choking into
///     sliver fans.
///
///   GRID (gridMode=true) -- a uniform quad lattice over the fill's bounding box.
///     Interior cells (all four corners inside) emit as clean quads; boundary cells
///     (the silhouette passes through) are clipped to their inside portion and
///     fanned so the edge still hugs the curve; cells fully outside or inside a hole
///     are simply not emitted. This is the workable topology for a game/iso
///     pipeline -- uniform quads subdivide and displace predictably. The tradeoff is
///     a stair-stepped silhouette at the cell resolution (raise gridCount to smooth
///     it).
///
///   DELAUNAY (delaunayMode=true) -- ORGANIC TRIANGLES: the same math as the
///     in-app "Bake to Triangulated Spline" (Sci-Fi veins), emitted as real `f`
///     faces instead of a DFS spline walk. Boundary samples (at the export's
///     Curve Resolution, so the silhouette is exact -- every boundary sample is
///     a mesh vertex, no stair-stepping) plus a seeded, spacing-enforced
///     interior scatter, run through Bowyer-Watson; triangles whose centroid
///     falls outside the even-odd region (concave bays, holes) are culled. The
///     result is roughly-equilateral, roughly-uniform tris -- the natural
///     topology for organic deformation, wireframe render styles, and anything
///     downstream that dislikes the scanline's slivers and the grid's blocky
///     rim. delaunaySpacing sets the interior point spacing (~ triangle edge
///     length); the kernel lives in delaunay.dart.
///
///   SKELETON (skeletonMode=true; wins over the other mode flags if several are
///     set) -- exports the region's MEDIAL AXIS instead of its area: the
///     internal topological frame, as loose OBJ `l` (line) elements rather than
///     `f` faces. Blender imports these as edge-only mesh geometry -- exactly
///     the input the Skin modifier and edge->armature scripts want, which is
///     the auto-rigging / retopology use case this mode exists for. The
///     extraction itself (discrete Voronoi sweep + lambda pruning) lives in
///     medial_axis.dart; this file only hands it the flattened contours and
///     serializes the result. gridCount here sets the SKELETON's sweep
///     resolution (same "cells across the longest side" meaning), and
///     skeletonLambda is the branch-pruning strength in logical px -- see
///     MedialAxisExtractor.extract for the full semantics, including the floor
///     lambda must keep above the sampling spacing.
///
///     In Skeleton mode, the outline and the internal medial axis are now emitted
///     as a single unified object. Bridge edges connect every boundary point to
///     the nearest skeleton point, guaranteeing a watertight contiguous mesh.
///
/// MODE PRECEDENCE when several flags are set: skeleton > delaunay > grid.
/// (Callers set exactly one; the ordering just makes the API total.)
///
/// All modes share flatten + even-odd inside test + recenter + Y-flip; the
/// scanline/grid modes additionally share the weld map (Delaunay's kernel does
/// its own lattice weld, exactly as the medial kernel does). Only the walking
/// differs.
///
/// Source path: layer.getLayerMeshExportPath(useExportImageMasks: true) -- the fill silhouette, which already
/// drops construction/stroke geometry and folds a closed width-spline's centerline
/// into the fill, so "what gets exported" matches "what you see filled on canvas."
/// The skeleton is extracted from this SAME silhouette, so holes shape the
/// skeleton exactly as they shape the fill (a ring yields a circular spine).
///
/// The mesh is RECENTERED on its bounding-box center so it lands at the world
/// origin (0,0,0) regardless of where the layer sat on Compass's infinite canvas,
/// and Y is flipped (Compass is Y-down; OBJ/Blender are Y-up). Every mode uses
/// the same bbox center, so a skeleton export lands in perfect registration
/// with a fill export (any fill mode) of the same layer in Blender.
///
/// Pure: depends only on dart:ui geometry + math (+ the equally pure
/// medial_axis.dart and delaunay.dart kernels).
class OBJExporter {
  // Weld tolerance (logical px) for collapsing coincident emitted vertices into a
  // single OBJ index. Design geometry spans hundreds-to-thousands of units, so
  // 1e-3 never merges genuinely distinct points.
  static const double _weld = 1e-3;

  // Minimum band height and minimum span width (logical px) for a trapezoid to be
  // emitted. Bands/spans thinner than this are sub-sample slivers that contribute
  // no visible area and only risk degenerate triangles, so they're skipped.
  static const double _minBand = 1e-4;
  static const double _minSpan = 1e-4;

  /// Serializes [layer]'s fill (or its skeleton + outline) to OBJ text. Returns
  /// an EMPTY string when the layer has no fillable area -- or, in skeleton
  /// mode, when pruning leaves no skeleton at all (e.g. lambda larger than every
  /// feature) -- so the caller can report "nothing to export" rather than
  /// writing a junk file.
  ///
  /// [samplingSpacing] -- arc-length gap (logical px) between samples along each
  ///   contour when flattening curves to polygons. Smaller = truer outline. In
  ///   skeleton mode this also sets the boundary-sample density the medial test
  ///   runs against (and the density of the emitted outline loops); in Delaunay
  ///   mode it sets the boundary vertex density of the triangulation itself --
  ///   so finer sampling = a truer silhouette in every mode.
  /// [minSamplesPerContour] / [maxSamplesPerContour] -- floor/cap on samples.
  /// [gridMode] -- true: uniform quad grid (default false: scanline trapezoids).
  /// [gridCount] -- grid AND skeleton modes: number of cells across the LONGEST
  ///   bbox side. Higher = finer grid / finer skeleton. The shorter side gets
  ///   however many same-size cells fit, so cells stay square.
  /// [delaunayMode] -- true: organic Delaunay triangles (see class comment).
  /// [delaunaySpacing] -- Delaunay mode only: minimum interior point spacing in
  ///   logical px, i.e. the approximate edge length of interior triangles.
  ///   Smaller = denser, finer mesh.
  /// [skeletonMode] -- true: export the medial-axis skeleton as `l` line
  ///   elements, plus the resampled boundary outline, unified with bridge
  ///   spokes. Takes precedence over delaunayMode and gridMode.
  /// [skeletonLambda] -- skeleton mode only: lambda-pruning strength in logical
  ///   px (minimum wall-to-wall separation for a point to count as skeleton).
  ///   Larger = only the primary frame survives; smaller = finer twigs kept.
  static String toOBJ(
    CompassLayer layer, {
    double samplingSpacing = 2.0,
    int minSamplesPerContour = 24,
    int maxSamplesPerContour = 4000,
    bool gridMode = false,
    int gridCount = 48,
    bool delaunayMode = false,
    double delaunaySpacing = 25.0,
    bool skeletonMode = false,
    double skeletonLambda = 20.0,
  }) {
    // Combine the standard fill with the variable-width ribbons
    Path path = layer.getLayerMeshExportPath(
      useExportImageMasks: true,
    );
    final areaPath = layer.getLayerStrokeAreaPath();

    if (areaPath.computeMetrics().isNotEmpty) {
      if (path.computeMetrics().isEmpty) {
        path = areaPath;
      } else {
        path = Path.combine(PathOperation.union, path, areaPath);
      }
    }

    // ---- 1. Flatten every contour to a polygon, keeping its own winding. ----
    final contours = <List<Offset>>[];
    for (final metric in path.computeMetrics()) {
      if (metric.length < 1e-3) continue;
      final pts = _sampleContour(
          metric, samplingSpacing, minSamplesPerContour, maxSamplesPerContour);
      if (pts.length >= 3) contours.add(pts);
    }
    if (contours.isEmpty) return '';

    final modeLabel = skeletonMode
        ? 'skeleton'
        : (delaunayMode ? 'delaunay' : (gridMode ? 'grid' : 'scanline'));
    debugPrint('[OBJ] mode: $modeLabel, contours found: ${contours.length}');
    for (int i = 0; i < contours.length; i++) {
      debugPrint('[OBJ]   contour $i: ${contours[i].length} pts, '
          'signedArea=${_signedArea(contours[i]).toStringAsFixed(2)}');
    }

    // ---- 2. Bounding box across all contours (shared by all modes). ----
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final poly in contours) {
      for (final p in poly) {
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }

    // Recenter offset -- the SAME bbox center in every mode, so a skeleton
    // export registers exactly with a fill export of the same layer.
    final cx = (minX + maxX) / 2.0;
    final cy = (minY + maxY) / 2.0;

    // ---- SKELETON MODE: extract + emit skeleton and outline, then return. ----
    // The medial kernel does its own lattice welding (vertices live on cell
    // centers), so the string-keyed weld map below is fill-mode machinery the
    // skeleton never touches.
    if (skeletonMode) {
      final skel = MedialAxisExtractor.extract(
        contours,
        gridCount: gridCount,
        lambda: skeletonLambda,
      );

      debugPrint('[OBJ] skeleton verts: ${skel.verts.length}, '
          'edges: ${skel.edges.length} '
          '(gridCount=$gridCount, lambda=$skeletonLambda)');

      if (skel.isEmpty) return '';

      debugPrint('[OBJ] recenter offset: ($cx, $cy) -> origin');

      int outlineVerts = 0;
      for (final poly in contours) {
        outlineVerts += poly.length;
      }

      final name = _sanitizeName(layer.name);
      final buffer = StringBuffer();
      buffer.writeln('# Exported from Compass');
      buffer.writeln('# Layer: ${layer.name}');
      buffer.writeln(
          '# skeleton: ${skel.verts.length} vertices, ${skel.edges.length} line segments');
      buffer.writeln(
          '# outline: $outlineVerts vertices, ${contours.length} closed loop(s)');
      buffer.writeln('# medial-axis skeleton ($gridCount across, '
          'lambda=$skeletonLambda) + resampled boundary outline, '
          'even-odd region; recentered, flat on Z=0');

      // =================================================================
      // 1. WRITE ALL VERTICES FIRST (Skeleton, then Outline)
      // =================================================================
      // By writing all vertices before any edges, we can freely draw lines 
      // connecting the skeleton to the outline.
      
      // Skeleton vertices (Global Indices: 1 to skel.verts.length)
      for (final v in skel.verts) {
        final ex = v.dx - cx;
        final ey = -(v.dy - cy); // Y-up for OBJ/Blender
        buffer.writeln('v $ex $ey 0');
      }

      // Outline vertices (Global Indices: skel.verts.length + 1 ...)
      int base = skel.verts.length; 
      final outlinePts = <(Offset, int)>[]; // Flat lookup for bridging
      
      for (final poly in contours) {
        for (final p in poly) {
          final ex = p.dx - cx;
          final ey = -(p.dy - cy); 
          buffer.writeln('v $ex $ey 0');
          outlinePts.add((p, base + 1));
          base++;
        }
      }

      // =================================================================
      // 2. WRITE EDGES (Skeleton + Outline + Bridges)
      // =================================================================
      // Emitting this all under ONE object name so Blender imports it as a 
      // single contiguous mesh, making the outline the true "outside edge".
      buffer.writeln('o ${name}_skeleton_mesh');
      
      // A. Write the core medial axis edges
      for (final e in skel.edges) {
        buffer.writeln('l ${e.$1 + 1} ${e.$2 + 1}');
      }

      // B. Write Outline Edges (closed loops)
      base = skel.verts.length; 
      for (final poly in contours) {
        final m = poly.length;
        for (int i = 0; i < m; i++) {
          final a = base + i + 1; 
          final b = base + ((i + 1) % m) + 1;
          buffer.writeln('l $a $b');
        }
        base += m;
      }

      // C. Bridge Edges: Connect EVERY outline vertex to the nearest skeleton node.
      // This seals the gap between the discrete grid/skeleton and the smooth boundary,
      // forming the "spokes" of the Voronoi cells.
      if (skel.verts.isNotEmpty) {
        for (final opt in outlinePts) {
          final outPt = opt.$1;
          final outIdx = opt.$2;
          
          double minDistSq = double.infinity;
          int bestSkelIndex = -1;
          
          for (int i = 0; i < skel.verts.length; i++) {
            final distSq = (skel.verts[i] - outPt).distanceSquared;
            if (distSq < minDistSq) {
              minDistSq = distSq;
              bestSkelIndex = i + 1; // 1-based global index
            }
          }
          
          if (bestSkelIndex != -1) {
            buffer.writeln('l $outIdx $bestSkelIndex');
          }
        }
      }

      return buffer.toString();
    }

    // ---- DELAUNAY MODE: kernel triangulation, emitted directly. -------------
    // Like the skeleton mode, the kernel owns its own welding (0.01 px lattice)
    // and hands back 0-based indices, so the fill modes' string-keyed weld map
    // below is never touched. Winding is pre-normalized by the kernel so the
    // Y-flip here yields uniform CCW (+Z-facing) faces in Blender.
    if (delaunayMode) {
      final tri = DelaunayTriangulator.triangulate(
        contours,
        interiorSpacing: delaunaySpacing,
      );

      debugPrint('[OBJ] delaunay verts: ${tri.verts.length}, '
          'triangles: ${tri.tris.length} '
          '(spacing=$delaunaySpacing)');

      if (tri.isEmpty) return '';

      debugPrint('[OBJ] recenter offset: ($cx, $cy) -> origin');

      final name = _sanitizeName(layer.name);
      final buffer = StringBuffer();
      buffer.writeln('# Exported from Compass');
      buffer.writeln('# Layer: ${layer.name}');
      buffer.writeln('# ${tri.verts.length} vertices, ${tri.tris.length} triangles');
      buffer.writeln('# delaunay tessellation (interior spacing '
          '$delaunaySpacing px), even-odd fill; recentered, flat on Z=0');
      buffer.writeln('o $name');
      for (final v in tri.verts) {
        final ex = v.dx - cx;
        final ey = -(v.dy - cy); // Y-up for OBJ/Blender
        buffer.writeln('v $ex $ey 0');
      }
      for (final t in tri.tris) {
        // Kernel indices are 0-based; OBJ is 1-based.
        buffer.writeln('f ${t.$1 + 1} ${t.$2 + 1} ${t.$3 + 1}');
      }
      return buffer.toString();
    }

    // ---- 3. Tessellate (mode-specific) into raw-coordinate verts + faces. ----
    final verts = <Offset>[];
    final vIndex = <String, int>{};
    final faces = <List<int>>[];

    int vid(double x, double y) {
      final key = '${(x / _weld).round()}_${(y / _weld).round()}';
      final existing = vIndex[key];
      if (existing != null) return existing;
      verts.add(Offset(x, y));
      final id = verts.length; // 1-based
      vIndex[key] = id;
      return id;
    }

    if (gridMode) {
      _tessellateGrid(contours, minX, minY, maxX, maxY, gridCount, vid, faces);
    } else {
      _tessellateScanline(contours, vid, faces);
    }

    debugPrint('[OBJ] verts: ${verts.length}, triangles: ${faces.length}');

    if (faces.isEmpty) return '';

    // ---- 4. Recenter on bbox center, Y-flip, emit. ----
    debugPrint('[OBJ] recenter offset: ($cx, $cy) -> origin');

    final name = _sanitizeName(layer.name);
    final buffer = StringBuffer();
    buffer.writeln('# Exported from Compass');
    buffer.writeln('# Layer: ${layer.name}');
    buffer.writeln('# ${verts.length} vertices, ${faces.length} triangles');
    buffer.writeln('# ${gridMode ? "grid ($gridCount across)" : "scanline"} '
        'tessellation, even-odd fill; recentered, flat on Z=0');
    buffer.writeln('o $name');
    for (final v in verts) {
      final ex = v.dx - cx;
      final ey = -(v.dy - cy); // Y-up for OBJ/Blender
      buffer.writeln('v $ex $ey 0');
    }
    for (final f in faces) {
      buffer.writeln('f ${f[0]} ${f[1]} ${f[2]}');
    }
    return buffer.toString();
  }

  /// Exports one IMG object's resolved Boolean mask as a textured OBJ surface.
  ///
  /// The mesh boundary is the mask: image pixels can only appear where triangles
  /// exist. Each emitted vertex is projected back through the IMG object's affine
  /// frame to generate a matching OBJ `vt` coordinate. The original JPG/PNG is
  /// referenced by a companion MTL file; the caller is responsible for copying it
  /// beside the OBJ using the filenames supplied here.
  ///
  /// Textured skeleton output is intentionally unsupported because skeleton mode
  /// emits loose edges rather than faces. Mirrored layers are also rejected for
  /// now: a fused mirrored silhouette needs a UV seam/material-ownership pass
  /// rather than one globally invertible image projection.
  static OBJTextureExport toTexturedOBJ(
    CompassLayer layer,
    CompassImage image, {
    required String materialLibraryFileName,
    required String textureFileName,
    double samplingSpacing = 2.0,
    int minSamplesPerContour = 24,
    int maxSamplesPerContour = 4000,
    bool gridMode = false,
    int gridCount = 48,
    bool delaunayMode = false,
    double delaunaySpacing = 25.0,
    bool skeletonMode = false,
  }) {
    if (skeletonMode) {
      return OBJTextureExport.empty(
        'IMG textures require a filled mesh; Skeleton mode exports edges only.',
      );
    }

    if (layer.mirrorEnabled) {
      return OBJTextureExport.empty(
        'Textured OBJ export does not yet support the layer Mirror Modifier.',
      );
    }

    if (!image.isVisible || !CompassLayer.hasLiftedImageFill(image)) {
      return OBJTextureExport.empty(
        'The selected IMG is not a visible Add object.',
      );
    }

    if (image.worldToUv(image.originOffset) == null) {
      return OBJTextureExport.empty(
        'The selected IMG frame is degenerate and cannot generate UV coordinates.',
      );
    }

    // Reconstruct the exact export surface instead of trusting the raw IMG
    // footprint. This guarantees a lone circle INTERSECT exports a circular
    // mesh (and multiple intersections still union into disconnected islands).
    final path = layer.getLayerImageExportMaskPath(image)
      ..fillType = PathFillType.evenOdd;

    final contours = <List<Offset>>[];
    for (final metric in path.computeMetrics()) {
      if (metric.length < 1e-3) continue;
      final pts = _sampleContour(
        metric,
        samplingSpacing,
        minSamplesPerContour,
        maxSamplesPerContour,
      );
      if (pts.length >= 3) contours.add(pts);
    }

    if (contours.isEmpty) {
      return OBJTextureExport.empty(
        'The selected IMG mask has no filled area to export.',
      );
    }

    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final poly in contours) {
      for (final p in poly) {
        if (p.dx < minX) minX = p.dx;
        if (p.dy < minY) minY = p.dy;
        if (p.dx > maxX) maxX = p.dx;
        if (p.dy > maxY) maxY = p.dy;
      }
    }

    final cx = (minX + maxX) / 2.0;
    final cy = (minY + maxY) / 2.0;
    final verts = <Offset>[];
    final faces = <List<int>>[];

    if (delaunayMode) {
      final tri = DelaunayTriangulator.triangulate(
        contours,
        interiorSpacing: delaunaySpacing,
      );
      if (tri.isEmpty) {
        return OBJTextureExport.empty(
          'The selected IMG mask could not be triangulated.',
        );
      }

      verts.addAll(tri.verts);
      for (final t in tri.tris) {
        faces.add([t.$1 + 1, t.$2 + 1, t.$3 + 1]);
      }
    } else {
      final vIndex = <String, int>{};

      int vid(double x, double y) {
        final key = '${(x / _weld).round()}_${(y / _weld).round()}';
        final existing = vIndex[key];
        if (existing != null) return existing;
        verts.add(Offset(x, y));
        final id = verts.length;
        vIndex[key] = id;
        return id;
      }

      if (gridMode) {
        _tessellateGrid(
          contours,
          minX,
          minY,
          maxX,
          maxY,
          gridCount,
          vid,
          faces,
        );
      } else {
        _tessellateScanline(contours, vid, faces);
      }
    }

    if (verts.isEmpty || faces.isEmpty) {
      return OBJTextureExport.empty(
        'The selected IMG mask has no triangulated faces to export.',
      );
    }

    final uvs = <Offset>[];
    for (final vertex in verts) {
      final uv = image.worldToUv(vertex);
      if (uv == null) {
        return OBJTextureExport.empty(
          'The selected IMG frame became degenerate while generating UVs.',
        );
      }
      uvs.add(uv);
    }

    final objectName = _sanitizeName('${layer.name}_${image.displayName}');
    final materialName = '${objectName}_material';
    final modeLabel = delaunayMode
        ? 'delaunay (spacing $delaunaySpacing px)'
        : (gridMode ? 'grid ($gridCount across)' : 'scanline');

    final obj = StringBuffer();
    obj.writeln('# Exported from Compass');
    obj.writeln('# Layer: ${layer.name}');
    obj.writeln('# IMG: ${image.displayName}');
    obj.writeln('# ${verts.length} vertices, ${faces.length} textured triangles');
    obj.writeln('# $modeLabel tessellation; IMG Boolean mask is the mesh boundary');
    obj.writeln('mtllib $materialLibraryFileName');
    obj.writeln('o $objectName');

    for (final vertex in verts) {
      final ex = vertex.dx - cx;
      final ey = -(vertex.dy - cy);
      obj.writeln('v $ex $ey 0');
    }
    for (final uv in uvs) {
      obj.writeln('vt ${uv.dx} ${uv.dy}');
    }

    obj.writeln('usemtl $materialName');
    obj.writeln('s off');
    for (final face in faces) {
      obj.writeln(
        'f ${face[0]}/${face[0]} ${face[1]}/${face[1]} ${face[2]}/${face[2]}',
      );
    }

    final alpha = image.opacity.clamp(0.0, 1.0).toDouble();
    final mtl = StringBuffer();
    mtl.writeln('# Exported from Compass');
    mtl.writeln('newmtl $materialName');
    mtl.writeln('Ka 0.000000 0.000000 0.000000');
    mtl.writeln('Kd 1.000000 1.000000 1.000000');
    mtl.writeln('Ks 0.000000 0.000000 0.000000');
    mtl.writeln('d $alpha');
    mtl.writeln('illum 1');
    mtl.writeln('map_Kd $textureFileName');
    // Importers that honor MTL opacity maps can preserve a transparent PNG.
    // Do not use a JPG as map_d: its luminance would incorrectly become alpha.
    if (textureFileName.toLowerCase().endsWith('.png')) {
      mtl.writeln('map_d $textureFileName');
    }

    return OBJTextureExport(
      objData: obj.toString(),
      mtlData: mtl.toString(),
      materialLibraryFileName: materialLibraryFileName,
      textureFileName: textureFileName,
      textureSourcePath: image.imagePath,
    );
  }

  // ===========================================================================
  // SCANLINE MODE  (the proven default -- robust, follows the curve, ugly topo)
  // ===========================================================================

  static void _tessellateScanline(
      List<List<Offset>> contours, int Function(double, double) vid, List<List<int>> faces) {
    // Flat edge list; drop ~horizontal edges (they don't cross a scanline cleanly).
    final edges = <_Edge>[];
    for (final poly in contours) {
      final m = poly.length;
      for (int i = 0; i < m; i++) {
        final a = poly[i];
        final b = poly[(i + 1) % m];
        if ((a.dy - b.dy).abs() < _minBand) continue;
        edges.add(_Edge(a, b));
      }
    }
    if (edges.isEmpty) return;

    // Scanlines = every distinct vertex Y.
    final ysSet = <double>{};
    for (final poly in contours) {
      for (final p in poly) {
        ysSet.add(p.dy);
      }
    }
    final ys = ysSet.toList()..sort();
    if (ys.length < 2) return;

    for (int b = 0; b < ys.length - 1; b++) {
      final yTop = ys[b];
      final yBot = ys[b + 1];
      if (yBot - yTop < _minBand) continue;
      final yMid = (yTop + yBot) * 0.5;

      final xs = <double>[];
      for (final e in edges) {
        if (yMid <= e.yTop || yMid >= e.yBot) continue;
        final t = (yMid - e.yTop) / (e.yBot - e.yTop);
        xs.add(e.xTop + t * (e.xBot - e.xTop));
      }
      if (xs.length < 2) continue;
      xs.sort();

      for (int k = 0; k + 1 < xs.length; k += 2) {
        final xL = xs[k];
        final xR = xs[k + 1];
        if (xR - xL < _minSpan) continue;

        final topL = _spanXAt(edges, yTop, xL, true);
        final topR = _spanXAt(edges, yTop, xR, false);
        final botL = _spanXAt(edges, yBot, xL, true);
        final botR = _spanXAt(edges, yBot, xR, false);

        final tl = vid(topL, yTop);
        final tr = vid(topR, yTop);
        final br = vid(botR, yBot);
        final bl = vid(botL, yBot);

        if (tl != tr && tr != br && tl != br) faces.add([tl, tr, br]);
        if (tl != br && br != bl && tl != bl) faces.add([tl, br, bl]);
      }
    }
  }

  // The X of the filled-span boundary at scanline `y`, nearest to `approxX`.
  static double _spanXAt(List<_Edge> edges, double y, double approxX, bool wantLeft) {
    double best = approxX;
    double bestDist = double.infinity;
    for (final e in edges) {
      if (y < e.yTop - _weld || y > e.yBot + _weld) continue;
      final dy = e.yBot - e.yTop;
      final t = dy.abs() < 1e-12 ? 0.0 : (y - e.yTop) / dy;
      final x = e.xTop + t * (e.xBot - e.xTop);
      final d = (x - approxX).abs();
      if (d < bestDist - 1e-9 ||
          (d < bestDist + 1e-9 && (wantLeft ? x < best : x > best))) {
        bestDist = d;
        best = x;
      }
    }
    return best;
  }

  // ===========================================================================
  // GRID MODE  (uniform quads inside, curve-clipped boundary cells, holes free)
  // ===========================================================================

  static void _tessellateGrid(
    List<List<Offset>> contours,
    double minX,
    double minY,
    double maxX,
    double maxY,
    int gridCount,
    int Function(double, double) vid,
    List<List<int>> faces,
  ) {
    final w = maxX - minX;
    final h = maxY - minY;
    if (w <= 0 || h <= 0 || gridCount < 1) return;

    // Square cells sized so the LONGEST side gets exactly `gridCount` of them.
    final cell = (w >= h ? w : h) / gridCount;
    if (cell <= 0) return;

    final cols = (w / cell).ceil();
    final rows = (h / cell).ceil();

    // Flat edge list for boundary-cell crossing tests (all edges, any orientation).
    final segs = <_Seg>[];
    for (final poly in contours) {
      final m = poly.length;
      for (int i = 0; i < m; i++) {
        segs.add(_Seg(poly[i], poly[(i + 1) % m]));
      }
    }

    for (int r = 0; r < rows; r++) {
      final y0 = minY + r * cell;
      final y1 = y0 + cell;
      for (int c = 0; c < cols; c++) {
        final x0 = minX + c * cell;
        final x1 = x0 + cell;

        // The four cell corners, clockwise from top-left in Compass (Y-down) space.
        final corners = <Offset>[
          Offset(x0, y0),
          Offset(x1, y0),
          Offset(x1, y1),
          Offset(x0, y1),
        ];
        final inside = [
          _pointInRegion(corners[0], contours),
          _pointInRegion(corners[1], contours),
          _pointInRegion(corners[2], contours),
          _pointInRegion(corners[3], contours),
        ];
        final insideCount = inside.where((b) => b).length;

        if (insideCount == 0) {
          // Fully outside, OR fully inside a hole. One more check distinguishes a
          // cell that straddles a hole RIM (some edge passes through, so it's still
          // a boundary cell we must clip) from one entirely in empty space. If any
          // contour edge clips this cell, fall through to boundary handling with an
          // empty inside-corner set; otherwise skip.
          if (!_anyEdgeIntersectsCell(segs, x0, y0, x1, y1)) continue;
          _emitBoundaryCell(corners, inside, contours, segs, x0, y0, x1, y1, vid, faces);
          continue;
        }

        if (insideCount == 4) {
          // Clean interior quad -> two triangles. Still verify no contour edge cuts
          // through it (a thin feature could clip a cell whose corners are all in);
          // if one does, treat it as a boundary cell so the cut is honored.
          if (_anyEdgeIntersectsCell(segs, x0, y0, x1, y1)) {
            _emitBoundaryCell(corners, inside, contours, segs, x0, y0, x1, y1, vid, faces);
          } else {
            final a = vid(corners[0].dx, corners[0].dy);
            final b = vid(corners[1].dx, corners[1].dy);
            final cc = vid(corners[2].dx, corners[2].dy);
            final d = vid(corners[3].dx, corners[3].dy);
            if (a != b && b != cc && a != cc) faces.add([a, b, cc]);
            if (a != cc && cc != d && a != d) faces.add([a, cc, d]);
          }
          continue;
        }

        // 1, 2, or 3 corners inside -> boundary cell, clip to the inside portion.
        _emitBoundaryCell(corners, inside, contours, segs, x0, y0, x1, y1, vid, faces);
      }
    }
  }

  // Builds the inside polygon of a partially-filled cell and fans it into tris.
  //
  // The inside polygon = (inside corners) + (points where contours cross the cell's
  // four edges), walked in angular order around the cell center so the fan is
  // non-self-overlapping. This is the "simple clip": it assumes the inside portion
  // is a single connected piece, which holds for a smooth boundary (a circle rim,
  // a spline edge) crossing a cell. A cell a thin sliver passes through, or one with
  // two disjoint inside pieces, can merge them -- a slightly-wrong boundary cell,
  // never a global blowup. Raising gridCount shrinks any such cell toward nothing.
  static void _emitBoundaryCell(
    List<Offset> corners,
    List<bool> inside,
    List<List<Offset>> contours,
    List<_Seg> segs,
    double x0,
    double y0,
    double x1,
    double y1,
    int Function(double, double) vid,
    List<List<int>> faces,
  ) {
    final poly = <Offset>[];

    // 1. Inside corners.
    for (int i = 0; i < 4; i++) {
      if (inside[i]) poly.add(corners[i]);
    }

    // 2. Contour crossings on each of the four cell edges.
    final cellEdges = <(Offset, Offset)>[
      (corners[0], corners[1]), // top
      (corners[1], corners[2]), // right
      (corners[2], corners[3]), // bottom
      (corners[3], corners[0]), // left
    ];
    for (final ce in cellEdges) {
      for (final s in segs) {
        final hit = _segSegIntersect(ce.$1, ce.$2, s.a, s.b);
        if (hit != null) poly.add(hit);
      }
    }

    if (poly.length < 3) return;

    // 3. Order the polygon vertices CCW around the cell center, dedup near-coincident.
    final cxp = (x0 + x1) * 0.5;
    final cyp = (y0 + y1) * 0.5;
    poly.sort((p, q) =>
        atan2(p.dy - cyp, p.dx - cxp).compareTo(atan2(q.dy - cyp, q.dx - cxp)));

    final cleaned = <Offset>[];
    for (final p in poly) {
      if (cleaned.isEmpty || (p - cleaned.last).distanceSquared > _weld * _weld) {
        cleaned.add(p);
      }
    }
    if (cleaned.length >= 2 &&
        (cleaned.first - cleaned.last).distanceSquared <= _weld * _weld) {
      cleaned.removeLast();
    }
    if (cleaned.length < 3) return;

    // 4. Fan from vertex 0. The clipped cell polygon is convex-ish (a square corner
    // chopped by a near-straight boundary), so a triangle fan is valid and clean.
    final i0 = vid(cleaned[0].dx, cleaned[0].dy);
    for (int i = 1; i + 1 < cleaned.length; i++) {
      final i1 = vid(cleaned[i].dx, cleaned[i].dy);
      final i2 = vid(cleaned[i + 1].dx, cleaned[i + 1].dy);
      if (i0 != i1 && i1 != i2 && i0 != i2) faces.add([i0, i1, i2]);
    }
  }

  // Even-odd point-in-region across ALL contours at once (winding carries the hole
  // signal, so a point inside the outer but inside a hole nets to OUTSIDE). Same
  // rule the scanline mode and the canvas fill use.
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

  // True if any contour edge intersects the cell rectangle (crosses an edge of it,
  // or lies within it). Cheap reject by the segment's own bbox vs the cell first.
  static bool _anyEdgeIntersectsCell(
      List<_Seg> segs, double x0, double y0, double x1, double y1) {
    for (final s in segs) {
      // Bbox reject.
      if (s.minX > x1 || s.maxX < x0 || s.minY > y1 || s.maxY < y0) continue;
      // An endpoint strictly inside the cell?
      if (s.a.dx > x0 && s.a.dx < x1 && s.a.dy > y0 && s.a.dy < y1) return true;
      if (s.b.dx > x0 && s.b.dx < x1 && s.b.dy > y0 && s.b.dy < y1) return true;
      // Crosses any of the four cell edges?
      final tl = Offset(x0, y0), tr = Offset(x1, y0);
      final br = Offset(x1, y1), bl = Offset(x0, y1);
      if (_segSegIntersect(tl, tr, s.a, s.b) != null) return true;
      if (_segSegIntersect(tr, br, s.a, s.b) != null) return true;
      if (_segSegIntersect(br, bl, s.a, s.b) != null) return true;
      if (_segSegIntersect(bl, tl, s.a, s.b) != null) return true;
    }
    return false;
  }

  // Segment-segment intersection point, or null if they don't properly cross.
  static Offset? _segSegIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
    final d1x = p2.dx - p1.dx, d1y = p2.dy - p1.dy;
    final d2x = p4.dx - p3.dx, d2y = p4.dy - p3.dy;
    final denom = d1x * d2y - d1y * d2x;
    if (denom.abs() < 1e-12) return null; // parallel / collinear
    final t = ((p3.dx - p1.dx) * d2y - (p3.dy - p1.dy) * d2x) / denom;
    final u = ((p3.dx - p1.dx) * d1y - (p3.dy - p1.dy) * d1x) / denom;
    if (t < -1e-9 || t > 1 + 1e-9 || u < -1e-9 || u > 1 + 1e-9) return null;
    return Offset(p1.dx + t * d1x, p1.dy + t * d1y);
  }

  // ---------------------------------------------------------------------------
  // SAMPLING (shared)
  // ---------------------------------------------------------------------------

  static List<Offset> _sampleContour(
      PathMetric metric, double spacing, int minS, int maxS) {
    final length = metric.length;
    int count = (length / spacing).floor();
    if (count < minS) count = minS;
    if (count > maxS) count = maxS;

    final step = length / count;
    final out = <Offset>[];
    for (int i = 0; i < count; i++) {
      final t = metric.getTangentForOffset(i * step);
      if (t == null) continue;
      final p = t.position;
      if (out.isNotEmpty && (p - out.last).distanceSquared < 1e-10) continue;
      out.add(p);
    }
    if (out.length >= 2 && (out.first - out.last).distanceSquared <= 1e-10) {
      out.removeLast();
    }
    return out;
  }

  // ---------------------------------------------------------------------------

  static double _signedArea(List<Offset> poly) {
    double a = 0;
    final m = poly.length;
    for (int i = 0; i < m; i++) {
      final p = poly[i];
      final q = poly[(i + 1) % m];
      a += p.dx * q.dy - q.dx * p.dy;
    }
    return a / 2.0;
  }

  static String _sanitizeName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_\-.]'), '');
    return cleaned.isEmpty ? 'layer' : cleaned;
  }
}

// A non-horizontal contour edge, normalized so yTop < yBottom (scanline mode).
class _Edge {
  final double xTop, yTop, xBot, yBot;

  factory _Edge(Offset a, Offset b) {
    if (a.dy <= b.dy) {
      return _Edge._(a.dx, a.dy, b.dx, b.dy);
    } else {
      return _Edge._(b.dx, b.dy, a.dx, a.dy);
    }
  }

  _Edge._(this.xTop, this.yTop, this.xBot, this.yBot);
}

// A contour segment with a cached bbox (grid-mode boundary tests).
class _Seg {
  final Offset a, b;
  final double minX, minY, maxX, maxY;

  _Seg(this.a, this.b)
      : minX = a.dx < b.dx ? a.dx : b.dx,
        minY = a.dy < b.dy ? a.dy : b.dy,
        maxX = a.dx > b.dx ? a.dx : b.dx,
        maxY = a.dy > b.dy ? a.dy : b.dy;
}