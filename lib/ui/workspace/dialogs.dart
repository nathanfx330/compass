// /lib/ui/workspace/dialogs.dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../engine.dart';
import '../../models/layer.dart';
import '../../models/geometry/spline.dart';

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
                'Compass 0.3',
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
  //      It matters in BOTH modes -- in scanline it sets the band density; in grid
  //      it sets how finely the boundary contour is sampled for cell clipping.
  //   2. "Grid mesh" checkbox switches tessellation: off = scanline (robust,
  //      follows the curve, many thin bands); on = uniform quad grid (clean
  //      workable topology, blocky silhouette). When on, a cell-count slider sets
  //      how many cells span the longest side (higher = finer + smoother edge).
  //   3. toOBJ returns an EMPTY STRING when the layer has no fillable area; we
  //      treat that like the PNG exporter's null and surface a snackbar instead of
  //      writing a junk file.
  static void showExportOBJ(BuildContext context, CompassEngine engine, CompassLayer layer) {
    // Seed the filename from the layer name so the default is meaningful.
    final safeName = layer.name.replaceAll(RegExp(r'\s+'), '_').replaceAll(RegExp(r'[^A-Za-z0-9_\-.]'), '');
    final TextEditingController filenameController =
        TextEditingController(text: '${safeName.isEmpty ? 'layer' : safeName}.obj');

    // Sampling spacing in logical px. Smaller = denser polygon = smoother.
    double samplingSpacing = 2.0;
    // Grid mode + density. gridCount = cells across the longest bbox side.
    bool gridMode = false;
    double gridCount = 48;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            return AlertDialog(
              title: Text('Export "${layer.name}" as OBJ'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Exports this layer\'s resolved boolean fill as a flat '
                      'triangle mesh on the Z=0 plane (holes preserved).'),
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
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 8),

                  // --- Grid mesh toggle ---
                  CheckboxListTile(
                    value: gridMode,
                    onChanged: (v) {
                      setLocalState(() {
                        gridMode = v ?? false;
                      });
                    },
                    title: const Text('Grid mesh (clean quads)'),
                    subtitle: const Text(
                      'Uniform quad grid instead of scanline bands. Workable topology; '
                      'edges step at the cell size.',
                    ),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),

                  // --- Cell-count slider, only shown when grid mode is on ---
                  if (gridMode) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Text('Cells across'),
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
                    Text(
                      'More cells = smoother silhouette, more quads.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      'Finer = smoother curves, more triangles.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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
                    if (!filename.endsWith('.obj')) {
                      filename += '.obj';
                    }
                    try {
                      final objData = engine.toOBJ(
                        layer,
                        samplingSpacing: samplingSpacing,
                        gridMode: gridMode,
                        gridCount: gridCount.round(),
                      );
                      if (objData.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Nothing to export — this layer has no filled area.')),
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
}