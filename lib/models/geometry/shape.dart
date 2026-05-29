import 'package:flutter/material.dart';

/// Defines how this shape interacts with the shapes below it
enum CompassBooleanOp { add, subtract, intersect, none }

/// Abstract base class for all visual geometry.
abstract class CompassShape {
  CompassBooleanOp operation;
  bool isVisible;

  CompassShape({
    this.operation = CompassBooleanOp.add, 
    this.isVisible = true,
  });

  Path getPath();

  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false});
}