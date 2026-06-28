// /lib/ui/panels/layers_panel.dart

import 'package:flutter/material.dart';

import '../../engine.dart';
import 'layer_tile.dart';

/// The hierarchy panel: a header, a reorderable z-stack of layer cards, and the
/// pinned reference-image footer. Slimmed to an orchestrator -- the per-shape row
/// lives in shape_row.dart, the whole layer card (header + shape list + shape
/// drop targets) lives in layer_tile.dart, and every mutation routes through the
/// engine. (The reference footer is still inline here; it's slated to move to
/// reference_layer_tile.dart as a follow-up, but it's outside the reordering
/// surface so it isn't urgent.)
///
/// LAYER REORDERING: a ReorderableListView with buildDefaultDragHandles:false, so
/// the ONLY drag trigger is the explicit grip inside each LayerTile -- that's what
/// keeps layer-card dragging from colliding with the per-shape LongPressDraggable
/// nested in each ShapeRow. The list is rendered TOP-OF-STACK-FIRST (visual index
/// 0 = highest model index), so onReorder converts visual<->model per the recipe
/// in hierarchy_ops.dart before calling engine.reorderLayer.
class LayersPanel extends StatelessWidget {
  final CompassEngine engine;
  final VoidCallback onLoadReferenceImage;

  const LayersPanel({
    super.key,
    required this.engine,
    required this.onLoadReferenceImage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Hierarchy',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_box_outlined),
                tooltip: 'New Layer',
                onPressed: () {
                  engine.addLayer('Layer ${engine.layers.length + 1}');
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // MATHEMATICAL LAYERS (reorderable z-stack, top-of-stack first)
        Expanded(
          child: ListenableBuilder(
            listenable: engine,
            builder: (context, _) {
              if (engine.layers.isEmpty) {
                return const Center(
                  child: Text(
                    'No layers yet.',
                    style: TextStyle(color: Colors.grey),
                  ),
                );
              }

              final int n = engine.layers.length;

              return ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: n,
                // Lift the dragged card onto its own Material so it reads as a
                // floating tile (elevation + rounded corners) rather than carrying
                // the panel's flat full-bleed look while in flight.
                proxyDecorator: (child, index, animation) {
                  return Material(
                    elevation: 6,
                    borderRadius: BorderRadius.circular(8),
                    color: theme.colorScheme.surface,
                    child: child,
                  );
                },
                onReorder: (oldIndex, newIndex) {
                  // ReorderableListView's newIndex is an INSERTION index in the
                  // pre-removal list; when dragging downward it points one past the
                  // target slot, so pull it back by one. Then flip both visual
                  // indices to model indices (the list is shown reversed). See the
                  // recipe in hierarchy_ops.dart.
                  if (newIndex > oldIndex) newIndex -= 1;
                  final from = (n - 1) - oldIndex;
                  final to = (n - 1) - newIndex;
                  engine.reorderLayer(from, to);
                },
                itemBuilder: (context, index) {
                  // Visual index -> model index (reversed): visual 0 is the top of
                  // the z-stack = the LAST layer in engine.layers.
                  final layerIndex = (n - 1) - index;
                  final layer = engine.layers[layerIndex];

                  // ReorderableListView requires a stable key per item, keyed to
                  // the LAYER identity so it follows the card across a reorder.
                  return LayerTile(
                    key: ValueKey(layer),
                    engine: engine,
                    layer: layer,
                    // The grip forwards THIS visual index straight to onReorder.
                    dragIndex: index,
                  );
                },
              );
            },
          ),
        ),

        // --- THE REFERENCE IMAGE LAYER (PERMANENTLY PINNED TO BOTTOM) ---
        // Inline for now; outside the reordering surface. Candidate for extraction
        // into reference_layer_tile.dart as a follow-up.
        ListenableBuilder(
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
        ),
      ],
    );
  }
}