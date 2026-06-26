// ./lib/ui/canvas/compass_canvas.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart'; 

import '../../engine.dart';
import 'compass_renderer.dart';
import 'canvas_hud.dart';
import 'canvas_controller.dart'; 

class CompassCanvas extends StatefulWidget {
  final CompassEngine engine;
  final bool showScaffolding;
  final VoidCallback onToggleScaffolding;
  final bool showHandles; // <--- NEW
  final VoidCallback onToggleHandles; // <--- NEW

  const CompassCanvas({
    super.key, 
    required this.engine,
    this.showScaffolding = true,
    required this.onToggleScaffolding,
    required this.showHandles, // <--- NEW
    required this.onToggleHandles, // <--- NEW
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
                  // --- NEW: clean-click resolver for a 2+ selection. Fires only when
                  // the press did NOT become a pan (the arena picked tap), so it's how
                  // a click collapses/toggles the group while a drag moves it. ---
                  onTap: () => _controller.onTap(),
                  // --- NEW: if the tap is aborted without becoming a pan, drop any
                  // deferred press so it can't leak into the next gesture. ---
                  onTapCancel: () => _controller.onTapCancel(),
                  onSecondaryTapDown: (details) => _controller.onSecondaryTapDown(
                    details, context, widget.showScaffolding, widget.onToggleScaffolding,
                    widget.showHandles, widget.onToggleHandles, // <--- NEW
                  ), 
                  // <--- NEW: Passed showHandles down to pan functions so handles can be ignored if hidden
                  onPanStart: (details) => _controller.onPanStart(details, context, widget.showScaffolding, widget.showHandles),
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
                        isCtrlRPressed: _controller.isCtrlRPressed, // <--- ADDED CTRL+R STATE
                        isAPressed: _controller.isAPressed, 
                        activeFilletNode: _controller.activeFilletNode,
                        activeFilletSpline: _controller.activeFilletSpline,
                        activeFilletRadius: _controller.activeFilletRadius,
                        isFPressed: _controller.isFPressed,
                        // --- NEW: Width tool (W key) state, wired through so the
                        // width diamonds actually draw. The controller has tracked
                        // these all along; they simply were never passed in, so they
                        // defaulted to false and the handles never rendered. ---
                        isWPressed: _controller.isWPressed,
                        activeWidthNode: _controller.activeWidthNode,
                        activeWidthIsLeft: _controller.activeWidthIsLeft,
                        addVertexPreviewPos: _controller.addVertexPreviewPos,
                        addVertexSpline: _controller.addVertexSpline,
                        addVertexSegmentIndex: _controller.addVertexSegmentIndex,
                        // --- NEW: X-key mesh slice preview. The controller resolves
                        // these on hover (which mesh, row vs column, the two dashed-
                        // line endpoints); the renderer draws the dotted guide from
                        // them. Default null/false when no slice is staged. ---
                        sliceIsRow: _controller.sliceIsRow,
                        slicePreviewA: _controller.slicePreviewA,
                        slicePreviewB: _controller.slicePreviewB,
                        tensionTargetPoint: _controller.targetTensionNode?.point, 
                        shapeStartPoint: _controller.shapeStartPoint, 
                        hoveredPoint: _controller.hoveredPoint,
                        hoverPosition: _controller.hoverPosition,
                        currentTool: _controller.currentTool,
                        showScaffolding: widget.showScaffolding,
                        showHandles: widget.showHandles, // <--- NEW
                        panOffset: _controller.panOffset,
                        canvasScale: _controller.canvasScale,
                        pointBorderColor: theme.colorScheme.surface, 
                        activeHandleNode: _controller.activeHandleNode,
                        activeHandleIsOut: _controller.activeHandleIsOut,
                        // --- NEW: bounding box of the active 2+ selection (logical
                        // space, or null). The renderer draws the grabbable box from
                        // this. Pairs with the selectionBounds param added to
                        // CompassRenderer in the next file. ---
                        selectionBounds: _controller.selectionBounds,
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
                isCtrlRPressed: _controller.isCtrlRPressed, // <--- ADDED CTRL+R STATE
                isShiftPressed: _controller.isShiftPressed,
                isAPressed: _controller.isAPressed, 
                isFPressed: _controller.isFPressed,
                isZPressed: _controller.isZPressed, 
                isShiftZPressed: _controller.isShiftZPressed, // <--- NEW: Passed down to HUD
                isWPressed: _controller.isWPressed, // <--- NEW: Passed down to HUD
                is1Pressed: _controller.is1Pressed,
                is2Pressed: _controller.is2Pressed,
                addVertexActive: _controller.addVertexPreviewPos != null,
                
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