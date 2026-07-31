// /lib/io/obj_material.dart

/// MATERIAL DOMAIN for the OBJ exporter: turns one layer's *appearance* into a
/// set of disjoint filled REGIONS, each carrying an OBJ material and (when the
/// material is textured) a world-space -> UV projection.
///
/// This is the generalization of the IMG-only path in obj_exporter.dart. That
/// path worked because an IMG object's appearance is a single globally
/// invertible affine map (worldToUv), so every vertex -- no matter which
/// tessellator produced it -- resolves to one correct UV. The insight this file
/// rests on is that the SAME property holds for every other fill Compass can
/// paint:
///
///   * a FLAT fill is a constant function of world position (one Kd, no UVs);
///   * a GRADIENT fill is `projectPosition(worldPoint)` -- already implemented
///     in gradient.dart, already branching linear (orthogonal projection onto
///     the axis) vs circular (radial distance / radius), already clamped to
///     [0,1]. That is literally a 1-D texture coordinate.
///
/// So every material here is a pure function of world position, which is what
/// makes vertex welding safe: two coincident vertices always resolve to the
/// same UV regardless of which triangle produced them.
///
/// GRADIENTS BAKE TO A 1-D RAMP, NOT A RASTER OF THE ARTWORK. A 256x4 PNG of
/// the resolved stop ramp is sampled at `u = projectPosition(v)`, `v = 0.5`.
/// Rasterizing the gradient over its bounding box instead would (a) fix the
/// color resolution to whatever pixel density we guessed, (b) cost a megapixel
/// sidecar per gradient, and (c) reintroduce the exact "painted-on rectangle"
/// failure the IMG mask work eliminated. The ramp is ~1 KB, exact at any mesh
/// scale, and one code path covers linear AND circular because the branch lives
/// inside projectPosition.
///
/// MIRROR. Flat fill, stroke area, and colored bands arrive already mirrored --
/// getLayerFillPath / getLayerStrokeAreaPath / getStrokeAddBandOverpaints all
/// end in applyMirror. The self-painted clip getters deliberately do NOT (the
/// renderer reflects clip geometry and reuses the same world-space shader), so
/// this file unions in the reflection itself. A GRADIENT SURVIVES THAT
/// correctly and needs no seam pass: the ramp is world-space, so a reflected
/// vertex projects onto the same untransformed axis and the color flows
/// straight across the seam -- identical to the canvas and to the SVG <use>
/// path. An IMG does not: one affine frame cannot invert across the reflection,
/// so mirrored layers drop their IMG regions with a warning rather than failing
/// the whole export (you still get correctly mirrored flat + gradient
/// geometry).
///
/// GRADIENT MESHES BAKE TO A 2-D PATCH TEXTURE. A Coons color field is the one
/// fill Compass paints that is NOT a simple function of world position, so it
/// gets the same treatment a raster does: render the mesh's own
/// `drawVertices` output offscreen over its bounding box, and hand the mesh
/// region a planar unwrap of that box. The region PATH comes from
/// `getLayerMeshClipPath`, which already resolves every subtract and intersect
/// operating on the mesh -- so a circle cutting into a mesh carves the exported
/// silhouette exactly as it does on canvas.
///
/// NOT COVERED, deliberately:
///   * The layer HAIRLINE (layer.strokeWidth on getLayerPath). It is an
///     outline, not an area: there is nothing to tessellate into faces. Stroke
///     RINGS are the modelled equivalent and are covered.
///   * A mesh acting as a boolean OPERAND. `layer.dart` skips meshes in every
///     boolean walk, so a mesh set to Subtract carves nothing anywhere --
///     canvas included. That is upstream behavior, not a decision made here.
///
/// Pure-ish: depends on dart:ui + the geometry models. Owns no engine state.
/// Async only because baking a ramp goes through PictureRecorder -> toImage.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/layer.dart';
import '../models/geometry/gradient.dart';
import '../models/geometry/image.dart';
import '../models/geometry/mesh.dart';

/// What kind of surface appearance a material represents.
enum ObjMaterialSource {
  /// Constant color. Emits Kd/d only -- no texture, no UVs.
  flat,

  /// Per-shape gradient fill, baked to a 1-D ramp PNG sidecar.
  ramp,

  /// Coons gradient mesh, baked to a 2-D patch PNG sidecar.
  mesh,

  /// IMG object, referencing a copy of the source raster.
  image,
}

/// A world-space -> UV projection. Returns null when the source frame is
/// degenerate and cannot be inverted (only reachable for [ObjMaterialSource.image];
/// the collector pre-rejects those, so a null here is a genuine mid-export
/// degeneracy and the exporter should abort rather than emit garbage UVs).
typedef ObjUvProjector = Offset? Function(Offset worldPoint);

