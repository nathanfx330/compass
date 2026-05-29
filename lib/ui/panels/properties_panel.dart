import 'package:flutter/material.dart';
import '../../engine.dart';

class PropertiesPanel extends StatelessWidget {
  final CompassEngine engine;
  final List<Color> swatchColors;

  const PropertiesPanel({
    super.key,
    required this.engine,
    required this.swatchColors,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final activeLayer = engine.activeLayer;

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
                    onTap: () => engine.changeLayerColor(activeLayer, Colors.transparent),
                    isNone: true,
                  ),
                  ...swatchColors.map((color) {
                    return _buildColorSwatch(
                      color: color, 
                      isSelected: activeLayer.color == color, 
                      theme: theme,
                      onTap: () => engine.changeLayerColor(activeLayer, color),
                    );
                  }),
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
                    onTap: () => engine.changeLayerStrokeColor(activeLayer, Colors.transparent),
                    isNone: true,
                  ),
                  ...swatchColors.map((color) {
                    return _buildColorSwatch(
                      color: color, 
                      isSelected: activeLayer.strokeColor == color, 
                      theme: theme,
                      onTap: () => engine.changeLayerStrokeColor(activeLayer, color),
                    );
                  }),
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
                  engine.changeLayerStrokeWidth(activeLayer, value);
                },
              ),
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
}