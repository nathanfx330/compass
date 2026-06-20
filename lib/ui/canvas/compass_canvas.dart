// lib/ui/canvas/compass_canvas.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'; 

import '../../engine.dart';
import 'compass_renderer.dart';
import 'canvas_hud.dart';
import 'canvas_controller.dart'; // <--- Imports the new controller & CompassTool

class CompassCanvas extends StatefulWidget {
  final CompassEngine engine;
  final bool showScaffolding;
  final VoidCallback onToggleScaffolding;

  const CompassCanvas({
    super.key, 
    required this.engine,
    this.showScaffolding = true,
    required this.onToggleScaffolding,
  });

  @override
  State<CompassCanvas> createState() => _CompassCanvasState();
}

class _CompassCanvasState extends State<CompassCanvas> {
  late CanvasController _controller;

  @override
  void initState() {
    super.initState();
    // Initialize our new dedicated gesture & math controller
    _controller = CanvasController(widget.engine);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // ListenableBuilder ensures the canvas ONLY rebuilds when the controller says so
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return Stack(
          children: [
            Listener(
              onPointerDown: (event) {
                if (event.buttons == kMiddleMouseButton) {
                  _controller.startCanvasPan();
                }
              },
              onPointerMove: (event) {
                _controller.updateCanvasPan(event.delta);
              },
              onPointerUp: (event) {
                _controller.endCanvasPan();
              },
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  _controller.handleScroll(event, context);
                }
              },
              child: MouseRegion(
                onHover: (event) => _controller.onHover(event, context, widget.showScaffolding),
                onExit: (_) => _controller.clearHover(),
                cursor: _controller.isPanningCanvas
                    ? SystemMouseCursors.move
                    : (_controller.targetTensionNode != null && _controller.isAPressed
                        ? SystemMouseCursors.resizeUpRight
                        : (_controller.hoveredPoint != null 
                            ? SystemMouseCursors.precise 
                            : SystemMouseCursors.basic)),
                child: GestureDetector(
                  onTapDown: (details) => _controller.onTapDown(details, context, widget.showScaffolding),
                  onSecondaryTapDown: (details) => _controller.onSecondaryTapDown(
                    details, context, widget.showScaffolding, widget.onToggleScaffolding,
                  ), 
                  onPanStart: (details) => _controller.onPanStart(details, context, widget.showScaffolding),
                  onPanUpdate: (details) => _controller.onPanUpdate(details, context, widget.showScaffolding),
                  onPanEnd: _controller.onPanEnd,
                  onPanCancel: _controller.onPanCancel,
                  child: Container(
                    color: Colors.transparent, 
                    width: double.infinity,
                    height: double.infinity,
                    child: CustomPaint(
                      painter: CompassRenderer(
                        engine: widget.engine,
                        selectedPoint: _controller.selectedPoints.isNotEmpty ? _controller.selectedPoints.first : null,     
                        selectedPoints: _controller.selectedPoints,
                        rotationPivotOffset: _controller.rotationPivotOffset,     
                        isRPressed: _controller.isRPressed,           
                        isShiftRPressed: _controller.isShiftRPressed,
                        isAPressed: _controller.isAPressed, 
                        // --- NEW: Pass Fillet State to Renderer ---
                        activeFilletNode: _controller.activeFilletNode,
                        activeFilletSpline: _controller.activeFilletSpline,
                        activeFilletRadius: _controller.activeFilletRadius,
                        isFPressed: _controller.isFPressed,
                        
                        tensionTargetPoint: _controller.targetTensionNode?.point, 
                        shapeStartPoint: _controller.shapeStartPoint, 
                        hoveredPoint: _controller.hoveredPoint,
                        hoverPosition: _controller.hoverPosition,
                        currentTool: _controller.currentTool,
                        showScaffolding: widget.showScaffolding,
                        panOffset: _controller.panOffset,
                        canvasScale: _controller.canvasScale,
                        pointBorderColor: theme.colorScheme.surface, 
                        activeHandleNode: _controller.activeHandleNode,
                        activeHandleIsOut: _controller.activeHandleIsOut,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // --- Interactive Selection Box Render Layer ---
            if (_controller.isDraggingSelectionBox && _controller.selectionBoxStart != null && _controller.selectionBoxCurrent != null)
               Positioned(
                 left: min(_controller.selectionBoxStart!.dx, _controller.selectionBoxCurrent!.dx) * _controller.canvasScale + _controller.panOffset.dx,
                 top: min(_controller.selectionBoxStart!.dy, _controller.selectionBoxCurrent!.dy) * _controller.canvasScale + _controller.panOffset.dy,
                 width: (_controller.selectionBoxCurrent!.dx - _controller.selectionBoxStart!.dx).abs() * _controller.canvasScale,
                 height: (_controller.selectionBoxCurrent!.dy - _controller.selectionBoxStart!.dy).abs() * _controller.canvasScale,
                 child: IgnorePointer(
                   child: Container(
                     decoration: BoxDecoration(
                       color: Colors.blue.withOpacity(0.1),
                       border: Border.all(color: Colors.blueAccent, width: 1.0),
                     ),
                   ),
                 ),
               ),

            // --- Canvas Heads Up Display (HUD) ---
            Positioned.fill(
              child: CanvasHUD(
                engine: widget.engine,
                showScaffolding: widget.showScaffolding,
                currentTool: _controller.currentTool,
                onToolSelected: _controller.setTool,
                isRPressed: _controller.isRPressed,
                isShiftRPressed: _controller.isShiftRPressed,
                isShiftPressed: _controller.isShiftPressed,
                isAPressed: _controller.isAPressed, 
                // --- NEW: Pass F Key state to HUD ---
                isFPressed: _controller.isFPressed,
                
                panOffset: _controller.panOffset,
                canvasScale: _controller.canvasScale,
              ),
            ),
          ],
        );
      },
    );
  }
}