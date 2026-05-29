import 'package:flutter/material.dart';
import 'geometry/shape.dart';

/// Represents a distinct Z-layer of geometry.
class CompassLayer {
  final String id;
  String name;
  bool isVisible = true;
  bool isExpanded = true; 
  Color color; 
  Color strokeColor;
  double strokeWidth;
  
  final List<CompassShape> shapes = [];

  CompassLayer({
    required this.name,
    this.color = const Color(0xFF222222), 
    this.strokeColor = Colors.transparent, 
    this.strokeWidth = 2.0,
    String? id,
  }) : id = id ?? UniqueKey().toString();

  Path getLayerPath() {
    Path master = Path();
    for (var shape in shapes) {
      if (!shape.isVisible || shape.operation == CompassBooleanOp.none) continue;

      final shapePath = shape.getPath();
      if (shapePath.computeMetrics().isEmpty) continue;

      if (master.computeMetrics().isEmpty && shape.operation == CompassBooleanOp.add) {
         master = shapePath;
         continue;
      }

      if (shape.operation == CompassBooleanOp.add) {
        master = Path.combine(PathOperation.union, master, shapePath);
      } else if (shape.operation == CompassBooleanOp.subtract) {
        master = Path.combine(PathOperation.difference, master, shapePath);
      } else if (shape.operation == CompassBooleanOp.intersect) {
        master = Path.combine(PathOperation.intersect, master, shapePath);
      }
    }
    return master;
  }
}