// lib/models/geometry/spline.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';

class CompassSplineNode {
  final CompassPoint point;
  // 0.0 means a perfectly sharp linear corner. 1.0 means a fully smooth Catmull-Rom curve.
  // NOTE: tension acts as a master multiplier for ALL handles (Catmull-Rom AND Explicit).
  final ValueNotifier<double> tension;

  // Dual independent handles. 
  // handleIn is the offset FROM the point TO the incoming control point.
  // handleOut is the offset FROM the point TO the outgoing control point.
  //
  // Explicit handles OVERRIDE the neighbor-derived Catmull-Rom tangent, letting us 
  // express mathematically exact geometry (e.g. true circular-arc subdivisions).
  Offset? handleIn;
  Offset? handleOut;

  CompassSplineNode({
    required this.point, 
    double tension = 1.0, 
    this.handleIn, 
    this.handleOut,
  }) : tension = ValueNotifier(tension);
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

  // Returns the (insertIndex, t_value) for the closest segment
  (int, double) getInsertDetailsForOffset(Offset tap) {
    if (nodes.length < 2) return (nodes.length, 0.0);
    
    double minDist = double.infinity;
    int bestIndex = 1; 
    double bestT = 0.5;
    
    int loopCount = isClosed ? nodes.length : nodes.length - 1;
    
    for (int i = 0; i < loopCount; i++) {
      final p1 = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
      final p2 = Offset(nodes[(i + 1) % nodes.length].point.x.value, nodes[(i + 1) % nodes.length].point.y.value);
      
      // Calculate point-to-line-segment distance to find the closest segment mathematically
      final l2 = (p2.dx - p1.dx) * (p2.dx - p1.dx) + (p2.dy - p1.dy) * (p2.dy - p1.dy);
      double t = 0;
      if (l2 != 0) {
        t = ((tap.dx - p1.dx) * (p2.dx - p1.dx) + (tap.dy - p1.dy) * (p2.dy - p1.dy)) / l2;
        // Clamp t slightly inward to prevent degenerate stacking exactly on top of an existing node
        t = max(0.001, min(0.999, t)); 
      }
      final proj = Offset(p1.dx + t * (p2.dx - p1.dx), p1.dy + t * (p2.dy - p1.dy));
      final dist = (tap - proj).distance;
      
      if (dist < minDist) {
        minDist = dist;
        bestIndex = (i + 1) % nodes.length;
        if (bestIndex == 0 && !isClosed) bestIndex = nodes.length; 
        bestT = t;
      }
    }
    
    // If closed and best index wrapped to 0, it means insert at the very end of the list
    if (bestIndex == 0 && isClosed) return (nodes.length, bestT);
    return (bestIndex, bestT);
  }

  // Resolves the actual control point offsets (handleOut, handleIn) for every node.
  List<(Offset, Offset)> getEvaluatedControls() {
    List<(Offset, Offset)> controls = [];
    for (int i = 0; i < nodes.length; i++) {
      final current = nodes[i];
      final tension = current.tension.value;
      
      Offset? hOut = current.handleOut;
      Offset? hIn = current.handleIn;

      // If both explicit handles exist, we just scale them by the tension multiplier
      if (hOut != null && hIn != null) {
        controls.add((hOut * tension, hIn * tension));
        continue;
      }

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
      
      Offset tangent;
      if (!isClosed) {
        if (i == 0) {
          tangent = Offset((next.dx - current.point.x.value) * tension, (next.dy - current.point.y.value) * tension);
        } else if (i == nodes.length - 1) {
          tangent = Offset((current.point.x.value - prev.dx) * tension, (current.point.y.value - prev.dy) * tension);
        } else {
          tangent = Offset(dx, dy);
        }
      } else {
        tangent = Offset(dx, dy);
      }

      // Fallback: Catmull-Rom tangent converted to cubic Bezier handle length (/ 3).
      // Since explicit handles scale above by tension, we also scale the explicit fallback here
      // if one handle is explicit and the other is Catmull-Rom (rare but possible).
      controls.add((
        hOut != null ? hOut * tension : Offset(tangent.dx / 3, tangent.dy / 3),
        hIn != null ? hIn * tension : Offset(-tangent.dx / 3, -tangent.dy / 3)
      ));
    }
    return controls;
  }

  @override
  Path getPath() {
    final path = Path();
    // Setting fillType to evenOdd explicitly solves winding rule issues 
    // when nodes loop tightly or are used in boolean subtractions
    path.fillType = PathFillType.evenOdd;
    
    if (nodes.isEmpty) return path;
    
    final startOffset = Offset(nodes[0].point.x.value, nodes[0].point.y.value);
    path.moveTo(startOffset.dx, startOffset.dy);

    if (nodes.length == 1) return path;

    final controls = getEvaluatedControls();
    int loopCount = isClosed ? nodes.length : nodes.length - 1;

    for (int i = 0; i < loopCount; i++) {
      final pt0 = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
      final pt1 = Offset(nodes[(i + 1) % nodes.length].point.x.value, nodes[(i + 1) % nodes.length].point.y.value);
      
      final hOut = controls[i].$1;
      final hIn = controls[(i + 1) % nodes.length].$2;

      // Convert offsets to absolute standard Cubic Bezier control points
      final cp1 = pt0 + hOut;
      final cp2 = pt1 + hIn;

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
      final controls = getEvaluatedControls();
      int loopCount = isClosed ? nodes.length : nodes.length - 1;

      for (int i = 0; i < loopCount; i++) {
        final pt0 = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
        final pt1 = Offset(nodes[(i + 1) % nodes.length].point.x.value, nodes[(i + 1) % nodes.length].point.y.value);
        
        final cp1 = pt0 + controls[i].$1;
        final cp2 = pt1 + controls[(i + 1) % nodes.length].$2;

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
        final tensionFillPaint = Paint()
          ..color = Colors.blue.withOpacity(node.tension.value.clamp(0.0, 1.0))
          ..style = PaintingStyle.fill;
        canvas.drawRect(handleRect, tensionFillPaint);
      }
    }
  }
}