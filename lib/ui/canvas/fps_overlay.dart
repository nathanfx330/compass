import 'dart:ui' show FontFeature, FrameTiming;

import 'package:flutter/material.dart';

/// Lightweight frame-timing overlay used from the Debug menu.
///
/// It listens to Flutter's real frame timings instead of running its own ticker,
/// so enabling the overlay does not continuously schedule frames or inflate the
/// measured FPS while the canvas is idle.
class FpsOverlay extends StatefulWidget {
  const FpsOverlay({super.key});

  @override
  State<FpsOverlay> createState() => _FpsOverlayState();
}

class _FpsOverlayState extends State<FpsOverlay> {
  final Stopwatch _window = Stopwatch();

  int _frameCount = 0;
  Duration _buildTotal = Duration.zero;
  Duration _rasterTotal = Duration.zero;

  double _fps = 0.0;
  double _buildMs = 0.0;
  double _rasterMs = 0.0;

  @override
  void initState() {
    super.initState();
    _window.start();
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeTimingsCallback(_onFrameTimings);
    super.dispose();
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _frameCount++;
      _buildTotal += timing.buildDuration;
      _rasterTotal += timing.rasterDuration;
    }

    final elapsed = _window.elapsed;
    if (elapsed < const Duration(milliseconds: 450) || _frameCount == 0) {
      return;
    }

    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final fps = _frameCount / seconds;
    final buildMs =
        _buildTotal.inMicroseconds / _frameCount / Duration.microsecondsPerMillisecond;
    final rasterMs =
        _rasterTotal.inMicroseconds / _frameCount / Duration.microsecondsPerMillisecond;

    _frameCount = 0;
    _buildTotal = Duration.zero;
    _rasterTotal = Duration.zero;
    _window
      ..reset()
      ..start();

    if (!mounted) return;
    setState(() {
      _fps = fps;
      _buildMs = buildMs;
      _rasterMs = rasterMs;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final targetFrameMs = 1000.0 / 60.0;
    final slow = _buildMs + _rasterMs > targetFrameMs;

    return IgnorePointer(
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withOpacity(0.90),
            border: Border.all(
              color: slow
                  ? theme.colorScheme.error.withOpacity(0.75)
                  : theme.dividerColor,
            ),
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            child: DefaultTextStyle(
              style: theme.textTheme.labelSmall!.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
                height: 1.25,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_fps.round()} FPS',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: slow ? theme.colorScheme.error : null,
                    ),
                  ),
                  Text(
                    'UI ${_buildMs.toStringAsFixed(1)} ms  GPU ${_rasterMs.toStringAsFixed(1)} ms',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
