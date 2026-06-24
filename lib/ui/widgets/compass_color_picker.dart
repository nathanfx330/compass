// lib/ui/widgets/compass_color_picker.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A pure-Dart HSV color picker. Zero external dependencies — built from two
/// CustomPainters (a saturation/value square and a hue bar) plus Flutter's
/// built-in [HSVColor] for the math. Opaque-only for now: the returned color
/// always has full alpha, because the SVG exporter currently drops the alpha
/// byte (it slices the value string), so honoring opacity here would silently
/// diverge between the canvas/PNG and the SVG output. Alpha is a clean follow-up
/// once the exporter learns fill-opacity / stroke-opacity.
///
/// Returns the chosen [Color] on confirm, or null if the user cancels.
Future<Color?> showCompassColorPicker(
  BuildContext context, {
  required Color initialColor,
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => _CompassColorPickerDialog(initialColor: initialColor),
  );
}

class _CompassColorPickerDialog extends StatefulWidget {
  final Color initialColor;
  const _CompassColorPickerDialog({required this.initialColor});

  @override
  State<_CompassColorPickerDialog> createState() => _CompassColorPickerDialogState();
}

class _CompassColorPickerDialogState extends State<_CompassColorPickerDialog> {
  // State is kept in HSV — not RGB — so that dragging brightness to 0 (black)
  // and back, or saturation to 0 (gray) and back, does not lose the hue. An
  // RGB-only model collapses hue at those edges; HSV preserves it.
  late HSVColor _hsv;

  // The hex field's controller. We set its text programmatically whenever the
  // square/bar move, which does NOT fire the field's onChanged (that only fires
  // on real user input), so there is no feedback loop between typing and dragging.
  late TextEditingController _hexController;

  static const double _squareSize = 240.0;
  static const double _hueBarHeight = 22.0;
  static const double _thumbRadius = 9.0;