/// One file that must be written beside the .obj/.mtl pair.
///
/// Exactly one of [bytes] / [sourcePath] is non-null: baked ramps arrive as
/// bytes, IMG textures as a path to copy. Keeping both shapes in one type lets
/// the dialog write the whole manifest in a single loop.
class ObjSidecarFile {
  final String fileName;
  final Uint8List? bytes;
  final String? sourcePath;

  const ObjSidecarFile.data({
    required this.fileName,
    required Uint8List this.bytes,
  }) : sourcePath = null;

  const ObjSidecarFile.copy({
    required this.fileName,
    required String this.sourcePath,
  }) : bytes = null;

  bool get isCopy => sourcePath != null;
}

/// One resolved OBJ material.
///
/// Materials are DEDUPED BY CONTENT (see [_MaterialInterner]), so a five-ring
/// tree-ring circle whose rings share two colors exports two materials, not
/// five. Note this is possible for ramps too even though their AXES differ: the
/// axis lives on the REGION's projector, not on the material, so two shapes
/// carrying the same stop ramp at different orientations share one texture.
class ObjMaterial {
  final String name;
  final ObjMaterialSource source;

  /// Diffuse color. White for textured materials so the map is not tinted.
  final Color diffuse;

  /// Dissolve (`d`). Layer/shape alpha, already clamped to [0,1].
  final double alpha;

  /// Texture filename as referenced from the MTL, or null for [ObjMaterialSource.flat].
  final String? textureFileName;

  /// True when [textureFileName] is a PNG and may therefore also serve as an
  /// alpha map. Never set for JPG: its luminance would silently become alpha.
  final bool textureCarriesAlpha;

  const ObjMaterial({
    required this.name,
    required this.source,
    required this.diffuse,
    required this.alpha,
    this.textureFileName,
    this.textureCarriesAlpha = false,
  });

  bool get isTextured => textureFileName != null;
}

/// One filled region of the layer's appearance: a world-space path plus the
/// material to paint it with.
///
/// [path] is FINAL -- mirror already applied, already made disjoint against
/// every later-painted region. The exporter tessellates it with the ordinary
/// scanline/grid/delaunay kernels and needs no further boolean work.
class ObjMaterialRegion {
  /// Group label, emitted as `g` so the region is selectable in Blender.
  final String label;

  final Path path;
  final ObjMaterial material;

  /// Null for flat materials. The exporter substitutes a planar unwrap over the
  /// global bounding box, so every face still emits as `v/vt`.
  final ObjUvProjector? uv;

  const ObjMaterialRegion({
    required this.label,
    required this.path,
    required this.material,
    this.uv,
  });
}

/// Everything the exporter and the save dialog need for one layer.
class ObjMaterialSet {
  /// Paint-order regions, mutually exclusive, all non-empty.
  final List<ObjMaterialRegion> regions;

  /// Distinct materials referenced by [regions], in first-use order.
  final List<ObjMaterial> materials;

  /// Files to write beside the .obj (baked ramps, copied textures).
  final List<ObjSidecarFile> sidecars;

  /// Non-fatal notes for the caller to surface (e.g. IMG dropped under mirror).
  final List<String> warnings;

  /// Human-readable trace of every collection DECISION -- which shapes became
  /// regions, which were skipped, and why. Distinct from [warnings]: a warning
  /// is something the user needs to know about their document, a diagnostic is
  /// something the developer needs to know about the export.
  ///
  /// Exists because the failure mode this class is most prone to is silence:
  /// an empty region list produces "nothing to export" with no indication of
  /// whether the layer was genuinely blank, or full of geometry that every
  /// collection branch happened to decline. Defaulted so callers that build a
  /// set by hand (the exporter's MTL-only path) need not supply one.
  final List<String> diagnostics;

  const ObjMaterialSet({
    required this.regions,
    required this.materials,
    required this.sidecars,
    required this.warnings,
    this.diagnostics = const [],
  });

  bool get isEmpty => regions.isEmpty;

  /// Serializes [materials] to MTL text.
  ///
  /// Field choices mirror the existing textured-IMG writer so both paths import
  /// identically: black Ka/Ks (Compass has no ambient or specular model),
  /// `illum 1` (diffuse, no specular), and `d` carrying opacity. Textured
  /// materials force `Kd 1 1 1` so the map arrives untinted.
  ///
  /// STATIC, taking the material list directly, because the exporter prunes
  /// materials AFTER tessellation -- by then the region list is stale, and an
  /// instance method would force it to construct a throwaway set just to reach
  /// this text. [toMtl] is the instance convenience for callers that still hold
  /// a live set.
  static String materialsToMtl(List<ObjMaterial> materials) {
    final buffer = StringBuffer();
    buffer.writeln('# Exported from Compass');

    for (final material in materials) {
      final color = material.isTextured ? Colors.white : material.diffuse;
      final r = (color.red / 255.0).toStringAsFixed(6);
      final g = (color.green / 255.0).toStringAsFixed(6);
      final b = (color.blue / 255.0).toStringAsFixed(6);

      buffer.writeln();
      buffer.writeln('newmtl ${material.name}');
      buffer.writeln('Ka 0.000000 0.000000 0.000000');
      buffer.writeln('Kd $r $g $b');
      buffer.writeln('Ks 0.000000 0.000000 0.000000');
      buffer.writeln('d ${material.alpha.toStringAsFixed(6)}');
      buffer.writeln('illum 1');

      final texture = material.textureFileName;
      if (texture != null) {
        buffer.writeln('map_Kd $texture');
        // A ramp is always PNG, and its stops may carry alpha; an IMG only
        // qualifies when the source really is a PNG.
        if (material.textureCarriesAlpha) {
          buffer.writeln('map_d $texture');
        }
      }
    }

    return buffer.toString();
  }

