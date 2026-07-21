// lib/ui/workspace/dialogs.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../engine.dart';
import '../../models/layer.dart';
import '../../models/geometry/spline.dart';

// The OBJ exporter's four output modes as the dialog presents them. Local to
// this file: the engine/exporter API stays booleans (gridMode, delaunayMode,
// skeletonMode) for backward compatibility, and _ObjExportMode maps onto them
// at save time.
enum _ObjExportMode { scanline, grid, delaunay, skeleton }

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
    // Resolution multiplier over the artwork's natural bounding-box size.
    double exportScale = 2.0;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: const Text('Export as PNG'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Enter a filename to save your raster image:'),
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
                  const Text('Resolution'),
                  const SizedBox(height: 8),
                  SegmentedButton<double>(
                    segments: const [
                      ButtonSegment(value: 1.0, label: Text('1x')),
                      ButtonSegment(value: 2.0, label: Text('2x')),
                      ButtonSegment(value: 4.0, label: Text('4x')),
                    ],
                    selected: {exportScale},
                    onSelectionChanged: (newSelection) {
                      setLocalState(() {
                        exportScale = newSelection.first;
                      });
                    },
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
                    if (!filename.endsWith('.png')) {
                      filename += '.png';
                    }
                    try {
                      final Uint8List? bytes = await engine.toPNG(scale: exportScale);
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

            String headerText;
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
                    try {
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
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(mode == _ObjExportMode.skeleton
                                  ? 'Nothing to export — no skeleton survived. Try lowering branch pruning or check the layer has filled area.'
                                  : 'Nothing to export — this layer has no filled area.'),
                            ),
                          );
                        }
                        return;
                      }

                      final file = File(filename);
                      await file.writeAsString(objData);
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

  static void showLoadReferenceImage(BuildContext context, CompassEngine engine) {
    final TextEditingController filepathController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Load Reference Image'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter the absolute file path to a local image (PNG/JPG):'),
              const SizedBox(height: 12),
              TextField(
                controller: filepathController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Image File Path',
                  hintText: '/home/user/Pictures/sketch.png',
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
              icon: const Icon(Icons.image_search),
              label: const Text('Load Image'),
              onPressed: () async {
                final path = filepathController.text;
                if (path.isNotEmpty) {
                  Navigator.of(context).pop();
                  await engine.loadReferenceImage(path);
                  if (engine.referenceLayer == null && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Failed to load image at that path.')),
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