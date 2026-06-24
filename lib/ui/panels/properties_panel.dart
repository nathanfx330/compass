// /lib/ui/panels/properties_panel.dart
import 'package:flutter/material.dart';
import '../../engine.dart';
import '../../models/geometry/spline.dart';
import '../widgets/compass_color_picker.dart';

class PropertiesPanel extends StatefulWidget {
  final CompassEngine engine;
  final List<Color> swatchColors;

  const PropertiesPanel({
    super.key,
    required this.engine,
    required this.swatchColors,
  });

  @override
  State<PropertiesPanel> createState() => _PropertiesPanelState();
}

class _PropertiesPanelState extends State<PropertiesPanel> {
  final TextEditingController _uniformController = TextEditingController(text: '10.0');
  final TextEditingController _startTaperController = TextEditingController(text: '2.0');
  final TextEditingController _endTaperController = TextEditingController(text: '20.0');

  @override
  void dispose() {
    _uniformController.dispose();
    _startTaperController.dispose();
    _endTaperController.dispose();
    super.dispose();
  }

  // A color counts as "custom" — and lights up the Custom chip — when it is a
  // real color that is NOT transparent and NOT one of the presets. Preset colors
  // are stored as the MaterialColor objects from swatchColors, so an exact
  // identity match here works; a picked color is a plain Color and will never
  // match a MaterialColor, which is exactly why a hand-picked value reads as
  // custom even if its hex coincides with a preset's shade.
  bool _isCustomColor(Color c) =>
      c != Colors.transparent && !widget.swatchColors.contains(c);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: widget.engine,
      builder: (context, _) {
        final activeLayer = widget.engine.activeLayer;
        final selectedShape = widget.engine.selectedShape;

        if (activeLayer == null) {
          return const Center(
            child: Text(
              'Select a layer to edit properties.',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Layer: ${activeLayer.name}',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              
              Text(
                'Fill Color',
                style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildColorSwatch(
                    color: Colors.transparent, 
                    isSelected: activeLayer.color == Colors.transparent, 
                    theme: theme,
                    onTap: () => widget.engine.changeLayerColor(activeLayer, Colors.transparent),
                    isNone: true,
                  ),
                  ...widget.swatchColors.map((color) {
                    return _buildColorSwatch(
                      color: color, 
                      isSelected: activeLayer.color == color, 
                      theme: theme,
                      onTap: () => widget.engine.changeLayerColor(activeLayer, color),
                    );
                  }),
                  _buildCustomSwatch(
                    context: context,
                    currentColor: activeLayer.color,
                    isSelected: _isCustomColor(activeLayer.color),
                    theme: theme,
                    onPicked: (c) => widget.engine.changeLayerColor(activeLayer, c),
                  ),
                ],
              ),
              
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 24),

              Text(
                'Stroke Color',
                style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _buildColorSwatch(
                    color: Colors.transparent, 
                    isSelected: activeLayer.strokeColor == Colors.transparent, 
                    theme: theme,
                    onTap: () => widget.engine.changeLayerStrokeColor(activeLayer, Colors.transparent),
                    isNone: true,
                  ),
                  ...widget.swatchColors.map((color) {
                    return _buildColorSwatch(
                      color: color, 
                      isSelected: activeLayer.strokeColor == color, 
                      theme: theme,
                      onTap: () => widget.engine.changeLayerStrokeColor(activeLayer, color),
                    );
                  }),
                  _buildCustomSwatch(
                    context: context,
                    currentColor: activeLayer.strokeColor,
                    isSelected: _isCustomColor(activeLayer.strokeColor),
                    theme: theme,
                    onPicked: (c) => widget.engine.changeLayerStrokeColor(activeLayer, c),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              Row(
                children: [
                  Text(
                    'Stroke Width',
                    style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
                  ),
                  const Spacer(),
                  Text(
                    activeLayer.strokeWidth.toStringAsFixed(1),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Slider(
                value: activeLayer.strokeWidth,
                min: 0.0,
                max: 20.0,
                divisions: 40,
                activeColor: theme.colorScheme.primary,
                onChanged: (value) {
                  widget.engine.changeLayerStrokeWidth(activeLayer, value);
                },
              ),

              // --- NEW: AREA STROKE PROFILE SECTION ---
              if (selectedShape is CompassXSpline) ...[
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 24),
                
                Text(
                  'Area Stroke Profile',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),

                // Vertex Numbering Toggle
                Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: SwitchListTile(
                    title: const Text('Show Vertex Numbers', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    subtitle: const Text('Display 0...N on canvas', style: TextStyle(fontSize: 11)),
                    value: widget.engine.showNodeIndices,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    dense: true,
                    onChanged: (val) {
                      widget.engine.toggleNodeIndices(val);
                    },
                  ),
                ),
                const SizedBox(height: 16),

                // Uniform Width
                Text(
                  'Uniform Width',
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _uniformController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(), 
                          labelText: 'Width (px)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () {
                        final w = double.tryParse(_uniformController.text);
                        if (w != null && w >= 0) widget.engine.applyUniformWidth(selectedShape, w);
                      },
                      child: const Text('Apply'),
                    ),
                  ],
                ),

                const SizedBox(height: 20),

                // Taper Width
                Text(
                  'Taper Width',
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.textTheme.bodySmall?.color),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _startTaperController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(), 
                          labelText: 'Start (0)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.arrow_forward, color: Colors.grey, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _endTaperController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(), 
                          labelText: 'End (N)',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonal(
                    onPressed: () {
                      final startW = double.tryParse(_startTaperController.text);
                      final endW = double.tryParse(_endTaperController.text);
                      if (startW != null && endW != null && startW >= 0 && endW >= 0) {
                        widget.engine.applyTaperToSpline(selectedShape, startW, endW);
                      }
                    },
                    child: const Text('Apply Taper'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildColorSwatch({
    required Color color, 
    required bool isSelected, 
    required ThemeData theme, 
    required VoidCallback onTap,
    bool isNone = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: isNone ? theme.scaffoldBackgroundColor : color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : theme.dividerColor,
            width: isSelected ? 3 : 1,
          ),
          boxShadow: isSelected ? [
            BoxShadow(
              color: theme.colorScheme.primary.withOpacity(0.4),
              blurRadius: 6,
              spreadRadius: 1,
            )
          ] : null,
        ),
        child: isNone 
          ? const Center(child: Icon(Icons.format_color_reset, size: 16, color: Colors.grey))
          : null,
      ),
    );
  }

  // The "Custom…" chip. It opens the pure-Dart HSV picker and applies whatever
  // comes back via onPicked. When an off-palette color is active, the chip wears
  // that exact color (so there's always a live swatch of what's selected, even
  // for a value that isn't in the preset row) and takes the selected ring; the
  // eyedropper icon flips black/white against the color's luminance so it stays
  // legible. When no custom color is active it sits neutral with a primary-tinted
  // icon, reading as an affordance to open the picker.
  Widget _buildCustomSwatch({
    required BuildContext context,
    required Color currentColor,
    required bool isSelected,
    required ThemeData theme,
    required void Function(Color) onPicked,
  }) {
    final Color bg = isSelected ? currentColor : theme.scaffoldBackgroundColor;
    final Color iconColor = isSelected
        ? (currentColor.computeLuminance() > 0.5 ? Colors.black87 : Colors.white)
        : theme.colorScheme.primary;

    return Tooltip(
      message: 'Custom color…',
      child: GestureDetector(
        onTap: () async {
          // A transparent ("None") starting point opens the picker at black
          // rather than at a fully-transparent color, since the picker is
          // opaque-only and "give this a color" wants a visible default.
          final initial =
              currentColor == Colors.transparent ? Colors.black : currentColor;
          final picked =
              await showCompassColorPicker(context, initialColor: initial);
          // onPicked only touches the engine, never context, so it's safe across
          // the await without a mounted guard.
          if (picked != null) onPicked(picked);
        },
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? theme.colorScheme.primary : theme.dividerColor,
              width: isSelected ? 3 : 1,
            ),
            boxShadow: isSelected ? [
              BoxShadow(
                color: theme.colorScheme.primary.withOpacity(0.4),
                blurRadius: 6,
                spreadRadius: 1,
              )
            ] : null,
          ),
          child: Center(
            child: Icon(Icons.colorize, size: 16, color: iconColor),
          ),
        ),
      ),
    );
  }
}