  String toMtl() => materialsToMtl(materials);
}

/// Content-keyed material pool. The key is whatever fully determines the
/// emitted MTL block, so equal appearance always collapses to one material.
class _MaterialInterner {
  final List<ObjMaterial> materials = [];
  final List<ObjSidecarFile> sidecars = [];
  final Map<String, ObjMaterial> _byKey = {};
  final String stem;

  int _rampCount = 0;
  int _imageCount = 0;
  int _meshCount = 0;

  _MaterialInterner(this.stem);

  ObjMaterial flat(Color color) {
    final alpha = color.alpha / 255.0;
    final key = 'flat:${color.value}';
    final existing = _byKey[key];
    if (existing != null) return existing;

    final material = ObjMaterial(
      name: '${stem}_flat_${_hex(color)}',
      source: ObjMaterialSource.flat,
      diffuse: color,
      alpha: alpha,
    );
    _register(key, material);
    return material;
  }

  /// Interns a ramp material, baking the PNG on first use. Returns null when
  /// the bake fails (guarded upstream: the collector only reaches here for a
  /// gradient with a usable axis and >= 2 resolved stops).
  Future<ObjMaterial?> ramp(LinearGradientFill gradient, double alpha) async {
    final key = 'ramp:${_rampKey(gradient)}:${alpha.toStringAsFixed(4)}';
    final existing = _byKey[key];
    if (existing != null) return existing;

    final bytes = await ObjMaterialCollector.bakeRampPng(gradient);
    if (bytes == null) return null;

    // One index for BOTH strings, so material `stem_gradient0` is obviously the
    // one that samples `stem_ramp0.png` when you are reading the MTL by eye.
    final index = _rampCount++;
    final fileName = '${stem}_ramp$index.png';

    final material = ObjMaterial(
      name: '${stem}_gradient$index',
      source: ObjMaterialSource.ramp,
      diffuse: Colors.white,
      alpha: alpha,
      textureFileName: fileName,
      // Ramps are always PNG, so stop alpha round-trips through map_d.
      textureCarriesAlpha: true,
    );
    _register(key, material);
    sidecars.add(ObjSidecarFile.data(fileName: fileName, bytes: bytes));
    return material;
  }

  ObjMaterial image(CompassImage source) {
    final alpha = source.opacity.clamp(0.0, 1.0).toDouble();
    final key = 'image:${source.imagePath}:${alpha.toStringAsFixed(4)}';
    final existing = _byKey[key];
    if (existing != null) return existing;

    final extension = _extensionOf(source.imagePath);
    final index = _imageCount++;
    final fileName = '${stem}_texture$index$extension';

    final material = ObjMaterial(
      name: '${stem}_img$index',
      source: ObjMaterialSource.image,
      diffuse: Colors.white,
      alpha: alpha,
      textureFileName: fileName,
      textureCarriesAlpha: extension == '.png',
    );
    _register(key, material);
    sidecars.add(
      ObjSidecarFile.copy(fileName: fileName, sourcePath: source.imagePath),
    );
    return material;
  }

  /// Interns a mesh patch material around an already-baked PNG.
  ///
  /// Keyed by IDENTITY rather than content, unlike every other material here.
  /// Two meshes being pixel-identical is vanishingly rare, and proving it would
  /// mean hashing every node position, tension, and color -- more work than the
  /// one duplicate texture it might save. Identity never merges two meshes
  /// wrongly; it just declines to merge two that happen to match.
  ObjMaterial mesh(CompassMesh source, Uint8List bytes) {
    final key = 'mesh:${identityHashCode(source)}';
    final existing = _byKey[key];
    if (existing != null) return existing;

    final index = _meshCount++;
    final fileName = '${stem}_mesh$index.png';

    final material = ObjMaterial(
      name: '${stem}_mesh$index',
      source: ObjMaterialSource.mesh,
      diffuse: Colors.white,
      alpha: 1.0,
      textureFileName: fileName,
      // NO map_d. The bake composites the color field over an opaque average-
      // color background (see bakeMeshPng), so the PNG is opaque throughout and
      // an alpha map would be a no-op at best. The tradeoff is explicit: mesh
      // vertex alpha is FLATTENED rather than exported.
      textureCarriesAlpha: false,
    );
    _register(key, material);
    sidecars.add(ObjSidecarFile.data(fileName: fileName, bytes: bytes));
    return material;
  }