  @override
  void initState() {
    super.initState();
    // Force full alpha: a transparent "None" layer round-trips to (0,0,0) here,
    // which simply opens the picker at black — a sane default for "give this a color."
    _hsv = HSVColor.fromColor(widget.initialColor).withAlpha(1.0);
    _hexController = TextEditingController(text: _hexString(_hsv.toColor()));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  Color get _currentColor => _hsv.toColor();

  static String _hexString(Color c) {
    final r = c.red.toRadixString(16).padLeft(2, '0');
    final g = c.green.toRadixString(16).padLeft(2, '0');
    final b = c.blue.toRadixString(16).padLeft(2, '0');
    return '$r$g$b'.toUpperCase();
  }

  // Parse user-typed hex. Only commits when it's a full, valid 6-digit value;
  // partial/invalid input is ignored (state simply holds). We deliberately do
  // NOT rewrite the controller here, so the user's caret and text are untouched
  // while typing.
  void _applyHex(String raw) {
    var s = raw.trim();
    if (s.startsWith('#')) s = s.substring(1);
    if (s.length == 6 && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(s)) {
      final value = int.parse(s, radix: 16);
      final color = Color(0xFF000000 | value);
      setState(() {
        _hsv = HSVColor.fromColor(color).withAlpha(1.0);
      });
    }
  }

  void _updateSV(Offset localPos) {
    final dx = localPos.dx.clamp(0.0, _squareSize);
    final dy = localPos.dy.clamp(0.0, _squareSize);
    final sat = dx / _squareSize;
    final val = 1.0 - dy / _squareSize;
    setState(() {
      _hsv = _hsv.withSaturation(sat).withValue(val);
      _hexController.text = _hexString(_currentColor);
    });
  }

  void _updateHue(Offset localPos) {
    final dx = localPos.dx.clamp(0.0, _squareSize);
    // HSVColor expects hue in [0, 360); keep it a hair under 360 to avoid wrap.
    final hue = (dx / _squareSize) * 360.0;
    setState(() {
      _hsv = _hsv.withHue(hue.clamp(0.0, 359.9999));
      _hexController.text = _hexString(_currentColor);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Custom Color'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: _squareSize,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSVSquare(theme),
              const SizedBox(height: 12),
              _buildHueBar(theme),
              const SizedBox(height: 16),

              // Full-width preview of the current color.
              Container(
                height: 36,
                decoration: BoxDecoration(
                  color: _currentColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.dividerColor),
                ),
              ),
              const SizedBox(height: 14),

              // Hex input. Restricted to hex characters, max 6.
              TextField(
                controller: _hexController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Hex',
                  prefixText: '#',
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
                  LengthLimitingTextInputFormatter(6),
                ],
                onChanged: _applyHex,
              ),
              const SizedBox(height: 12),

              // Read-only RGB breakdown.
              Row(
                children: [
                  _rgbCell('R', _currentColor.red, theme),
                  const SizedBox(width: 8),
                  _rgbCell('G', _currentColor.green, theme),
                  const SizedBox(width: 8),
                  _rgbCell('B', _currentColor.blue, theme),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_currentColor),
          child: const Text('Select'),
        ),
      ],
    );
  }

  Widget _buildSVSquare(ThemeData theme) {
    final pos = Offset(
      _hsv.saturation * _squareSize,
      (1.0 - _hsv.value) * _squareSize,
    );
    return GestureDetector(
      onTapDown: (d) => _updateSV(d.localPosition),
      onPanStart: (d) => _updateSV(d.localPosition),
      onPanUpdate: (d) => _updateSV(d.localPosition),
      child: SizedBox(
        width: _squareSize,
        height: _squareSize,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CustomPaint(painter: _SVPainter(_hsv.hue)),
              ),
            ),
            // Border overlay (so the white corner of the square is visible on a
            // light dialog); IgnorePointer so it never eats the drag.
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor),
                  ),
                ),
              ),
            ),
            Positioned(
              left: pos.dx - _thumbRadius,
              top: pos.dy - _thumbRadius,
              child: _thumb(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHueBar(ThemeData theme) {
    final x = (_hsv.hue / 360.0) * _squareSize;
    return GestureDetector(
      onTapDown: (d) => _updateHue(d.localPosition),
      onPanStart: (d) => _updateHue(d.localPosition),
      onPanUpdate: (d) => _updateHue(d.localPosition),
      child: SizedBox(
        width: _squareSize,
        height: _hueBarHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_hueBarHeight / 2),
                child: CustomPaint(painter: _HuePainter()),
              ),
            ),
            Positioned(
              left: x - _thumbRadius,
              top: _hueBarHeight / 2 - _thumbRadius,
              child: _thumb(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb() {
    return Container(
      width: _thumbRadius * 2,
      height: _thumbRadius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.transparent,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 2,
            spreadRadius: 0.5,
          ),
        ],
      ),
    );
  }

  Widget _rgbCell(String label, int v, ThemeData theme) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.textTheme.bodySmall?.color?.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '$v',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints the saturation (x: white → hue) × value (y: bright → black) square.
class _SVPainter extends CustomPainter {
  final double hue;
  _SVPainter(this.hue);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hueColor = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();

    // Horizontal: white (sat 0) → pure hue (sat 1).
    final satPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [Colors.white, hueColor],
      ).createShader(rect);
    canvas.drawRect(rect, satPaint);

    // Vertical: transparent (val 1) → black (val 0), multiplied on top.
    final valPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black],
      ).createShader(rect);
    canvas.drawRect(rect, valPaint);
  }

  @override
  bool shouldRepaint(covariant _SVPainter old) => old.hue != hue;
}

/// Paints the full hue spectrum as a horizontal gradient.
class _HuePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    const hueColors = [
      Color(0xFFFF0000), // 0   red
      Color(0xFFFFFF00), // 60  yellow
      Color(0xFF00FF00), // 120 green
      Color(0xFF00FFFF), // 180 cyan
      Color(0xFF0000FF), // 240 blue
      Color(0xFFFF00FF), // 300 magenta
      Color(0xFFFF0000), // 360 red
    ];
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: hueColors,
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _HuePainter old) => false;
}