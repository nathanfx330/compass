// lib/models/geometry/spline.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';

class CompassSplineNode {
  final CompassPoint point;
  // 0.0 means a perfectly sharp linear corner. 1.0 means a fully smooth Catmull-Rom curve.
  final ValueNotifier<double> tension;

  CompassSplineNode({required this.point, double tension = 1.0}) 
      : tension = ValueNotifier(tension);
}

class CompassXSpline extends CompassShape {
  final List<CompassSplineNode> nodes = [];
  bool isClosed;
  
  // Optional anchor point to represent the mathematical center for rigid body constraints
  CompassPoint? anchorPoint;

  CompassXSpline({this.isClosed = false, this.anchorPoint, super.operation, super.isVisible});

  void addNode(CompassSplineNode node) {
    nodes.add(node);
  }

  // Figure out which segment of the line the new point was dropped on
  int getInsertIndexForOffset(Offset tap) {
    if (nodes.length < 2) return nodes.length;
    
    double minDist = double.infinity;
    int bestIndex = 1; // Default to inserting after the first point
    
    int loopCount = isClosed ? nodes.length : nodes.length - 1;
    
    for (int i = 0; i < loopCount; i++) {
      final p1 = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
      final p2 = Offset(nodes[(i + 1) % nodes.length].point.x.value, nodes[(i + 1) % nodes.length].point.y.value);
      
      // Calculate point-to-line-segment distance
      final l2 = (p2.dx - p1.dx) * (p2.dx - p1.dx) + (p2.dy - p1.dy) * (p2.dy - p1.dy);
      double t = 0;
      if (l2 != 0) {
        t = ((tap.dx - p1.dx) * (p2.dx - p1.dx) + (tap.dy - p1.dy) * (p2.dy - p1.dy)) / l2;
        t = max(0, min(1, t));
      }
      final proj = Offset(p1.dx + t * (p2.dx - p1.dx), p1.dy + t * (p2.dy - p1.dy));
      final dist = (tap - proj).distance;
      
      if (dist < minDist) {
        minDist = dist;
        bestIndex = (i + 1) % nodes.length;
        if (bestIndex == 0 && !isClosed) bestIndex = nodes.length; // Append to end if open
      }
    }
    
    // If closed and best index wrapped to 0, it means insert at the very end of the list
    if (bestIndex == 0 && isClosed) return nodes.length;
    return bestIndex;
  }

  // Calculates the tangents based on tension and neighbors
  List<Offset> _calculateTangents() {
    List<Offset> tangents = [];
    for (int i = 0; i < nodes.length; i++) {
      final current = nodes[i];
      final tension = current.tension.value;
      
      Offset prev, next;
      
      if (isClosed) {
        prev = Offset(nodes[(i - 1 + nodes.length) % nodes.length].point.x.value, nodes[(i - 1 + nodes.length) % nodes.length].point.y.value);
        next = Offset(nodes[(i + 1) % nodes.length].point.x.value, nodes[(i + 1) % nodes.length].point.y.value);
      } else {
        prev = i == 0 
          ? Offset(current.point.x.value, current.point.y.value) 
          : Offset(nodes[i - 1].point.x.value, nodes[i - 1].point.y.value);
        next = i == nodes.length - 1 
          ? Offset(current.point.x.value, current.point.y.value) 
          : Offset(nodes[i + 1].point.x.value, nodes[i + 1].point.y.value);
      }
      
      // Standard Catmull-Rom tangent factor is 0.5. We scale it by our tension slider.
      final dx = (next.dx - prev.dx) * 0.5 * tension;
      final dy = (next.dy - prev.dy) * 0.5 * tension;
      
      if (!isClosed) {
        if (i == 0) {
          tangents.add(Offset((next.dx - current.point.x.value) * tension, (next.dy - current.point.y.value) * tension));
        } else if (i == nodes.length - 1) {
          tangents.add(Offset((current.point.x.value - prev.dx) * tension, (current.point.y.value - prev.dy) * tension));
        } else {
          tangents.add(Offset(dx, dy));
        }
      } else {
        tangents.add(Offset(dx, dy));
      }
    }
    return tangents;
  }