  void _register(String key, ObjMaterial material) {
    _byKey[key] = material;
    materials.add(material);
  }

  // Identity of a ramp = its type plus its resolved (position, color) list.
  // resolvedStops() already sorts, so two gradients that render identically
  // hash identically even if their stop LISTS are ordered differently.
  static String _rampKey(LinearGradientFill gradient) {
    final buffer = StringBuffer(gradient.type.name);
    for (final stop in gradient.resolvedStops()) {
      buffer.write('|${stop.$1.toStringAsFixed(5)}:${stop.$2.value}');
    }
    return buffer.toString();
  }

  static String _hex(Color c) => c.value.toRadixString(16).padLeft(8, '0');

  static String _extensionOf(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '.png';
    final ext = name.substring(dot).toLowerCase();
    return (ext == '.png' || ext == '.jpg' || ext == '.jpeg') ? ext : '.png';
  }
}

/// Builds the material set for one layer.
class ObjMaterialCollector {
  ObjMaterialCollector._();

  /// Ramp texture dimensions. 256 columns is one texel per 8-bit color step --
  /// finer than any downstream renderer will resolve on a gradient. 4 rows only
  /// because some importers dislike 1-pixel-tall maps; every row is identical
  /// and we always sample v = 0.5.
  static const int rampWidth = 256;
  static const int rampHeight = 4;

  /// Baked mesh-patch resolution along the LONGEST bounding-box side. 512 is a
  /// deliberate middle: a Coons field is smooth by construction, so it survives
  /// modest resolution well, and a mesh-heavy document should not drop tens of
  /// megabytes of sidecars next to a small OBJ.
  static const int meshTextureMaxDim = 512;

  /// Padding around a baked mesh patch, in texels. See [bakeMeshPatchPng].
  static const double _meshTexturePadTexels = 2.0;

  /// Maps a normalized gradient position `t` onto the ramp texture's TEXEL
  /// CENTERS. Paired with [bakeRampPng]; changing one without the other
  /// silently shifts every exported ramp by half a texel.
  ///
  /// WHY THIS EXISTS -- the alternative (emitting raw t as u) is wrong at both
  /// ends, and wrong in the most visible possible way. u = 0 in normalized
  /// texture space is the LEFT EDGE of texel 0, not its centre. Under bilinear
  /// filtering with a Repeat/wrap extension -- Blender's default for imported
  /// image textures -- sampling there blends texel 0 with texel 255 ACROSS THE
  /// SEAM, i.e. the gradient's start color mixed 50/50 with its end color. The
  /// same happens at u = 1.
  ///
  /// That is not a subtle edge artifact, because [LinearGradientFill
  /// .projectPosition] CLAMPS: every vertex lying before the axis start
  /// projects to exactly t = 0, so an entire region of the mesh -- the flat
  /// plateau beyond the first stop -- lands on that one bad sample and renders
  /// as a single wrong-colored patch.
  ///
  /// Insetting to texel centres removes the problem at the source rather than
  /// depending on the importer: u never approaches the seam, so Repeat, Extend,
  /// and Clip all sample identically, and no `-clamp on` flag is needed in the
  /// MTL (which not every importer honors anyway).
  ///
  ///   t = 0 -> u = 0.5 / 256         (centre of texel 0   = start color, exact)
  ///   t = 1 -> u = 255.5 / 256       (centre of texel 255 = end color, exact)
  static double rampU(double t) {
    final clamped = t.clamp(0.0, 1.0);
    return (0.5 + clamped * (rampWidth - 1)) / rampWidth;
  }

