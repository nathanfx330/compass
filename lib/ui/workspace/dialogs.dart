// /lib/ui/workspace/dialogs.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import '../../engine.dart';
import '../../models/layer.dart';
import '../../models/geometry/spline.dart';
import '../../models/geometry/image.dart';
import '../../models/geometry/mesh.dart';
import '../../io/png_exporter.dart'; // <--- NEW: Import for PngExportStyle

// The OBJ exporter's four output modes as the dialog presents them. Local to
// this file: the engine/exporter API stays booleans (gridMode, delaunayMode,
// skeletonMode) for backward compatibility, and _ObjExportMode maps onto them
// at save time.
enum _ObjExportMode { scanline, grid, delaunay, skeleton }

// The OBJ dialog's "material" dropdown is an int channel with two sentinels;
// any NON-NEGATIVE value indexes into the layer's visible-Add IMG list.
//
// A plain enum would be tidier, but the third case genuinely carries a payload
// (which IMG), and DropdownButtonFormField wants one value type. Two named
// constants beat either a record or a parallel index variable that can silently
// disagree with the enum.
const int _objMaterialGeometryOnly = -1;
const int _objMaterialLayerAppearance = -2;

class CompassDialogs {
  static void showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('About Compass'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Compass 0.4',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              SizedBox(height: 12),
              Text('Created by Nathaniel Westveer'),
              SizedBox(height: 8),
              Text(
                'Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  static void showExportSVG(BuildContext context, CompassEngine engine) {
    final svgData = engine.toSVG();
    final TextEditingController filenameController = TextEditingController(text: 'compass_export.svg');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Export as SVG'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter a filename to save your vector graphic:'),
              const SizedBox(height: 12),
              TextField(
                controller: filenameController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Filename',
                  suffixText: '.svg',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Save File'),
              onPressed: () async {
                String filename = filenameController.text;
                if (!filename.endsWith('.svg')) {
                  filename += '.svg';
                }
                try {
                  final file = File(filename);
                  await file.writeAsString(svgData);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Successfully saved to $filename!')),
                    );
                    Navigator.of(context).pop();
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error saving file: $e')),
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  static void showExportPNG(BuildContext context, CompassEngine engine) {
    final TextEditingController filenameController = TextEditingController(text: 'compass_export.png');
    final TextEditingController customScaleController = TextEditingController(text: '0.25');
    
    // Default States
    double exportScaleSelection = 2.0; // 0.0 acts as our "Custom" sentinel
    PngExportStyle exportStyle = PngExportStyle.standard;
    bool isGrayscale = false;
    double bubbleSize = 10.0;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: const Text('Export as PNG'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Save your image with advanced raster effects.'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: filenameController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Filename',
                        suffixText: '.png',
                      ),
                    ),
                    const SizedBox(height: 20),

                    // --- Resolution ---
                    const Text('Resolution Scale', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    SegmentedButton<double>(
                      segments: const [
                        ButtonSegment(value: 0.5, label: Text('0.5x')),
                        ButtonSegment(value: 1.0, label: Text('1x')),
                        ButtonSegment(value: 2.0, label: Text('2x')),
                        ButtonSegment(value: 4.0, label: Text('4x')),
                        ButtonSegment(value: 0.0, label: Text('Custom')),
                      ],
                      selected: {exportScaleSelection},
                      onSelectionChanged: (newSelection) {
                        setLocalState(() => exportScaleSelection = newSelection.first);
                      },
                    ),
                    if (exportScaleSelection == 0.0) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: customScaleController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Custom Scale',
                          suffixText: 'x',
                          isDense: true,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),

                    // --- Color Mode ---
                    const Text('Color Mode', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('Full Color')),
                        ButtonSegment(value: true, label: Text('Grayscale')),
                      ],
                      selected: {isGrayscale},
                      onSelectionChanged: (newSelection) {
                        setLocalState(() => isGrayscale = newSelection.first);
                      },
                    ),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),

