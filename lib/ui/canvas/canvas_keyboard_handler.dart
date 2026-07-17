// /lib/ui/canvas/canvas_keyboard_handler.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../engine.dart';
import 'canvas_controller.dart';

class CanvasKeyboardHandler {
  /// Parses the active hardware keys, handles immediate actions like Delete, 
  /// and updates the CanvasController's modifier state flags.
  static bool handleKeyEvent(
    KeyEvent event, 
    CanvasController controller, 
    CompassEngine engine
  ) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    
    final isR = keys.contains(LogicalKeyboardKey.keyR);
    final isShift = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
    final isA = keys.contains(LogicalKeyboardKey.keyA);
    final isF = keys.contains(LogicalKeyboardKey.keyF); 
    final isQ = keys.contains(LogicalKeyboardKey.keyQ); 
    final isW = keys.contains(LogicalKeyboardKey.keyW); 
    final isX = keys.contains(LogicalKeyboardKey.keyX); // mesh slice modifier

    // Handle Ctrl/Cmd for the rotation mode
    final isCtrl = keys.contains(LogicalKeyboardKey.controlLeft) || keys.contains(LogicalKeyboardKey.controlRight);
    final isMeta = keys.contains(LogicalKeyboardKey.metaLeft) || keys.contains(LogicalKeyboardKey.metaRight);
    final isCtrlOrMeta = isCtrl || isMeta;

    // Plain Z only -- exclude Ctrl/Cmd so the smooth modifier never collides with
    // Ctrl+Z / Cmd+Z undo (handled at the workspace level via CallbackShortcuts).
    final isZ = keys.contains(LogicalKeyboardKey.keyZ) && !isCtrlOrMeta;

    final isShiftZ = isZ && isShift;
    final isPlainZ = isZ && !isShift;

    final is1 = keys.contains(LogicalKeyboardKey.digit1) || keys.contains(LogicalKeyboardKey.numpad1);
    final is2 = keys.contains(LogicalKeyboardKey.digit2) || keys.contains(LogicalKeyboardKey.numpad2);

    final isDelete = keys.contains(LogicalKeyboardKey.delete) || keys.contains(LogicalKeyboardKey.backspace);

    // Immediate Action: Delete
    //
    // ONE batch call, not a removePoint-per-point loop. The loop had two defects
    // with multi-selections: every removePoint ended in saveSnapshot(), so
    // deleting N points minted N undo states (Ctrl+Z resurrected them one at a
    // time and large deletes flushed the 50-deep stack); and cascade deletions
    // (a shape destroyed by point A dragging its OTHER selected points down with
    // it) made later iterations run a full no-op removal -- shape scan,
    // constraint sweep, and yet another snapshot -- against already-dead points.
    // engine.removePoints() does one combined GC batch, one constraint sweep,
    // one snapshot, one notify. The engine also prunes its own selection set,
    // but the explicit clear() keeps this handler's contract self-evident.
    if (isDelete && controller.selectedPoints.isNotEmpty && event is KeyDownEvent) {
       engine.removePoints(controller.selectedPoints.toList());
       controller.selectedPoints.clear();
       // Note: the controller's notifyListeners() is accessible because it extends ChangeNotifier
       controller.notifyListeners();
    }

    // Immediate Action: S = SHARP VERTEX TOGGLE
    //
    // Fires once on the physical key-down (not on repeats: KeyDownEvent only, and
    // Flutter emits KeyRepeatEvent for holds, so a held S doesn't machine-gun the
    // toggle). Plain S only -- Ctrl/Cmd+S stays free for a future save shortcut,
    // and Shift+S is excluded so it can carry a variant later.
    //
    // Targets the SELECTED points; falls back to the HOVERED point when nothing is
    // selected, so the flow "hover a corner, tap S" works without a click first.
    // The engine method resolves which of those points are actually X-Spline
    // vertices, flips them (fluid -> sharp: tension 0, handles wiped, pulleys
    // cleared; sharp -> fluid: tension 1.0), snapshots once, and notifies. Points
    // that belong to no spline (mesh nodes, circle centers...) are ignored there,
    // so pressing S with a mixed selection is safe.
    final bool isPlainS = keys.contains(LogicalKeyboardKey.keyS) && !isCtrlOrMeta && !isShift;
    if (isPlainS && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.keyS) {
      final targets = <dynamic>{...controller.selectedPoints};
      if (targets.isEmpty && controller.hoveredPoint != null) {
        targets.add(controller.hoveredPoint!);
      }
      if (targets.isNotEmpty) {
        engine.toggleSharpVertices(targets.cast());
        controller.notifyListeners();
      }
    }

    final bool shiftR = isR && isShift && !isCtrlOrMeta;
    final bool ctrlR = isR && isCtrlOrMeta && !isShift;
    final bool justR = isR && !isShift && !isCtrlOrMeta;
    
    // Don't trigger standard shift-pan if we are using the Width tool symmetrically, or smoothing widths
    final bool justShift = isShift && !isR && !isA && !isF && !isW && !isZ; 

    // Diff the current physical keys against the controller's recorded state
    if (controller.isRPressed != justR || 
        controller.isShiftRPressed != shiftR || 
        controller.isCtrlRPressed != ctrlR || 
        controller.isShiftPressed != justShift || 
        controller.isAPressed != isA || 
        controller.isFPressed != isF || 
        controller.isQPressed != isQ || 
        controller.isWPressed != isW ||
        controller.isXPressed != isX ||
        controller.isZPressed != isPlainZ || 
        controller.isShiftZPressed != isShiftZ ||
        controller.is1Pressed != is1 || 
        controller.is2Pressed != is2) {
      
      // Update Controller Flags
      controller.isRPressed = justR;
      controller.isShiftRPressed = shiftR;
      controller.isCtrlRPressed = ctrlR;
      controller.isShiftPressed = justShift;
      controller.isAPressed = isA; 
      controller.isFPressed = isF; 
      controller.isQPressed = isQ; 
      controller.isWPressed = isW; 
      controller.isXPressed = isX; 
      controller.isZPressed = isPlainZ; 
      controller.isShiftZPressed = isShiftZ;
      controller.is1Pressed = is1; 
      controller.is2Pressed = is2; 

      // Dispatch state setup/teardown methods on the controller based on new flags
      if (justR || shiftR || ctrlR) {
        controller.setupRotationState(hierarchy: shiftR, handlesOnly: ctrlR);
      } else {
        controller.clearRotationState();
      }

      if (isA) {
        controller.setupTensionState();
      } else {
        controller.targetTensionNode = null;
      }

      if (!isF && controller.activeFilletNode != null) {
        controller.clearFilletState();
      }

      if (!isW) {
        controller.clearWidthState();
      }

      if (controller.hoverPosition != null) {
        controller.updateAddVertexHover(controller.hoverPosition!);
      } else {
        controller.clearAddVertexHover();
      }

      // X-key mesh slice hover: refresh on any modifier change so pressing X
      // immediately shows the dotted preview at the current cursor, and releasing
      // it clears the preview (updateMeshSliceHover internally bails+clears when X
      // is no longer held).
      if (controller.hoverPosition != null) {
        controller.updateMeshSliceHover(controller.hoverPosition!);
      } else {
        controller.clearMeshSliceHover();
      }
      
      controller.notifyListeners();
    }
    
    return false; 
  }
}