  /// Collects [layer]'s appearance into disjoint, material-tagged regions.
  ///
  /// [fileStem] seeds material and sidecar names, so it should be the OBJ's
  /// base filename (already sanitized by the caller).
  ///
  /// PAINT ORDER, matching CompassRenderer exactly:
  ///   1a.  flat boolean fill            (layer.color)
  ///   1a'. self-painted fills           (gradients + IMG, in shape order)
  ///   1c.  variable-width stroke area   (layer.strokeColor)
  ///   1c'. colored stroke ADD bands     (own colors, in stack order)
  ///
  /// The order matters twice: it is the group order in the OBJ, and it drives
  /// the disjointness pass below.
  static Future<ObjMaterialSet> collect(
    CompassLayer layer, {
    required String fileStem,
  }) async {
    final interner = _MaterialInterner(fileStem);
    final warnings = <String>[];
    final regions = <ObjMaterialRegion>[];
    final diagnostics = <String>[];

    // Every branch below logs its decision, including the negative ones. The
    // whole point is that "no painted area" should never again be a dead end:
    // the log says which shapes existed, what each one was classified as, and
    // which test rejected it.
    void log(String line) {
      diagnostics.add(line);
      debugPrint('[OBJ-MAT] $line');
    }

    String describePath(Path p) {
      if (!_isNotEmpty(p)) return 'EMPTY';
      final b = p.getBounds();
      return 'bounds=(${b.left.toStringAsFixed(1)}, ${b.top.toStringAsFixed(1)})'
          '-(${b.right.toStringAsFixed(1)}, ${b.bottom.toStringAsFixed(1)}) '
          'contours=${p.computeMetrics().length}';
    }

    log('layer "${layer.name}" stem="$fileStem" '
        'shapes=${layer.shapes.length} '
        'mirror=${layer.mirrorEnabled ? layer.mirrorAxis.name : "off"}');

    // ---- 1a. Flat fill -----------------------------------------------------
    // getLayerFillPath already excludes lifted self-painted shapes (the same
    // `continue` the renderer relies on), so flat and gradient/IMG regions are
    // disjoint by construction before the pass below ever runs.
    final fillPath = layer.getLayerFillPath();
    final fillAlpha = layer.color.alpha;
    if (fillAlpha == 0) {
      log('flat fill: SKIPPED — layer color is fully transparent');
    } else if (!_isNotEmpty(fillPath)) {
      // The usual cause is a boolean walk that never got seeded: only `add` can
      // establish an empty master, so a layer whose only contributors are
      // subtract/intersect -- or whose sole ADD shape is a gradient mesh, which
      // every OBJ path skips -- resolves to nothing here.
      log('flat fill: SKIPPED — getLayerFillPath() resolved EMPTY '
          '(layer color 0x${layer.color.value.toRadixString(16).padLeft(8, "0")})');
    } else {
      log('flat fill: region "fill" — ${describePath(fillPath)}');
      regions.add(ObjMaterialRegion(
        label: 'fill',
        path: fillPath,
        material: interner.flat(layer.color),
      ));
    }

    // ---- 1a'. Self-painted fills ------------------------------------------
    var gradientIndex = 0;
    var imageIndex = 0;

    for (var shapeIndex = 0; shapeIndex < layer.shapes.length; shapeIndex++) {
      final shape = layer.shapes[shapeIndex];
      final tag = 'shape[$shapeIndex] ${shape.runtimeType} '
          'op=${shape.operation.name}';

      if (!shape.isVisible) {
        log('$tag: SKIPPED — hidden');
        continue;
      }

      if (CompassLayer.hasLiftedGradientFill(shape)) {
        final gradient = shape.gradient!;
        final clip = _withMirror(layer, layer.getLayerSelfPaintedClipPath(shape));
        if (!_isNotEmpty(clip)) {
          log('$tag: SKIPPED — gradient clip resolved EMPTY '
              '(fully carved by a later shape?)');
          continue;
        }

        // A gradient with fewer than two stops (or coincident handles) renders
        // as a SOLID on canvas via solidColor. Mirror that here instead of
        // baking a degenerate one-color ramp and paying for a sidecar.
        if (!gradient.hasUsableAxis) {
          final solid = gradient.solidColor;
          if (solid == null) {
            log('$tag: SKIPPED — gradient has no usable axis and no solid color');
            continue;
          }
          log('$tag: region "gradient$gradientIndex" as FLAT '
              '(${gradient.stops.length} stop(s), no usable axis) — '
              '${describePath(clip)}');
          regions.add(ObjMaterialRegion(
            label: 'gradient${gradientIndex++}',
            path: clip,
            material: interner.flat(solid),
          ));
          continue;
        }

        final material = await interner.ramp(gradient, 1.0);
        if (material == null) {
          log('$tag: SKIPPED — ramp bake failed');
          warnings.add('A gradient fill could not be baked and was skipped.');
          continue;
        }

        log('$tag: region "gradient$gradientIndex" as ${gradient.type.name.toUpperCase()} '
            'RAMP (${gradient.stops.length} stops, material ${material.name}) — '
            '${describePath(clip)}');

        regions.add(ObjMaterialRegion(
          label: 'gradient${gradientIndex++}',
          path: clip,
          material: material,
          // THE WHOLE TRICK: the gradient's own world-space parameterization IS
          // the texture coordinate. Linear vs circular is resolved inside
          // projectPosition, which also clamps to [0,1] -- so the plateaus
          // beyond the first and last stop are real, and land on exactly t = 0
          // and t = 1. rampU then maps those onto texel CENTRES, which is what
          // keeps those plateaus a clean solid color instead of a seam blend.
          uv: (world) => Offset(
            rampU(gradient.projectPosition(world)),
            0.5,
          ),
        ));
        continue;
      }

      if (CompassLayer.hasLiftedImageFill(shape)) {
        final image = shape as CompassImage;

        // One affine frame cannot invert across a reflection, so a mirrored
        // IMG would need a UV-seam / material-ownership pass. Drop the region
        // rather than the export: flat and gradient geometry still mirror
        // correctly, which is the useful half of the result.
        if (layer.mirrorEnabled) {
          log('$tag: SKIPPED — IMG under Mirror Modifier');
          warnings.add(
            'IMG "${image.displayName}" was skipped: textured export does not '
            'yet support the layer Mirror Modifier.',
          );
          continue;
        }

        if (image.worldToUv(image.originOffset) == null) {
          log('$tag: SKIPPED — IMG frame is degenerate (non-invertible)');
          warnings.add(
            'IMG "${image.displayName}" was skipped: its frame is degenerate '
            'and cannot generate UV coordinates.',
          );
          continue;
        }

        final clip = layer.getLayerImageExportMaskPath(image);
        if (!_isNotEmpty(clip)) {
          log('$tag: SKIPPED — IMG export mask resolved EMPTY');
          continue;
        }

        log('$tag: region "img$imageIndex" — ${image.displayName} — '
            '${describePath(clip)}');

        regions.add(ObjMaterialRegion(
          label: 'img${imageIndex++}',
          path: clip,
          material: interner.image(image),
          uv: image.worldToUv,
        ));
        continue;
      }

      // Everything else either rode the flat fill above, or is handled by a
      // later pass. Meshes are deferred rather than skipped: the renderer
      // paints them AFTER fills, stroke areas, and colored bands, and the
      // disjointness pass depends on collection order matching paint order.
      if (shape is CompassMesh) {
        log('$tag: deferred to the mesh pass (painted last)');
      } else {
        log('$tag: flat-fill contributor (no self-painted fill of its own)');
      }
    }

    // ---- 1c. Variable-width stroke area ------------------------------------
    final strokeAreaPath = layer.getLayerStrokeAreaPath();
    if (layer.strokeColor.alpha == 0) {
      log('stroke area: SKIPPED — layer stroke color is fully transparent');
    } else if (!_isNotEmpty(strokeAreaPath)) {
      log('stroke area: SKIPPED — getLayerStrokeAreaPath() resolved EMPTY');
    } else {
      log('stroke area: region "stroke_area" — ${describePath(strokeAreaPath)}');
      regions.add(ObjMaterialRegion(
        label: 'stroke_area',
        path: strokeAreaPath,
        material: interner.flat(layer.strokeColor),
      ));
    }

    // ---- 1c'. Colored stroke ADD bands -------------------------------------
    // These arrive already intersected with the fill master (and mirrored), so
    // each one lies ON TOP of the flat region -- exactly the overlap the
    // disjointness pass exists to resolve.
    if (layer.color.alpha != 0 && _isNotEmpty(fillPath)) {
      final overpaints = layer.getStrokeAddBandOverpaints(fillPath);
      log('stroke bands: ${overpaints.length} colored ADD band(s)');
      for (var i = 0; i < overpaints.length; i++) {
        final (bandPath, bandColor) = overpaints[i];
        if (!_isNotEmpty(bandPath)) {
          log('  band $i: SKIPPED — empty after clipping');
          continue;
        }
        log('  band $i: region "stroke_band$i" — ${describePath(bandPath)}');
        regions.add(ObjMaterialRegion(
          label: 'stroke_band$i',
          path: bandPath,
          material: interner.flat(bandColor),
        ));
      }
    } else {
      log('stroke bands: SKIPPED — no flat fill master to clip against');
    }

    // ---- 1d. Gradient meshes -----------------------------------------------
    // LAST, because the renderer paints meshes last (after fills, stroke areas,
    // and colored bands) and the disjointness pass resolves overlaps in favor
    // of whatever was collected later. A mesh therefore sits on top of anything
    // it overlaps, exactly as on canvas.
    //
    // getLayerMeshClipPath does the real work: it walks EVERY other shape in
    // the layer and applies each subtract/intersect, so a circle cutting into
    // the mesh arrives here already carved.
    var meshIndex = 0;
    for (final shape in layer.shapes) {
      if (shape is! CompassMesh || !shape.isVisible) continue;
      final tag = 'mesh[${layer.shapes.indexOf(shape)}]';

      if (shape.rows < 2 || shape.cols < 2) {
        log('$tag: SKIPPED — degenerate grid (${shape.rows}x${shape.cols})');
        continue;
      }

      final clip = _withMirror(layer, layer.getLayerMeshClipPath(shape));
      if (!_isNotEmpty(clip)) {
        log('$tag: SKIPPED — mesh clip resolved EMPTY (fully carved away?)');
        continue;
      }

      final baked = await bakeMeshPatchPng(shape);
      if (baked == null) {
        log('$tag: SKIPPED — patch bake failed (degenerate bounds?)');
        warnings.add('A gradient mesh could not be baked and was skipped.');
        continue;
      }

      final (bytes, texBounds) = baked;
      final material = interner.mesh(shape, bytes);

      log('$tag: region "mesh$meshIndex" — ${shape.rows}x${shape.cols} grid, '
          'material ${material.name}, '
          'texture box (${texBounds.left.toStringAsFixed(1)}, '
          '${texBounds.top.toStringAsFixed(1)})-'
          '(${texBounds.right.toStringAsFixed(1)}, '
          '${texBounds.bottom.toStringAsFixed(1)}) — ${describePath(clip)}');

      regions.add(ObjMaterialRegion(
        label: 'mesh${meshIndex++}',
        path: clip,
        material: material,
        // Planar unwrap of the PADDED texture box. Pure function of world
        // position, like every other projector here, so welding stays safe.
        // V is inverted to match the Y-flip the exporter applies to geometry.
        uv: (world) => Offset(
          (world.dx - texBounds.left) / texBounds.width,
          1.0 - (world.dy - texBounds.top) / texBounds.height,
        ),
      ));
    }

    final collectedCount = regions.length;
    final disjoint = _makeDisjoint(regions);
    if (disjoint.length != collectedCount) {
      log('disjointness: $collectedCount region(s) collected, '
          '${disjoint.length} survived (the rest were fully covered by later paint)');
    }

    // Prune materials/sidecars that no region ended up using -- a band fully
    // covered by a later one, or a gradient whose clip vanished under the pass.
    final live = <ObjMaterial>{for (final r in disjoint) r.material};
    final materials =
        interner.materials.where(live.contains).toList(growable: false);
    final liveTextures = <String>{
      for (final m in materials)
        if (m.textureFileName != null) m.textureFileName!,
    };
    final sidecars = interner.sidecars
        .where((s) => liveTextures.contains(s.fileName))
        .toList(growable: false);

    log('RESULT: ${disjoint.length} region(s), ${materials.length} material(s), '
        '${sidecars.length} sidecar(s), ${warnings.length} warning(s)');
    if (disjoint.isEmpty) {
      log('RESULT IS EMPTY — the export will report "no painted area". '
          'Read the per-shape lines above to see which test rejected each shape.');
    }

    return ObjMaterialSet(
      regions: disjoint,
      materials: materials,
      sidecars: sidecars,
      warnings: warnings,
      diagnostics: diagnostics,
    );
  }

