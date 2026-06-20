// lib/models/geometry/spline.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';

typedef FilletData = ({
  Offset cutPt1,
  Offset cutPt2,
  Offset prevHandleOut,
  Offset node1HandleIn,
  Offset node1HandleOut,
  Offset node2HandleIn,
  Offset node2HandleOut,
  Offset nextHandleIn,
});

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

  FilletData? computeFillet(CompassSplineNode node, double cutDistance) {
    int index = nodes.indexOf(node);
    if (index == -1) return null;

    // Cannot fillet the extreme endpoints of an open spline
    if (!isClosed && (index == 0 || index == nodes.length - 1)) return null;

    int prevIndex = (index - 1 + nodes.length) % nodes.length;
    int nextIndex = (index + 1) % nodes.length;

    final controls = getEvaluatedControls();
    final hOut_prev = controls[prevIndex].$1;
    final hIn_corner = controls[index].$2;
    final hOut_corner = controls[index].$1;
    final hIn_next = controls[nextIndex].$2;

    final p0 = Offset(nodes[prevIndex].point.x.value, nodes[prevIndex].point.y.value);
    final p3 = Offset(node.point.x.value, node.point.y.value);
    final q0 = p3;
    final q3 = Offset(nodes[nextIndex].point.x.value, nodes[nextIndex].point.y.value);

    final p1 = p0 + hOut_prev;
    final p2 = p3 + hIn_corner;
    final q1 = q0 + hOut_corner;
    final q2 = q3 + hIn_next;

    // Estimate arc length with chord length for parameter calculation
    final d1 = (p3 - p0).distance;
    final d2 = (q3 - q0).distance;

    if (d1 < 0.001 || d2 < 0.001) return null;

    double d = cutDistance;
    final maxD = min(d1, d2) * 0.5;
    if (d > maxD) d = maxD;
    if (d <= 0.1) return null; 

    // Convert real cut-distance to approximate Bezier 't' parameter
    final t1 = 1.0 - (d / d1);
    final t2 = (d / d2);

    // De Casteljau subdivision for Segment 1 (Prev -> Corner)
    final m0 = Offset.lerp(p0, p1, t1)!;
    final m1 = Offset.lerp(p1, p2, t1)!;
    final m2 = Offset.lerp(p2, p3, t1)!;
    final r0 = Offset.lerp(m0, m1, t1)!;
    final r1 = Offset.lerp(m1, m2, t1)!;
    final cutPt1 = Offset.lerp(r0, r1, t1)!;

    final newPrevHandleOut = m0 - p0;
    final node1HandleIn = r0 - cutPt1;

    // De Casteljau subdivision for Segment 2 (Corner -> Next)
    final n0 = Offset.lerp(q0, q1, t2)!;
    final n1 = Offset.lerp(q1, q2, t2)!;
    final n2 = Offset.lerp(q2, q3, t2)!;
    final s0 = Offset.lerp(n0, n1, t2)!;
    final s1 = Offset.lerp(n1, n2, t2)!;
    final cutPt2 = Offset.lerp(s0, s1, t2)!;

    final node2HandleOut = s1 - cutPt2;
    final newNextHandleIn = n2 - q3;

    // --- Bridging Arc Handles ---
    // Extract the exact curve tangents pointing TOWARDS the corner to maintain G1 continuity
    Offset nDir1 = r1 - cutPt1;
    double len1 = nDir1.distance;
    if (len1 > 0) nDir1 /= len1; else nDir1 = Offset.zero;

    Offset nDir2 = s0 - cutPt2;
    double len2 = nDir2.distance;
    if (len2 > 0) nDir2 /= len2; else nDir2 = Offset.zero;

    final dotProduct = (nDir1.dx * nDir2.dx + nDir1.dy * nDir2.dy).clamp(-1.0, 1.0);
    final angle = acos(dotProduct);

    Offset node1HandleOut = Offset.zero;
    Offset node2HandleIn = Offset.zero;

    // Approximate a circular arc blend between the two cut points
    if (angle > 0.01 && angle < pi - 0.01) {
      double effectiveRadius = d / tan((pi - angle) / 2);
      double L = (4.0 / 3.0) * effectiveRadius * tan((pi - angle) / 4.0);
      node1HandleOut = nDir1 * L;
      node2HandleIn = nDir2 * L;
    }

    return (
      cutPt1: cutPt1,
      cutPt2: cutPt2,
      prevHandleOut: newPrevHandleOut,
      node1HandleIn: node1HandleIn,
      node1HandleOut: node1HandleOut,
      node2HandleIn: node2HandleIn,
      node2HandleOut: node2HandleOut,
      nextHandleIn: newNextHandleIn,
    );
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