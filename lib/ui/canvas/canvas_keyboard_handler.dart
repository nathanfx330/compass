// lib/ui/canvas/canvas_keyboard_handler.dart

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
    final isX = keys.contains(LogicalKeyboardKey.keyX); // <--- NEW: mesh slice modifier

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
    if (isDelete && controller.selectedPoints.isNotEmpty && event is KeyDownEvent) {
       for (var p in controller.selectedPoints.toList()) {
         engine.removePoint(p);
       }
       controller.selectedPoints.clear();
       // Note: the controller's notifyListeners() is accessible because it extends ChangeNotifier
       controller.notifyListeners();
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