  /// Makes [regions] mutually exclusive, resolving overlaps in favor of the
  /// LATER-painted region.
  ///
  /// Walks backward accumulating a `covered` path: each region is trimmed by
  /// everything painted above it, then folded into the accumulator. That
  /// reproduces painter's-algorithm semantics as pure geometry, which is what
  /// OBJ needs -- coplanar overlapping faces have no defined draw order in a 3-D
  /// renderer, so a colored band left sitting on top of the flat fill would
  /// Z-fight rather than "win".
  ///
  /// Most regions are already disjoint (the layer getters do the real work);
  /// this is cheap insurance for the cases they don't cover, notably the
  /// colored bands. Cost is O(n) Path.combine calls on a one-shot export.
  static List<ObjMaterialRegion> _makeDisjoint(
    List<ObjMaterialRegion> regions,
  ) {
    final out = <ObjMaterialRegion>[];
    var covered = Path()..fillType = PathFillType.evenOdd;

    for (var i = regions.length - 1; i >= 0; i--) {
      final region = regions[i];
      var path = region.path;

      if (_isNotEmpty(covered) &&
          path.getBounds().overlaps(covered.getBounds())) {
        path = Path.combine(PathOperation.difference, path, covered)
          ..fillType = PathFillType.evenOdd;
      }

      if (!_isNotEmpty(path)) continue;

      out.add(ObjMaterialRegion(
        label: region.label,
        path: path,
        material: region.material,
        uv: region.uv,
      ));

      covered = _isNotEmpty(covered)
          ? (Path.combine(PathOperation.union, covered, region.path)
            ..fillType = PathFillType.evenOdd)
          : (Path.from(region.path)..fillType = PathFillType.evenOdd);
    }

    return out.reversed.toList(growable: false);
  }

