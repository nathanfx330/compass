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

  // Variable width properties for calligraphy / first-class area strokes.
  // Represents the physical distance pushed out along the normal vector.
  final ValueNotifier<double> widthLeft;
  final ValueNotifier<double> widthRight;

  CompassSplineNode({
    required this.point, 
    double tension = 1.0, 
    this.handleIn, 
    this.handleOut,
    double widthLeft = 0.0,
    double widthRight = 0.0,
  }) : tension = ValueNotifier(tension),
       widthLeft = ValueNotifier(widthLeft),
       widthRight = ValueNotifier(widthRight);
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

  // Returns true if any node has a width applied, triggering the area-stroke math
  bool get hasWidthProfile => nodes.any((n) => n.widthLeft.value > 0.01 || n.widthRight.value > 0.01);

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

  (int, double) getInsertDetailsForOffset(Offset tap) {
    if (nodes.length < 2) return (nodes.length, 0.0);
    
    double minDist = double.infinity;
    int bestIndex = 1; 
    double bestT = 0.5;
    
    int loopCount = isClosed ? nodes.length : nodes.length - 1;
    
    for (int i = 0; i < loopCount; i++) {
      final p1 = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
      final p2 = Offset(nodes[(i + 1) % nodes.length].point.x.value, nodes[(i + 1) % nodes.length].point.y.value);
      
      final l2 = (p2.dx - p1.dx) * (p2.dx - p1.dx) + (p2.dy - p1.dy) * (p2.dy - p1.dy);
      double t = 0;
      if (l2 != 0) {
        t = ((tap.dx - p1.dx) * (p2.dx - p1.dx) + (tap.dy - p1.dy) * (p2.dy - p1.dy)) / l2;
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
    
    if (bestIndex == 0 && isClosed) return (nodes.length, bestT);
    return (bestIndex, bestT);
  }

  List<(Offset, Offset)> getEvaluatedControls() {
    List<(Offset, Offset)> controls = [];
    for (int i = 0; i < nodes.length; i++) {
      final current = nodes[i];
      final tension = current.tension.value;
      
      Offset? hOut = current.handleOut;
      Offset? hIn = current.handleIn;

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

      controls.add((
        hOut != null ? hOut * tension : Offset(tangent.dx / 3, tangent.dy / 3),
        hIn != null ? hIn * tension : Offset(-tangent.dx / 3, -tangent.dy / 3)
      ));
    }
    return controls;
  }

  // --- Exposed to the renderer so we don't have to duplicate normal math ---
  List<Offset> calculateNormals(List<(Offset, Offset)> controls) {
    final normals = <Offset>[];
    int n = nodes.length;
    for (int i = 0; i < n; i++) {
      final pt = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
      
      Offset prevPt;
      if (isClosed) {
        prevPt = Offset(nodes[(i - 1 + n) % n].point.x.value, nodes[(i - 1 + n) % n].point.y.value);
      } else {
        prevPt = i > 0 ? Offset(nodes[i - 1].point.x.value, nodes[i - 1].point.y.value) : pt;
      }

      Offset nextPt;
      if (isClosed) {
        nextPt = Offset(nodes[(i + 1) % n].point.x.value, nodes[(i + 1) % n].point.y.value);
      } else {
        nextPt = i < n - 1 ? Offset(nodes[i + 1].point.x.value, nodes[i + 1].point.y.value) : pt;
      }

      final hOut = controls[i].$1;
      final hIn = controls[i].$2;

      Offset vOut = hOut;
      if (vOut.distance < 0.001) vOut = nextPt - pt;
      
      Offset vIn = Offset(-hIn.dx, -hIn.dy);
      if (vIn.distance < 0.001) vIn = pt - prevPt;

      if (!isClosed) {
        if (i == 0) vIn = vOut;
        if (i == n - 1) vOut = vIn;
      }

      double lenOut = vOut.distance;
      double lenIn = vIn.distance;
      
      Offset tOut = lenOut > 0.001 ? vOut / lenOut : Offset.zero;
      Offset tIn = lenIn > 0.001 ? vIn / lenIn : Offset.zero;

      Offset T = tIn + tOut;
      double lenT = T.distance;
      if (lenT > 0.001) {
        T = T / lenT;
      } else {
        T = tOut; 
      }

      // The Normal is exactly 90 degrees Counter-Clockwise from the Tangent
      normals.add(Offset(-T.dy, T.dx));
    }
    return normals;
  }

  // --- Extracts pure 1D center spine ---
  Path getCenterPath() {
    final path = Path();
    if (nodes.isEmpty) return path;

    final controls = getEvaluatedControls();
    int n = nodes.length;
    int loopCount = isClosed ? n : n - 1;

    final startOffset = Offset(nodes[0].point.x.value, nodes[0].point.y.value);
    path.moveTo(startOffset.dx, startOffset.dy);

    if (n == 1) return path;

    for (int i = 0; i < loopCount; i++) {
      final pt0 = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
      final pt1 = Offset(nodes[(i + 1) % n].point.x.value, nodes[(i + 1) % n].point.y.value);
      
      final hOut = controls[i].$1;
      final hIn = controls[(i + 1) % n].$2;

      final cp1 = pt0 + hOut;
      final cp2 = pt1 + hIn;

      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, pt1.dx, pt1.dy);
    }
    
    if (isClosed) path.close();
    return path;
  }

  @override
  Path getPath() {
    if (!hasWidthProfile) {
      return getCenterPath()..fillType = PathFillType.evenOdd;
    }

    final path = Path();
    path.fillType = PathFillType.evenOdd;
    
    final controls = getEvaluatedControls();
    final normals = calculateNormals(controls);
    int n = nodes.length;
    int loopCount = isClosed ? n : n - 1;

    final leftPts = <Offset>[];
    final rightPts = <Offset>[];

    for (int i = 0; i < n; i++) {
      final pt = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
      final N = normals[i];
      leftPts.add(pt + N * nodes[i].widthLeft.value);
      rightPts.add(pt - N * nodes[i].widthRight.value);
    }

    // Trace the Forward (Left) Boundary
    path.moveTo(leftPts[0].dx, leftPts[0].dy);
    for (int i = 0; i < loopCount; i++) {
      final nextIdx = (i + 1) % n;
      final cp1 = leftPts[i] + controls[i].$1;
      final cp2 = leftPts[nextIdx] + controls[nextIdx].$2;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, leftPts[nextIdx].dx, leftPts[nextIdx].dy);
    }

    if (isClosed) {
      path.close(); // Close the Outer/Left contour
      
      // Trace the Inner/Right Boundary BACKWARD so boolean union honors the hole
      path.moveTo(rightPts[0].dx, rightPts[0].dy);
      for (int i = n; i > 0; i--) {
        final currIdx = i % n;
        final prevIdx = i - 1;
        final cp1 = rightPts[currIdx] + controls[currIdx].$2;
        final cp2 = rightPts[prevIdx] + controls[prevIdx].$1;
        path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, rightPts[prevIdx].dx, rightPts[prevIdx].dy);
      }
      path.close(); 
    } else {
      // Forward Endcap: Perfect semi-circle from Left -> Right
      final endRadius = (leftPts[n - 1] - rightPts[n - 1]).distance / 2.0;
      if (endRadius > 0.001) {
        path.arcToPoint(
          rightPts[n - 1],
          radius: Radius.circular(endRadius),
          clockwise: false, // <--- FIXED: Outward bulge in Flutter space
        );
      } else {
        path.lineTo(rightPts[n - 1].dx, rightPts[n - 1].dy);
      }
      
      // Trace Backward (Right) Boundary
      for (int i = n - 1; i > 0; i--) {
        final prevIdx = i - 1;
        final cp1 = rightPts[i] + controls[i].$2; 
        final cp2 = rightPts[prevIdx] + controls[prevIdx].$1; 
        path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, rightPts[prevIdx].dx, rightPts[prevIdx].dy);
      }
      
      // Start Endcap: Perfect semi-circle from Right -> Left
      final startRadius = (rightPts[0] - leftPts[0]).distance / 2.0;
      if (startRadius > 0.001) {
        path.arcToPoint(
          leftPts[0],
          radius: Radius.circular(startRadius),
          clockwise: false, // <--- FIXED: Outward bulge in Flutter space
        );
      } else {
        path.lineTo(leftPts[0].dx, leftPts[0].dy);
      }
      path.close(); 
    }

    return path;
  }

  // --- Centerline as an SVG path string (the 1D spine, ignoring any width
  // profile) --- the string counterpart of getCenterPath(), exactly as
  // getSvgPathData()'s non-width branch always emitted. Pulled out so the SVG
  // exporter can draw a CLOSED width spline's inner fill from its centerline
  // while getSvgPathData() still returns the ribbon outline for the same shape.
  // For a non-width spline this IS the whole shape, so getSvgPathData() below
  // simply forwards to it -- one home for the centerline math.
  String getCenterSvgPathData() {
    if (nodes.isEmpty) return "";
    final buffer = StringBuffer();
    final controls = getEvaluatedControls();
    int n = nodes.length;
    int loopCount = isClosed ? n : n - 1;

    final start = Offset(nodes[0].point.x.value, nodes[0].point.y.value);
    buffer.write('M ${start.dx} ${start.dy} ');

    if (nodes.length > 1) {
      for (int i = 0; i < loopCount; i++) {
        final pt0 = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
        final pt1 = Offset(nodes[(i + 1) % n].point.x.value, nodes[(i + 1) % n].point.y.value);

        final cp1 = pt0 + controls[i].$1;
        final cp2 = pt1 + controls[(i + 1) % n].$2;

        buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${pt1.dx} ${pt1.dy} ');
      }
    }
    if (isClosed) buffer.write('Z');
    return buffer.toString().trim();
  }

  String getSvgPathData() {
    if (nodes.isEmpty) return "";

    // No width profile -> the shape IS its centerline.
    if (!hasWidthProfile) {
      return getCenterSvgPathData();
    }

    final buffer = StringBuffer();
    final controls = getEvaluatedControls();
    int n = nodes.length;
    int loopCount = isClosed ? n : n - 1;

    // SVG Outline Export
    final normals = calculateNormals(controls);
    final leftPts = <Offset>[];
    final rightPts = <Offset>[];

    for (int i = 0; i < n; i++) {
      final pt = Offset(nodes[i].point.x.value, nodes[i].point.y.value);
      final N = normals[i];
      leftPts.add(pt + N * nodes[i].widthLeft.value);
      rightPts.add(pt - N * nodes[i].widthRight.value);
    }

    // Left Boundary
    buffer.write('M ${leftPts[0].dx} ${leftPts[0].dy} ');
    for (int i = 0; i < loopCount; i++) {
      final nextIdx = (i + 1) % n;
      final cp1 = leftPts[i] + controls[i].$1;
      final cp2 = leftPts[nextIdx] + controls[nextIdx].$2;
      buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${leftPts[nextIdx].dx} ${leftPts[nextIdx].dy} ');
    }

    if (isClosed) {
      buffer.write('Z ');
      // Trace Inner/Right Boundary BACKWARD so boolean union honors the hole
      buffer.write('M ${rightPts[0].dx} ${rightPts[0].dy} ');
      for (int i = n; i > 0; i--) {
        final currIdx = i % n;
        final prevIdx = i - 1;
        final cp1 = rightPts[currIdx] + controls[currIdx].$2;
        final cp2 = rightPts[prevIdx] + controls[prevIdx].$1;
        buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${rightPts[prevIdx].dx} ${rightPts[prevIdx].dy} ');
      }
      buffer.write('Z');
    } else {
      // Forward Semicircle Endcap (SVG 'A' command, counter-clockwise 0 0 0)
      final endRadius = (leftPts[n - 1] - rightPts[n - 1]).distance / 2.0;
      if (endRadius > 0.001) {
        buffer.write('A $endRadius $endRadius 0 0 0 ${rightPts[n - 1].dx} ${rightPts[n - 1].dy} ');
      } else {
        buffer.write('L ${rightPts[n - 1].dx} ${rightPts[n - 1].dy} ');
      }

      for (int i = n - 1; i > 0; i--) {
        final prevIdx = i - 1;
        final cp1 = rightPts[i] + controls[i].$2; 
        final cp2 = rightPts[prevIdx] + controls[prevIdx].$1; 
        buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${rightPts[prevIdx].dx} ${rightPts[prevIdx].dy} ');
      }

      // Start Semicircle Endcap (counter-clockwise 0 0 0)
      final startRadius = (rightPts[0] - leftPts[0]).distance / 2.0;
      if (startRadius > 0.001) {
        buffer.write('A $startRadius $startRadius 0 0 0 ${leftPts[0].dx} ${leftPts[0].dy} ');
      } else {
        buffer.write('L ${leftPts[0].dx} ${leftPts[0].dy} ');
      }
      buffer.write('Z');
    }

    return buffer.toString().trim();
  }

  @override
  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false}) {
    // Note: If drawing wireframe/scaffolding, draw the true mathematical area so
    // the user can see exactly what boolean geometry is being output.
    canvas.drawPath(getPath(), paint);

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
        
        canvas.drawLine(pt, handlePt, scaffoldLinePaint);
        
        final handleRect = Rect.fromCenter(center: handlePt, width: 10, height: 10);
        canvas.drawRect(handleRect, boxStrokePaint);
        
        final tensionFillPaint = Paint()
          ..color = Colors.blue.withOpacity(node.tension.value.clamp(0.0, 1.0))
          ..style = PaintingStyle.fill;
        canvas.drawRect(handleRect, tensionFillPaint);
      }
    }
  }
}