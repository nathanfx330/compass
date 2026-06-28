// /lib/ui/panels/reference_layer_tile.dart

import 'package:flutter/material.dart';

import '../../engine.dart';

/// The reference-image footer, permanently pinned to the BOTTOM of the hierarchy
/// panel. It is NOT a z-stack layer and never participates in layer/shape
/// reordering -- it sits below the reorderable list as a fixed strip. Lifted
/// verbatim out of layers_panel.dart's inline footer as the final cleanup of the
/// panel split; behavior is unchanged.
///
/// Self-contained reactivity: it wraps its own ListenableBuilder(engine), exactly
/// as the inline version did, because it lives OUTSIDE the panel's layer-list
/// ListenableBuilder (a sibling in the Column). So it must subscribe to the engine
/// itself to reflect load / visibility / lock / removal of the reference image
/// live. The panel drops this in as a leaf -- no wiring beyond the two ctor args.
///
/// [onLoadReferenceImage] is threaded from the panel (which gets it from the
/// workspace) rather than opening the dialog here, so the file-path dialog stays
/// owned by the workspace layer and this widget carries no dialog dependency.
class ReferenceLayerTile extends StatelessWidget {
  final CompassEngine engine;
  final VoidCallback onLoadReferenceImage;

  const ReferenceLayerTile({
    super.key,
    required this.engine,
    required this.onLoadReferenceImage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final ref = engine.referenceLayer;

        return Container(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Divider(height: 1, thickness: 2),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Row(
                  children: [
                    const Icon(Icons.image, size: 16, color: Colors.grey),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Reference Image',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey),
                      ),
                    ),
                    if (ref == null)
                      TextButton(
                        onPressed: onLoadReferenceImage,
                        child: const Text('Load...'),
                      )
                    else ...[
                      IconButton(
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(
                          ref.isVisible ? Icons.visibility : Icons.visibility_off,
                          color: ref.isVisible ? theme.iconTheme.color : theme.disabledColor,
                        ),
                        onPressed: engine.toggleReferenceVisibility,
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: Icon(
                          ref.isLocked ? Icons.lock : Icons.lock_open,
                          color: ref.isLocked ? theme.disabledColor : Colors.orange,
                        ),
                        tooltip: ref.isLocked ? 'Unlock to move/scale' : 'Lock position',
                        onPressed: engine.toggleReferenceLock,
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                        onPressed: engine.removeReferenceLayer,
                      ),
                    ]
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}