  /// Unions a self-painted clip with its reflection when the layer mirrors.
  ///
  /// Only the GEOMETRY is reflected -- never the projector -- which is the same
  /// split the renderer and the SVG exporter make. A world-space ramp sampled
  /// at a reflected vertex continues in the original direction, so the color
  /// flows across the seam instead of folding at it.
  static Path _withMirror(CompassLayer layer, Path clip) {
    if (!layer.mirrorEnabled || !_isNotEmpty(clip)) return clip;
    final reflected = clip.transform(layer.mirrorMatrix.storage);
    return Path.combine(PathOperation.union, clip, reflected)
      ..fillType = PathFillType.evenOdd;
  }

  /// Renders a gradient's resolved stops to a [rampWidth] x [rampHeight] PNG.
  ///
  /// TEXEL ALIGNMENT: the shader runs from x = 0.5 to x = rampWidth - 0.5, so
  /// texel 0's CENTRE carries t = 0 and texel 255's centre carries t = 1. This
  /// is the exact counterpart of [rampU], which places every emitted UV on a
  /// texel centre -- the two must be changed together or every ramp shifts by
  /// half a texel.
  ///
  /// Positions come from resolvedStops(), the SAME resolver buildShader() and
  /// the SVG exporter use, so the baked ramp cannot drift from the canvas.
  static Future<Uint8List?> bakeRampPng(LinearGradientFill gradient) async {
    final resolved = gradient.resolvedStops();
    if (resolved.length < 2) return null;

    final colors = <Color>[for (final stop in resolved) stop.$2];
    final positions = <double>[for (final stop in resolved) stop.$1];

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final shader = ui.Gradient.linear(
      const Offset(0.5, 0.0),
      Offset(rampWidth - 0.5, 0.0),
      colors,
      positions,
    );

    canvas.drawRect(
      Rect.fromLTWH(0, 0, rampWidth.toDouble(), rampHeight.toDouble()),
      Paint()
        ..shader = shader
        ..isAntiAlias = false,
    );

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(rampWidth, rampHeight);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  /// Bakes a gradient mesh's Coons color field to a PNG, returning the bytes
  /// and the world-space box that texture covers.
  ///
  /// The caller unwraps that box planarly, so the returned Rect IS the UV
  /// frame: `u = (x - left) / width`, `v = 1 - (y - top) / height`.
  ///
  /// TWO TEXELS OF PADDING around the mesh's own bounds, which is what keeps
  /// the result correct under any sampler. Without it the mesh's extreme
  /// vertices land on u = 0 and u = 1 exactly -- the wrap seam -- and bilinear
  /// filtering under a Repeat extension blends the left edge of the patch into
  /// its right edge. It is the same failure [rampU] exists to prevent, in two
  /// dimensions; here the fix is a border rather than an inset because the
  /// texture is a real 2-D image and can simply be made slightly larger than
  /// the thing it depicts.
  ///
  /// The border (and the whole canvas beneath the field) is filled with the
  /// mesh's AVERAGE color first. Two reasons: a transparent border would bleed
  /// toward black at the silhouette under filtering, and an opaque background
  /// makes the PNG uniformly opaque so no `map_d` is needed -- at the cost of
  /// flattening any per-node alpha, which is the documented tradeoff in
  /// [_MaterialInterner.mesh].
  ///
  /// Rendering is `drawVertices(BlendMode.modulate, white)` -- byte-for-byte
  /// what CompassRenderer does for the live canvas, so the baked patch cannot
  /// drift from what the artist sees.
  static Future<(Uint8List, Rect)?> bakeMeshPatchPng(CompassMesh mesh) async {
    final raw = mesh.getBounds();
    if (raw.width <= 1e-6 || raw.height <= 1e-6) return null;

    final longest = raw.width >= raw.height ? raw.width : raw.height;
    final scale = meshTextureMaxDim / longest; // texels per world unit
    if (!scale.isFinite || scale <= 0) return null;

    final bounds = raw.inflate(_meshTexturePadTexels / scale);

    var texW = (bounds.width * scale).ceil();
    var texH = (bounds.height * scale).ceil();
    if (texW < 8) texW = 8;
    if (texH < 8) texH = 8;
    if (texW > 4096) texW = 4096;
    if (texH > 4096) texH = 4096;

    // Average color for the background/border.
    var rSum = 0, gSum = 0, bSum = 0;
    for (final color in mesh.colors) {
      rSum += color.red;
      gSum += color.green;
      bSum += color.blue;
    }
    final n = mesh.colors.isEmpty ? 1 : mesh.colors.length;
    final average = Color.fromARGB(
      255,
      (rSum / n).round().clamp(0, 255),
      (gSum / n).round().clamp(0, 255),
      (bSum / n).round().clamp(0, 255),
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, texW.toDouble(), texH.toDouble()),
      Paint()..color = average,
    );

    // World -> texel. Non-uniform on purpose: the padded box and the texture
    // can disagree by up to one texel after the ceil() above, and stretching to
    // fit keeps the UV mapping exact rather than off by a fraction of a texel.
    canvas.scale(texW / bounds.width, texH / bounds.height);
    canvas.translate(-bounds.left, -bounds.top);

    canvas.drawVertices(
      mesh.buildVertices(),
      BlendMode.modulate,
      Paint()
        ..isAntiAlias = true
        ..color = const Color(0xFFFFFFFF),
    );

    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(texW, texH);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        return (data.buffer.asUint8List(), bounds);
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  // Local emptiness test. layer.dart's extension is private to that file, and
  // the bounds check short-circuits the metrics walk for the common case.
  static bool _isNotEmpty(Path path) {
    if (path.getBounds() != Rect.zero) return true;
    return path.computeMetrics().isNotEmpty;
  }
}