  @override
  Path getPath() {
    final path = Path();
    // Setting fillType to evenOdd explicitly solves winding rule issues 
    // when Catmull-Rom nodes loop tightly or are used in boolean subtractions
    path.fillType = PathFillType.evenOdd;
    
    if (nodes.isEmpty) return path;
    
    final startOffset = Offset(nodes[0].point.x.value, nodes[0].point.y.value);
    path.moveTo(startOffset.dx, startOffset.dy);

    if (nodes.length == 1) return path;

    final tangents = _calculateTangents();
    int loopCount = isClosed ? nodes.length : nodes.length - 1;

    for (int i = 0; i < loopCount; i++) {
      final p0 = nodes[i];
      final p1 = nodes[(i + 1) % nodes.length];
      
      final pt0 = Offset(p0.point.x.value, p0.point.y.value);
      final pt1 = Offset(p1.point.x.value, p1.point.y.value);
      
      final t0 = tangents[i];
      final t1 = tangents[(i + 1) % nodes.length];

      // Convert Catmull-Rom/Hermite tangents to standard Cubic Bezier control points
      final cp1 = Offset(pt0.dx + t0.dx / 3, pt0.dy + t0.dy / 3);
      final cp2 = Offset(pt1.dx - t1.dx / 3, pt1.dy - t1.dy / 3);

      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, pt1.dx, pt1.dy);
    }
    
    if (isClosed) {
      path.close();
    }

    return path;
  }

  // Generates pure mathematically exact SVG bezier paths (no flattened lines)
  String getSvgPathData() {
    if (nodes.isEmpty) return "";
    final buffer = StringBuffer();
    final start = Offset(nodes[0].point.x.value, nodes[0].point.y.value);
    
    // Explicitly add an SVG fill-rule hint so external editors (like Illustrator) parse booleans correctly
    buffer.write('M ${start.dx} ${start.dy} ');

    if (nodes.length > 1) {
      final tangents = _calculateTangents();
      int loopCount = isClosed ? nodes.length : nodes.length - 1;

      for (int i = 0; i < loopCount; i++) {
        final p0 = nodes[i];
        final p1 = nodes[(i + 1) % nodes.length];
        
        final pt0 = Offset(p0.point.x.value, p0.point.y.value);
        final pt1 = Offset(p1.point.x.value, p1.point.y.value);
        
        final t0 = tangents[i];
        final t1 = tangents[(i + 1) % nodes.length];

        final cp1 = Offset(pt0.dx + t0.dx / 3, pt0.dy + t0.dy / 3);
        final cp2 = Offset(pt1.dx - t1.dx / 3, pt1.dy - t1.dy / 3);

        buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${pt1.dx} ${pt1.dy} ');
      }
    }

    if (isClosed) {
      buffer.write('Z');
    }
    return buffer.toString().trim();
  }

  @override
  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false}) {
    canvas.drawPath(getPath(), paint);

    // Draw the Mocha-style Tension Handles
    if (showScaffolding && isSelected) {
      final scaffoldLinePaint = Paint()
        ..color = Colors.blue.withOpacity(0.5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      final boxStrokePaint = Paint()
        ..color = Colors.blue
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      for (var node in nodes) {
        final pt = Offset(node.point.x.value, node.point.y.value);
        
        // Fixed length visual slider projecting up and right
        final handlePt = pt + const Offset(20, -30);
        
        // The tether line
        canvas.drawLine(pt, handlePt, scaffoldLinePaint);
        
        // The interactive tension box
        final handleRect = Rect.fromCenter(center: handlePt, width: 10, height: 10);
        canvas.drawRect(handleRect, boxStrokePaint);
        
        // Fill indicates how "smooth" (tension) it is
        // BUG FIX: Clamped the opacity between 0.0 and 1.0 to prevent silent Flutter crashes
        final tensionFillPaint = Paint()
          ..color = Colors.blue.withOpacity(node.tension.value.clamp(0.0, 1.0))
          ..style = PaintingStyle.fill;
        canvas.drawRect(handleRect, tensionFillPaint);
      }
    }
  }
}