                    // --- Render Style ---
                    const Text('Render Style', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    SegmentedButton<PngExportStyle>(
                      segments: const [
                        ButtonSegment(value: PngExportStyle.standard, label: Text('Standard')),
                        ButtonSegment(value: PngExportStyle.dithered, label: Text('Dithered')),
                        ButtonSegment(value: PngExportStyle.bubbleJet, label: Text('Bubble Jet')),
                      ],
                      selected: {exportStyle},
                      onSelectionChanged: (newSelection) {
                        setLocalState(() => exportStyle = newSelection.first);
                      },
                    ),
                    const SizedBox(height: 8),

                    // --- Hints / Contextual sliders ---
                    if (exportStyle == PngExportStyle.standard) ...[
                      Text('Clean vector rasterization.', style: Theme.of(context).textTheme.bodySmall),
                    ] else if (exportStyle == PngExportStyle.dithered) ...[
                      Text('Applies Floyd-Steinberg error diffusion for a crunchier retro/print look.', style: Theme.of(context).textTheme.bodySmall),
                    ] else if (exportStyle == PngExportStyle.bubbleJet) ...[
                      Row(
                        children: [
                          const Text('Bubble / Halftone Size:'),
                          const Spacer(),
                          Text(bubbleSize.round().toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Slider(
                        value: bubbleSize,
                        min: 4,
                        max: 32,
                        divisions: 28,
                        onChanged: (v) => setLocalState(() => bubbleSize = v),
                      ),
                      Text('Converts shading into scaled ink dots (Pointillism style).', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.save),
                  label: const Text('Save File'),
                  onPressed: () async {
                    String filename = filenameController.text;
                    if (!filename.endsWith('.png')) {
                      filename += '.png';
                    }

                    // Resolve final scale to use
                    double finalScale = exportScaleSelection;
                    if (finalScale == 0.0) {
                      finalScale = double.tryParse(customScaleController.text) ?? 1.0;
                      if (finalScale <= 0) finalScale = 1.0; // Fallback for invalid input
                    }

                    try {
                      // Trigger the engine compiler with the new parameters
                      final Uint8List? bytes = await engine.toPNG(
                        scale: finalScale,
                        style: exportStyle,
                        grayscale: isGrayscale,
                        bubbleSize: bubbleSize,
                      );
                      
                      if (bytes == null) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Nothing to export — the canvas is empty.')),
                          );
                        }
                        return;
                      }

                      final file = File(filename);
                      await file.writeAsBytes(bytes);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Successfully saved to $filename!')),
                        );
                        Navigator.of(context).pop();
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error saving file: $e')),
                        );
                      }
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Appends one timestamped block to `compass_export_log.txt` and returns its
  /// absolute path, or null if the write failed.
  ///
  /// APPEND, not truncate: the reason this exists is comparing one export
  /// attempt against the next, which a file that resets every run makes
  /// impossible. Plain text, a few hundred bytes per export.
  ///
  /// WHERE "./" LANDS: [Directory.current] -- wherever the process was launched
  /// from, so the project root under `flutter run` and the bundle directory if
  /// started from a file manager. That is the same convention ThemeManager
  /// already uses for compass_settings.json, so the two files turn up together
  /// instead of following two different rules.
  ///
  /// NEVER THROWS. A diagnostics log that can break an otherwise successful
  /// export would be worse than no log at all, so every failure is swallowed
  /// and surfaces as a null return, which callers render as "log unavailable".
  static Future<String?> _writeObjExportLog(List<String> lines) async {
    try {
      final file = File('compass_export_log.txt').absolute;
      final buffer = StringBuffer();
      buffer.writeln('=== ${DateTime.now().toIso8601String()} '
          '=========================');
      for (final line in lines) {
        buffer.writeln(line);
      }
      buffer.writeln();

      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
      return file.path;
    } catch (_) {
      return null;
    }
  }

  // Layer-to-object export. Scoped to ONE layer (the "what a shot turns into"
  // unit), unlike the whole-document SVG/PNG exporters. Mirrors showExportPNG's
  // structure -- StatefulBuilder + filename + controls -- with these specifics:
  //
  //   1. "Curve Resolution" is SAMPLING SPACING (logical px between polyline
  //      samples along each contour), sense INVERTED from PNG's scale: a SMALLER
  //      number = DENSER polygon = smoother result. So "Fine" is the small value.
  //      It matters in ALL modes -- scanline: band density; grid: how finely the
  //      boundary is sampled for cell clipping; delaunay: the boundary vertex
  //      density of the triangulation itself; skeleton: the boundary-sample
  //      density the medial-axis test runs against.
  //   2. "Mode" is a four-way SegmentedButton:
  //        Scanline -- robust curve-following bands (the proven default);
  //        Grid     -- uniform quad mesh, workable topology, blocky silhouette,
  //                    with a cells-across slider;
  //        Organic  -- Delaunay triangulation (the same math as the in-app
  //                    "Bake to Triangulated Spline"), roughly-equilateral tris
  //                    hugging the exact silhouette, with a Triangle Size slider
  //                    (interior point spacing in logical px);
  //        Skeleton -- the region's MEDIAL AXIS as loose OBJ `l` edges (for
  //                    Blender's Skin modifier / rigging workflows), sharing the
  //                    cells-across slider (sweep resolution) plus a Branch
  //                    Pruning (lambda) slider. Lambda's slider FLOOR is tied to
  //                    the sampling spacing (see the kernel's caveat: lambda must
  //                    stay well above the boundary sample gap or every wall cell
  //                    self-qualifies against its own neighbors) -- switching
  //                    Curve Resolution re-clamps the current lambda if needed.
  //      The dialog enum maps onto the engine's booleans at save time, so the
  //      exporter API stays backward compatible.
  //   3. toOBJ returns an EMPTY STRING when the layer has no fillable area -- or,
  //      in skeleton mode, when pruning leaves nothing -- treated like the PNG
  //      exporter's null: a snackbar instead of a junk file. The skeleton-mode
  //      empty message hints at lowering lambda, since over-pruning is the usual
  //      cause there rather than a truly empty layer.
  static void showExportOBJ(BuildContext context, CompassEngine engine, CompassLayer layer) {
    // Seed the filename from the layer name so the default is meaningful.
    final safeName = layer.name.replaceAll(RegExp(r'\s+'), '_').replaceAll(RegExp(r'[^A-Za-z0-9_\-.]'), '');
    final TextEditingController filenameController =
        TextEditingController(text: '${safeName.isEmpty ? 'layer' : safeName}.obj');

    final textureImages = layer.shapes
        .whereType<CompassImage>()
        .where((image) =>
            image.isVisible && CompassLayer.hasLiftedImageFill(image))
        .toList();

    // DEFAULTS ARE DELIBERATELY UNCHANGED from the IMG-only era: geometry-only,
    // or the single IMG when the layer has one and is not mirrored. "Layer
    // appearance" is strictly more complete (it covers the IMG too, alongside
    // every fill, gradient, and stroke band), but defaulting to it would
    // silently start emitting MTL + sidecar files for anyone who has been
    // exporting bare geometry. Opt-in via the dropdown; flip this line if the
    // richer default is wanted later.
    int materialChoice = textureImages.isNotEmpty && !layer.mirrorEnabled
        ? 0
        : _objMaterialGeometryOnly;

    String basename(String path) =>
        path.replaceAll('\\', '/').split('/').last;

    String withoutExtension(String name) {
      final dot = name.lastIndexOf('.');
      return dot <= 0 ? name : name.substring(0, dot);
    }

    String extensionOf(String name) {
      final dot = name.lastIndexOf('.');
      return dot <= 0 ? '' : name.substring(dot).toLowerCase();
    }

    String safeSidecarStem(String raw) {
      final cleaned = raw
          .replaceAll(RegExp(r'\s+'), '_')
          .replaceAll(RegExp(r'[^A-Za-z0-9_\-.]'), '');
      return cleaned.isEmpty ? 'compass_texture' : cleaned;
    }

    // Sampling spacing in logical px. Smaller = denser polygon = smoother.
    double samplingSpacing = 2.0;
    // Output mode + shared density. gridCount = cells across the longest bbox
    // side (grid: quad density; skeleton: sweep resolution).
    _ObjExportMode mode = _ObjExportMode.scanline;
    double gridCount = 48;
    // Delaunay interior point spacing (~ triangle edge length), logical px.
    double delaunaySpacing = 25.0;
    // Skeleton branch pruning (lambda), logical px. Re-clamped against the floor
    // whenever samplingSpacing changes.
    double skeletonLambda = 20.0;

    // Lambda floor: 5x the boundary sample gap, never under 5 px. Below this the
    // medial test degenerates (adjacent samples on ONE wall read as "two walls").
    double lambdaFloor() {
      final f = samplingSpacing * 5.0;
      return f < 5.0 ? 5.0 : f;
    }

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final double lamMin = lambdaFloor();
            const double lamMax = 200.0;
            final double lamValue = skeletonLambda.clamp(lamMin, lamMax);

            final selectedTextureImage =
                materialChoice >= 0 &&
                        materialChoice < textureImages.length
                    ? textureImages[materialChoice]
                    : null;

            final isLayerAppearance =
                materialChoice == _objMaterialLayerAppearance;

            String headerText;
            if (selectedTextureImage != null) {
              headerText = 'Exports the selected IMG Boolean mask as a textured '
                  'triangle mesh. The mesh itself hides every pixel outside the '
                  'mask; Compass writes OBJ + MTL + a copy of the source image.';
            } else if (isLayerAppearance) {
              headerText = 'Exports this layer\'s whole appearance as disjoint '
                  'material regions — flat fill, gradients, stroke area, colored '
                  'bands, and IMG masks. Compass writes OBJ + MTL plus a small '
                  'texture beside them for each gradient and image.';
            } else {
              switch (mode) {
              case _ObjExportMode.skeleton:
                headerText = 'Exports this layer\'s medial-axis skeleton as loose '
                    'edge geometry on the Z=0 plane (for Skin modifier / '
                    'rigging workflows).';
                break;
              case _ObjExportMode.delaunay:
                headerText = 'Exports this layer\'s resolved boolean fill as '
                    'organic, roughly-uniform triangles on the Z=0 plane '
                    '(holes preserved) — the same triangulation as the '
                    'in-app Triangulated Spline bake.';
                break;
              default:
                headerText = 'Exports this layer\'s resolved boolean fill as a flat '
                    'triangle mesh on the Z=0 plane (holes preserved).';
              }
            }

            return AlertDialog(
              title: Text('Export "${layer.name}" as OBJ'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(headerText),
                    const SizedBox(height: 12),
                    TextField(
                      controller: filenameController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Filename',
                        suffixText: '.obj',
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      value: materialChoice,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'OBJ material',
                      ),
                      items: [
                        const DropdownMenuItem<int>(
                          value: _objMaterialGeometryOnly,
                          child: Text('Geometry only'),
                        ),
                        const DropdownMenuItem<int>(
                          value: _objMaterialLayerAppearance,
                          child: Text('Layer appearance (fill, gradients, strokes)'),
                        ),
                        // IMG items are OMITTED rather than disabled under the
                        // Mirror Modifier: one affine frame cannot invert across
                        // a reflection, so there is no valid IMG-only export to
                        // offer. Layer appearance stays available and simply
                        // skips IMG regions with a warning.
                        if (!layer.mirrorEnabled)
                          for (var i = 0; i < textureImages.length; i++)
                            DropdownMenuItem<int>(
                              value: i,
                              child: Text(
                                'IMG texture — ${textureImages[i].displayName}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                      ],
                      onChanged: mode == _ObjExportMode.skeleton
                          ? null
                          : (value) {
                              setLocalState(() {
                                materialChoice =
                                    value ?? _objMaterialGeometryOnly;
                              });
                            },
                    ),
                    if (mode == _ObjExportMode.skeleton) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Skeleton mode exports loose edges, which carry no faces '
                        'and therefore no materials.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ] else if (layer.mirrorEnabled) ...[
                      const SizedBox(height: 6),
                      Text(
                        'IMG texture export is unavailable while the Mirror '
                        'Modifier is enabled. Layer appearance still exports flat '
                        'and gradient regions correctly across the seam; any IMG '
                        'regions are skipped.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ] else if (textureImages.isEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'No visible Add IMG object exists on this layer, so only '
                        'geometry and layer appearance are available.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Text('Curve Resolution'),
                    const SizedBox(height: 8),
                    SegmentedButton<double>(
                      segments: const [
                        ButtonSegment(value: 1.0, label: Text('Fine')),
                        ButtonSegment(value: 2.0, label: Text('Medium')),
                        ButtonSegment(value: 4.0, label: Text('Coarse')),
                      ],
                      selected: {samplingSpacing},
                      onSelectionChanged: (newSelection) {
                        setLocalState(() {
                          samplingSpacing = newSelection.first;
                          // Keep lambda legal against the new floor.
                          final f = lambdaFloor();
                          if (skeletonLambda < f) skeletonLambda = f;
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    const Divider(height: 1),
                    const SizedBox(height: 12),

                    // --- Output mode (four-way) ---
                    const Text('Mode'),
                    const SizedBox(height: 8),
                    SegmentedButton<_ObjExportMode>(
                      segments: const [
                        ButtonSegment(
                          value: _ObjExportMode.scanline,
                          label: Text('Scanline'),
                        ),
                        ButtonSegment(
                          value: _ObjExportMode.grid,
                          label: Text('Grid'),
                        ),
                        ButtonSegment(
                          value: _ObjExportMode.delaunay,
                          label: Text('Organic'),
                        ),
                        ButtonSegment(
                          value: _ObjExportMode.skeleton,
                          label: Text('Skeleton'),
                        ),
                      ],
                      selected: {mode},
                      onSelectionChanged: (newSelection) {
                        setLocalState(() {
                          mode = newSelection.first;
                          // Skeleton emits `l` edges: no faces, so no materials.
                          // Snap the dropdown back rather than disabling the
                          // mode -- matching how the IMG selection has always
                          // behaved here, and keeping Skeleton reachable.
                          if (mode == _ObjExportMode.skeleton) {
                            materialChoice = _objMaterialGeometryOnly;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 12),

                    // --- Per-mode controls + hints ---
                    if (mode == _ObjExportMode.scanline) ...[
                      Text(
                        'Robust curve-following bands. Finer resolution = smoother '
                        'curves, more triangles.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ] else if (mode == _ObjExportMode.delaunay) ...[
                      Row(
                        children: [
                          const Text('Triangle size'),
                          const Spacer(),
                          Text(
                            delaunaySpacing.toStringAsFixed(0),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Slider(
                        value: delaunaySpacing,
                        min: 5,
                        max: 100,
                        divisions: 19, // steps of 5
                        label: delaunaySpacing.toStringAsFixed(0),
                        onChanged: (v) {
                          setLocalState(() {
                            delaunaySpacing = v;
                          });
                        },
                      ),
                      Text(
                        'Organic, roughly-equilateral triangles; the silhouette is '
                        'exact (boundary samples are mesh vertices). Smaller size = '
                        'denser, finer mesh.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ] else ...[
                      // Grid and Skeleton share the cells-across slider; only the
                      // label wording differs.
                      Row(
                        children: [
                          Text(mode == _ObjExportMode.grid
                              ? 'Cells across'
                              : 'Skeleton resolution'),
                          const Spacer(),
                          Text(
                            '${gridCount.round()}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      Slider(
                        value: gridCount,
                        min: 16,
                        max: 96,
                        divisions: 10, // steps of 8
                        label: '${gridCount.round()}',
                        onChanged: (v) {
                          setLocalState(() {
                            gridCount = v;
                          });
                        },
                      ),
                      if (mode == _ObjExportMode.grid) ...[
                        Text(
                          'Uniform quad mesh: workable topology, edges step at the '
                          'cell size. More cells = smoother silhouette, more quads.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ] else ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Text('Branch pruning (λ)'),
                            const Spacer(),
                            Text(
                              lamValue.toStringAsFixed(0),
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Slider(
                          value: lamValue,
                          min: lamMin,
                          max: lamMax,
                          label: lamValue.toStringAsFixed(0),
                          onChanged: (v) {
                            setLocalState(() {
                              skeletonLambda = v;
                            });
                          },
                        ),
                        Text(
                          'Higher pruning keeps only the primary frame; lower keeps '
                          'finer branches. Higher resolution = smoother skeleton, '
                          'more edges.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.save),
                  label: const Text('Save File'),
                  onPressed: () async {
                    String filename = filenameController.text;
                    if (!filename.endsWith('.obj')) {
                      filename += '.obj';
                    }

                    // Preamble written for EVERY outcome, so a log block always
                    // records what was attempted even when the attempt threw
                    // before producing anything.
                    final logLines = <String>[
                      'layer: ${layer.name}',
                      'target: $filename',
                      'mode: ${mode.name}',
                      'curve resolution: $samplingSpacing px',
                      if (mode == _ObjExportMode.grid ||
                          mode == _ObjExportMode.skeleton)
                        'cells across: ${gridCount.round()}',
                      if (mode == _ObjExportMode.delaunay)
                        'delaunay spacing: $delaunaySpacing px',
                      if (mode == _ObjExportMode.skeleton)
                        'skeleton lambda: ${lamValue.toStringAsFixed(1)}',
                      'material: ${materialChoice == _objMaterialGeometryOnly ? 'geometry only' : materialChoice == _objMaterialLayerAppearance ? 'layer appearance' : 'IMG texture'}',
                      'shapes in layer: ${layer.shapes.length}',
                      'mirror: ${layer.mirrorEnabled ? layer.mirrorAxis.name : 'off'}',
                      '',
                    ];

                    try {
                      final objFile = File(filename).absolute;
                      await objFile.parent.create(recursive: true);

                      final separator = Platform.pathSeparator;
                      final outputDir = objFile.parent.path;
                      final outputStem = safeSidecarStem(
                        withoutExtension(basename(objFile.path)),
                      );

                      final selectedTexture =
                          materialChoice >= 0 &&
                                  materialChoice < textureImages.length
                              ? textureImages[materialChoice]
                              : null;

                      // ---- LAYER APPEARANCE: multi-material export ----------
                      // Checked before the geometry-only branch because its
                      // sentinel is also "no selected IMG"; the difference is
                      // that here every painted region becomes its own material.
                      if (materialChoice == _objMaterialLayerAppearance) {
                        final mtlFileName = '$outputStem.mtl';

                        final export = await engine.toMaterialOBJ(
                          layer,
                          fileStem: outputStem,
                          materialLibraryFileName: mtlFileName,
                          samplingSpacing: samplingSpacing,
                          gridMode: mode == _ObjExportMode.grid,
                          gridCount: gridCount.round(),
                          delaunayMode: mode == _ObjExportMode.delaunay,
                          delaunaySpacing: delaunaySpacing,
                        );

                        if (export.isEmpty) {
                          logLines.addAll(export.diagnostics);
                          logLines.add('');
                          logLines.add('OUTCOME: FAILED — ${export.error}');
                          final logPath = await _writeObjExportLog(logLines);

                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '${export.error ?? 'Nothing to export — this layer has no painted area.'}'
                                  '\n${logPath == null ? 'Log unavailable.' : 'Details: $logPath'}',
                                ),
                              ),
                            );
                          }
                          return;
                        }

                        // Sidecars first: an OBJ that references a missing map
                        // is worse than no OBJ at all, so if a texture copy
                        // throws we bail before writing the .obj/.mtl pair.
                        for (final sidecar in export.sidecars) {
                          final target =
                              File('$outputDir$separator${sidecar.fileName}');

                          if (sidecar.isCopy) {
                            final source = File(sidecar.sourcePath!);
                            if (!await source.exists()) {
                              throw FileSystemException(
                                'IMG source file is missing',
                                sidecar.sourcePath!,
                              );
                            }
                            if (source.absolute.path != target.absolute.path) {
                              await source.copy(target.path);
                            }
                          } else {
                            await target.writeAsBytes(sidecar.bytes!);
                          }
                        }

                        await File('$outputDir$separator$mtlFileName')
                            .writeAsString(export.mtlData);
                        await objFile.writeAsString(export.objData);

                        logLines.addAll(export.diagnostics);
                        logLines.add('');
                        for (final warning in export.warnings) {
                          logLines.add('WARNING: $warning');
                        }
                        logLines.add('OUTCOME: OK — wrote ${objFile.path}, '
                            '$mtlFileName, and ${export.sidecars.length} sidecar(s)');
                        final logPath = await _writeObjExportLog(logLines);

                        if (context.mounted) {
                          final sidecarCount = export.sidecars.length;
                          final buffer = StringBuffer(
                            'Saved OBJ, MTL, and $sidecarCount texture '
                            'file${sidecarCount == 1 ? '' : 's'} to $outputDir',
                          );
                          // WARNINGS ARE NOT FAILURES: a mirrored layer still
                          // exported its flat and gradient geometry correctly.
                          // Report them alongside the success, never instead.
                          for (final warning in export.warnings) {
                            buffer.write('\n$warning');
                          }
                          if (logPath != null) {
                            buffer.write('\nLog: $logPath');
                          }

                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(buffer.toString())),
                          );
                          Navigator.of(context).pop();
                        }
                        return;
                      }

                      if (selectedTexture == null) {
                        final objData = engine.toOBJ(
                          layer,
                          samplingSpacing: samplingSpacing,
                          gridMode: mode == _ObjExportMode.grid,
                          gridCount: gridCount.round(),
                          delaunayMode: mode == _ObjExportMode.delaunay,
                          delaunaySpacing: delaunaySpacing,
                          skeletonMode: mode == _ObjExportMode.skeleton,
                          skeletonLambda: lamValue,
                        );
                        if (objData.isEmpty) {
                          final reason = mode == _ObjExportMode.skeleton
                              ? 'Nothing to export — no skeleton survived. Try lowering branch pruning or check the layer has filled area.'
                              : 'Nothing to export — this layer has no filled area.';

                          // toOBJ has no diagnostics channel of its own, so
                          // reconstruct the two facts that actually decide the
                          // outcome. A mesh-only layer reads as "0 non-mesh
                          // shapes", which is the answer in one line.
                          final meshCount = layer.shapes
                              .where((s) => s is CompassMesh && s.isVisible)
                              .length;
                          logLines.add(
                            'toOBJ() returned empty. visible shapes: '
                            '${layer.shapes.where((s) => s.isVisible).length}, '
                            'of which gradient meshes (never exportable): $meshCount',
                          );
                          logLines.add('OUTCOME: FAILED — $reason');
                          final logPath = await _writeObjExportLog(logLines);

                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '$reason'
                                  '\n${logPath == null ? 'Log unavailable.' : 'Details: $logPath'}',
                                ),
                              ),
                            );
                          }
                          return;
                        }

                        await objFile.writeAsString(objData);
                        logLines.add(
                          'OUTCOME: OK — wrote ${objData.length} bytes to ${objFile.path}',
                        );
                        final logPath = await _writeObjExportLog(logLines);

                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                'Successfully saved to ${objFile.path}!'
                                '${logPath == null ? '' : '\nLog: $logPath'}',
                              ),
                            ),
                          );
                          Navigator.of(context).pop();
                        }
                        return;
                      }

                      final sourceTexture = File(selectedTexture.imagePath);
                      if (!await sourceTexture.exists()) {
                        throw FileSystemException(
                          'IMG source file is missing',
                          selectedTexture.imagePath,
                        );
                      }

                      final sourceExtension =
                          extensionOf(basename(sourceTexture.path));
                      final textureExtension =
                          sourceExtension == '.jpg' ||
                                  sourceExtension == '.jpeg' ||
                                  sourceExtension == '.png'
                              ? sourceExtension
                              : '.png';
                      final mtlFileName = '$outputStem.mtl';
                      final textureFileName =
                          '${outputStem}_texture$textureExtension';

                      final export = engine.toTexturedOBJ(
                        layer,
                        selectedTexture,
                        materialLibraryFileName: mtlFileName,
                        textureFileName: textureFileName,
                        samplingSpacing: samplingSpacing,
                        gridMode: mode == _ObjExportMode.grid,
                        gridCount: gridCount.round(),
                        delaunayMode: mode == _ObjExportMode.delaunay,
                        delaunaySpacing: delaunaySpacing,
                        skeletonMode: mode == _ObjExportMode.skeleton,
                      );

                      if (export.isEmpty) {
                        logLines.add('IMG: ${selectedTexture.displayName}');
                        logLines.add('OUTCOME: FAILED — ${export.error}');
                        final logPath = await _writeObjExportLog(logLines);

                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '${export.error ?? 'Nothing to export from the selected IMG mask.'}'
                                '\n${logPath == null ? 'Log unavailable.' : 'Details: $logPath'}',
                              ),
                            ),
                          );
                        }
                        return;
                      }

                      final mtlFile = File(
                        '$outputDir$separator${export.materialLibraryFileName}',
                      );
                      final textureFile = File(
                        '$outputDir$separator${export.textureFileName}',
                      );

                      if (sourceTexture.absolute.path !=
                          textureFile.absolute.path) {
                        await sourceTexture.copy(textureFile.path);
                      }
                      await mtlFile.writeAsString(export.mtlData);
                      await objFile.writeAsString(export.objData);

                      logLines.add('IMG: ${selectedTexture.displayName}');
                      logLines.add(
                        'OUTCOME: OK — wrote ${objFile.path}, '
                        '${export.materialLibraryFileName}, '
                        '${export.textureFileName}',
                      );
                      final logPath = await _writeObjExportLog(logLines);

                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Saved textured OBJ, MTL, and image to $outputDir'
                              '${logPath == null ? '' : '\nLog: $logPath'}',
                            ),
                          ),
                        );
                        Navigator.of(context).pop();
                      }
                    } catch (e, stack) {
                      // The throw sites are all file I/O (missing IMG source,
                      // permission, disk). Log the stack too -- an exception is
                      // the one outcome where the preamble alone says nothing.
                      logLines.add('OUTCOME: THREW — $e');
                      logLines.add(stack.toString());
                      final logPath = await _writeObjExportLog(logLines);

                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Error saving file: $e'
                              '${logPath == null ? '' : '\nDetails: $logPath'}',
                            ),
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- ASCII Exporter Dialog ---
  static void showExportASCII(BuildContext context, CompassEngine engine) {
    final TextEditingController filenameController = TextEditingController(text: 'compass_art.txt');
    double columnWidth = 100.0;
    bool invertColors = false;
    bool useDither = false; // <--- NEW: Dither state

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: const Text('Export as ASCII Art'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Renders the geometry into text characters.'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: filenameController,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Filename',
                      suffixText: '.txt',
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Text('Resolution (Columns): '),
                      Text('${columnWidth.round()} chars', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Slider(
                    value: columnWidth,
                    min: 40,
                    max: 300,
                    divisions: 260,
                    onChanged: (val) => setLocalState(() => columnWidth = val),
                  ),
                  CheckboxListTile(
                    title: const Text('Invert Light/Dark'),
                    subtitle: const Text('Check this if you plan to view the text on a dark background.'),
                    value: invertColors,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (val) => setLocalState(() => invertColors = val ?? false),
                  ),
                  // <--- NEW: Dither Checkbox --->
                  CheckboxListTile(
                    title: const Text('Floyd-Steinberg Dithering'),
                    subtitle: const Text('Smooths gradients and shading using dot patterns.'),
                    value: useDither,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (val) => setLocalState(() => useDither = val ?? false),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton.icon(
                  icon: const Icon(Icons.text_snippet),
                  label: const Text('Save Text File'),
                  onPressed: () async {
                    String filename = filenameController.text;
                    if (!filename.endsWith('.txt')) filename += '.txt';
                    
                    try {
                      final String? asciiData = await engine.toASCII(
                        columns: columnWidth.round(),
                        invert: invertColors,
                        dither: useDither, // <--- NEW: Pass dither to engine
                      );
                      
                      if (asciiData == null || asciiData.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Nothing to export — the canvas is empty.')),
                          );
                        }
                        return;
                      }

                      final file = File(filename);
                      await file.writeAsString(asciiData);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('ASCII Art saved to $filename!')),
                        );
                        Navigator.of(context).pop();
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error saving file: $e')),
                        );
                      }
                    }
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  static void showSaveProject(BuildContext context, CompassEngine engine) {
    final projectData = engine.toProjectData();
    final TextEditingController filenameController = TextEditingController(text: 'my_design.compass');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Save Project'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter a filename to save your parametric math state:'),
              const SizedBox(height: 12),
              TextField(
                controller: filenameController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Filename',
                  suffixText: '.compass',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.save),
              label: const Text('Save Project'),
              onPressed: () async {
                String filename = filenameController.text;
                if (!filename.endsWith('.compass')) {
                  filename += '.compass';
                }
                try {
                  final file = File(filename);
                  await file.writeAsString(projectData);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Project saved to $filename!')),
                    );
                    Navigator.of(context).pop();
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error saving project: $e')),
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  static void showOpenProject(BuildContext context, CompassEngine engine) {
    final TextEditingController filepathController = TextEditingController(text: 'my_design.compass');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Open Project'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter the filename/path of the .compass file to load:'),
              const SizedBox(height: 12),
              TextField(
                controller: filepathController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'File Path',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Load Project'),
              onPressed: () async {
                try {
                  final file = File(filepathController.text);
                  final data = await file.readAsString();
                  engine.loadProjectData(data);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Project loaded from ${filepathController.text}!')),
                    );
                    Navigator.of(context).pop();
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error loading project: $e')),
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  static const XTypeGroup _rasterImageTypeGroup = XTypeGroup(
    label: 'Images',
    extensions: <String>['png', 'jpg', 'jpeg'],
  );

  static Future<XFile?> _pickRasterImage({
    required String confirmButtonText,
  }) {
    return openFile(
      acceptedTypeGroups: const <XTypeGroup>[_rasterImageTypeGroup],
      confirmButtonText: confirmButtonText,
    );
  }

  static Future<void> showImportImageLayer(
    BuildContext context,
    CompassEngine engine,
  ) async {
    try {
      final file = await _pickRasterImage(confirmButtonText: 'Import IMG');
      if (file == null) return;

      final image = await engine.importImageLayer(file.path);
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            image == null
                ? 'Could not import that PNG/JPG.'
                : 'Imported ${image.displayName} as an IMG layer.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the image picker: $e')),
      );
    }
  }

  static Future<void> showLoadReferenceImage(
    BuildContext context,
    CompassEngine engine,
  ) async {
    try {
      final file = await _pickRasterImage(
        confirmButtonText: 'Use as Reference',
      );
      if (file == null) return;

      final loaded = await engine.loadReferenceImage(file.path);
      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loaded
                ? 'Loaded ${file.name} as the reference image.'
                : 'Could not load that PNG/JPG.',
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the image picker: $e')),
      );
    }
  }

  static void showFilletDialog(BuildContext context, CompassEngine engine, CompassXSpline spline, CompassSplineNode node) {
    final TextEditingController radiusController = TextEditingController(text: '20.0');

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Fillet Corner'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter corner radius:'),
              const SizedBox(height: 12),
              TextField(
                controller: radiusController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Radius',
                  suffixText: 'px',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.rounded_corner),
              label: const Text('Apply Fillet'),
              onPressed: () {
                final radius = double.tryParse(radiusController.text);
                if (radius != null && radius > 0) {
                  engine.applyFilletToNode(spline, node, radius);
                  Navigator.of(context).pop();
                }
              },
            ),
          ],
        );
      },
    );
  }

  static void showStrokeProfileDialog(BuildContext context, CompassEngine engine, CompassXSpline spline) {
    // Determine initial values based on current nodes
    double initialStart = spline.nodes.isNotEmpty ? spline.nodes.first.widthLeft.value : 10.0;
    double initialEnd = spline.nodes.isNotEmpty ? spline.nodes.last.widthLeft.value : 10.0;

    final TextEditingController uniformController = TextEditingController(text: initialStart.toStringAsFixed(1));
    final TextEditingController startTaperController = TextEditingController(text: initialStart.toStringAsFixed(1));
    final TextEditingController endTaperController = TextEditingController(text: initialEnd.toStringAsFixed(1));

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: const Text('Area Stroke Profile'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- Show Vertex Numbers Toggle ---
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.blueAccent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
                      ),
                      child: SwitchListTile(
                        title: const Text('Show Vertex Numbers (0...N)'),
                        subtitle: const Text('Displays indices on the canvas to help you identify start/end points.'),
                        value: engine.showNodeIndices,
                        onChanged: (val) {
                          setLocalState(() {
                            engine.toggleNodeIndices(val);
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 24),

                    // --- Uniform Width ---
                    const Text('Uniform Width', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: uniformController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Width (px)'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: () {
                            final w = double.tryParse(uniformController.text);
                            if (w != null && w >= 0) engine.applyUniformWidth(spline, w);
                          },
                          child: const Text('Apply Uniform'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 24),

                    // --- Taper Width ---
                    const Text('Taper Width', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Text('Interpolates width from node 0 to the last node.', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: startTaperController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Start (Node 0)'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward, color: Colors.grey),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: endTaperController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'End (Last Node)'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonal(
                        onPressed: () {
                          final startW = double.tryParse(startTaperController.text);
                          final endW = double.tryParse(endTaperController.text);
                          if (startW != null && endW != null && startW >= 0 && endW >= 0) {
                            engine.applyTaperToSpline(spline, startW, endW);
                          }
                        },
                        child: const Text('Apply Taper'),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    engine.toggleNodeIndices(false); // Clean up when closing
                    Navigator.of(context).pop();
                  },
                  child: const Text('Close'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}