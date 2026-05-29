import 'dart:io';
import 'package:flutter/material.dart';

import '../../engine.dart';

class CompassDialogs {
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
}