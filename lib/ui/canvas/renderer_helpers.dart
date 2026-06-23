// lib/ui/canvas/renderer_helpers.dart

import 'dart:math';
import 'package:flutter/material.dart';

import '../../models/geometry/spline.dart';

class RendererHelpers {
  /// Draws a dashed line between two points. Scale-aware to keep dashes consistent.
  static void drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint, double invScale) {
    final double dashWidth = 6.0 * invScale;
    final double dashSpace = 6.0 * invScale;
    double distance = (p2 - p1).distance;
    if (distance == 0) return; 

    double dx = (p2.dx - p1.dx) / distance;
    double dy = (p2.dy - p1.dy) / distance;
    
    double currentDistance = 0;
    while (currentDistance < distance) {
      double nextDistance = currentDistance + dashWidth;
      if (nextDistance > distance) nextDistance = distance;
      canvas.drawLine(
        Offset(p1.dx + dx * currentDistance, p1.dy + dy * currentDistance),
        Offset(p1.dx + dx * nextDistance, p1.dy + dy * nextDistance),
        paint,
      );
      currentDistance += dashWidth + dashSpace;
    }
  }

  /// Draws the diamond-shaped handles for editing Variable Width profiles (W Key).
  static void drawWidthHandles(
    Canvas canvas, 
    CompassXSpline spline, 
    double invScale, 
    Color pointBorderColor,
    CompassSplineNode? activeWidthNode,
    bool activeWidthIsLeft,
  ) {
    final controls = spline.getEvaluatedControls();
    int n = spline.nodes.length;
    
    final guideLinePaint = Paint()
      ..color = Colors.tealAccent.withOpacity(0.3)
      ..strokeWidth = 1.0 * invScale
      ..style = PaintingStyle.stroke;

    final linePaint = Paint()
      ..color = Colors.tealAccent.withOpacity(0.8)
      ..strokeWidth = 1.5 * invScale
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.teal
      ..style = PaintingStyle.fill;
      
    final activeFillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = pointBorderColor
      ..strokeWidth = 1.0 * invScale
      ..style = PaintingStyle.stroke;

    void drawDiamond(Offset center, bool isActive, bool isPinned) { 
      final size = isActive ? 8.0 * invScale : 6.0 * invScale;
      final path = Path()
        ..moveTo(center.dx, center.dy - size)
        ..lineTo(center.dx + size, center.dy)
        ..lineTo(center.dx, center.dy + size)
        ..lineTo(center.dx - size, center.dy)
        ..close();
        
      if (isPinned) {
        if (isActive) {
          canvas.drawPath(path, Paint()..color = Colors.white..style = PaintingStyle.fill);
          canvas.drawPath(path, Paint()..color = Colors.orangeAccent..strokeWidth = 2.0 * invScale..style = PaintingStyle.stroke);
        } else {
          canvas.drawPath(path, Paint()..color = Colors.orangeAccent..style = PaintingStyle.fill);
          canvas.drawPath(path, Paint()..color = pointBorderColor..strokeWidth = 1.0 * invScale..style = PaintingStyle.stroke);
        }
      } else {
        if (isActive) {
          canvas.drawPath(path, activeFillPaint);
          canvas.drawPath(path, Paint()..color = Colors.teal..strokeWidth = 2.0 * invScale..style = PaintingStyle.stroke);
        } else {
          canvas.drawPath(path, dotPaint);
          canvas.drawPath(path, borderPaint);
        }
      }
    }

    for (int i = 0; i < n; i++) {
      final node = spline.nodes[i];
      final pt = Offset(node.point.x.value, node.point.y.value);
      
      Offset prevPt = spline.isClosed ? Offset(spline.nodes[(i - 1 + n) % n].point.x.value, spline.nodes[(i - 1 + n) % n].point.y.value) : (i > 0 ? Offset(spline.nodes[i - 1].point.x.value, spline.nodes[i - 1].point.y.value) : pt);
      Offset nextPt = spline.isClosed ? Offset(spline.nodes[(i + 1) % n].point.x.value, spline.nodes[(i + 1) % n].point.y.value) : (i < n - 1 ? Offset(spline.nodes[i + 1].point.x.value, spline.nodes[i + 1].point.y.value) : pt);

      final hOut = controls[i].$1;
      final hIn = controls[i].$2;

      Offset vOut = hOut;
      if (vOut.distance < 0.001) vOut = nextPt - pt;
      Offset vIn = Offset(-hIn.dx, -hIn.dy);
      if (vIn.distance < 0.001) vIn = pt - prevPt;

      if (!spline.isClosed) {
        if (i == 0) vIn = vOut;
        if (i == n - 1) vOut = vIn;
      }

      double lenOut = vOut.distance;
      double lenIn = vIn.distance;
      Offset tOut = lenOut > 0.001 ? vOut / lenOut : Offset.zero;
      Offset tIn = lenIn > 0.001 ? vIn / lenIn : Offset.zero;

      Offset T = tIn + tOut;
      double lenT = T.distance;
      if (lenT > 0.001) T = T / lenT; else T = tOut;
      
      Offset N = Offset(-T.dy, T.dx);

      // Faint normal guide lines extending from center (at least 30px so you can always see the axis)
      final leftGuide = pt + N * max(30.0 * invScale, node.widthLeft.value);
      final rightGuide = pt - N * max(30.0 * invScale, node.widthRight.value);
      
      canvas.drawLine(pt, leftGuide, guideLinePaint);
      canvas.drawLine(pt, rightGuide, guideLinePaint);

      final leftActual = pt + N * node.widthLeft.value;
      final rightActual = pt - N * node.widthRight.value;
      
      // Dashed line explicitly from the center outward to each handle
      if (node.widthLeft.value > 0.1) {
        drawDashedLine(canvas, pt, leftActual, linePaint, invScale);
      }
      if (node.widthRight.value > 0.1) {
        drawDashedLine(canvas, pt, rightActual, linePaint, invScale);
      }
      
      drawDiamond(leftActual, node == activeWidthNode && activeWidthIsLeft, node.isLeftWidthPinned); 
      drawDiamond(rightActual, node == activeWidthNode && !activeWidthIsLeft, node.isRightWidthPinned); 
    }
  }

  /// Draws the explicit bezier handles (circles) for a curve vertex.
  static void drawBezierHandles(
    Canvas canvas, 
    CompassXSpline spline, 
    double invScale, 
    Color pointBorderColor,
    CompassSplineNode? activeHandleNode,
    bool activeHandleIsOut,
  ) {
    final linePaint = Paint()
      ..color = Colors.purpleAccent.withOpacity(0.6)
      ..strokeWidth = 1.5 * invScale
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.purpleAccent
      ..style = PaintingStyle.fill;

    final dotBorderPaint = Paint()
      ..color = pointBorderColor
      ..strokeWidth = 1.0 * invScale
      ..style = PaintingStyle.stroke;

    final activeFillPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final activeBorderPaint = Paint()
      ..color = Colors.purpleAccent
      ..strokeWidth = 2.0 * invScale
      ..style = PaintingStyle.stroke;

    void drawDot(Offset dot, bool isActive) {
      if (isActive) {
        canvas.drawCircle(dot, 9.0 * invScale, activeFillPaint);
        canvas.drawCircle(dot, 9.0 * invScale, activeBorderPaint);
      } else {
        canvas.drawCircle(dot, 7.0 * invScale, dotPaint);
        canvas.drawCircle(dot, 7.0 * invScale, dotBorderPaint);
      }
    }

    for (var node in spline.nodes) {
      if (node.handleIn == null && node.handleOut == null) continue;

      final anchor = Offset(node.point.x.value, node.point.y.value);
      final t = node.tension.value;

      if (node.handleOut != null) {
        final dot = Offset(
          anchor.dx + node.handleOut!.dx * t,
          anchor.dy + node.handleOut!.dy * t,
        );
        canvas.drawLine(anchor, dot, linePaint);
        drawDot(dot, node == activeHandleNode && activeHandleIsOut);
      }

      if (node.handleIn != null) {
        final dot = Offset(
          anchor.dx + node.handleIn!.dx * t,
          anchor.dy + node.handleIn!.dy * t,
        );
        canvas.drawLine(anchor, dot, linePaint);
        drawDot(dot, node == activeHandleNode && !activeHandleIsOut);
      }
    }
  }

  /// Draws the dashed, corner-ticked bounding box around a 2+ selection.
  static void drawSelectionBounds(Canvas canvas, Rect bounds, double invScale) {
    final pad = 10.0 * invScale;
    final box = bounds.inflate(pad);

    final boxPaint = Paint()
      ..color = Colors.orangeAccent.withOpacity(0.9)
      ..strokeWidth = 1.5 * invScale
      ..style = PaintingStyle.stroke;

    // Dashed perimeter
    final tl = box.topLeft;
    final tr = box.topRight;
    final br = box.bottomRight;
    final bl = box.bottomLeft;
    drawDashedLine(canvas, tl, tr, boxPaint, invScale);
    drawDashedLine(canvas, tr, br, boxPaint, invScale);
    drawDashedLine(canvas, br, bl, boxPaint, invScale);
    drawDashedLine(canvas, bl, tl, boxPaint, invScale);

    // Solid corner ticks -- short right-angle marks at each corner.
    final tickPaint = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 2.0 * invScale
      ..style = PaintingStyle.stroke;
    final t = 8.0 * invScale; // tick arm length

    // Top-left
    canvas.drawLine(tl, tl + Offset(t, 0), tickPaint);
    canvas.drawLine(tl, tl + Offset(0, t), tickPaint);
    // Top-right
    canvas.drawLine(tr, tr + Offset(-t, 0), tickPaint);
    canvas.drawLine(tr, tr + Offset(0, t), tickPaint);
    // Bottom-right
    canvas.drawLine(br, br + Offset(-t, 0), tickPaint);
    canvas.drawLine(br, br + Offset(0, -t), tickPaint);
    // Bottom-left
    canvas.drawLine(bl, bl + Offset(t, 0), tickPaint);
    canvas.drawLine(bl, bl + Offset(0, -t), tickPaint);
  }

  /// Draws the curve-aware preview of the fillet while F is held.
  static void drawFilletPreview(Canvas canvas, CompassXSpline spline, CompassSplineNode node, double cutDistance, double invScale) {
    final fillet = spline.computeFillet(node, cutDistance);
    if (fillet == null) return;

    int index = spline.nodes.indexOf(node);
    int prevIndex = (index - 1 + spline.nodes.length) % spline.nodes.length;
    int nextIndex = (index + 1) % spline.nodes.length;

    final pPrev = Offset(spline.nodes[prevIndex].point.x.value, spline.nodes[prevIndex].point.y.value);
    final pCurr = Offset(node.point.x.value, node.point.y.value);
    final pNext = Offset(spline.nodes[nextIndex].point.x.value, spline.nodes[nextIndex].point.y.value);

    final previewPath = Path();
    
    // Draw from Prev to Cut1
    previewPath.moveTo(pPrev.dx, pPrev.dy);
    previewPath.cubicTo(
      pPrev.dx + fillet.prevHandleOut.dx, pPrev.dy + fillet.prevHandleOut.dy,
      fillet.cutPt1.dx + fillet.node1HandleIn.dx, fillet.cutPt1.dy + fillet.node1HandleIn.dy,
      fillet.cutPt1.dx, fillet.cutPt1.dy,
    );
    
    // Draw the Bridging Arc (Cut1 to Cut2)
    previewPath.cubicTo(
      fillet.cutPt1.dx + fillet.node1HandleOut.dx, fillet.cutPt1.dy + fillet.node1HandleOut.dy,
      fillet.cutPt2.dx + fillet.node2HandleIn.dx, fillet.cutPt2.dy + fillet.node2HandleIn.dy,
      fillet.cutPt2.dx, fillet.cutPt2.dy,
    );
    
    // Draw from Cut2 to Next
    previewPath.cubicTo(
      fillet.cutPt2.dx + fillet.node2HandleOut.dx, fillet.cutPt2.dy + fillet.node2HandleOut.dy,
      pNext.dx + fillet.nextHandleIn.dx, pNext.dy + fillet.nextHandleIn.dy,
      pNext.dx, pNext.dy,
    );

    final linePaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 3.0 * invScale
      ..style = PaintingStyle.stroke;
      
    final scissorPaint = Paint()
      ..color = Colors.redAccent.withOpacity(0.5)
      ..strokeWidth = 2.0 * invScale
      ..style = PaintingStyle.stroke;

    canvas.drawPath(previewPath, linePaint);
    
    drawDashedLine(canvas, fillet.cutPt1, pCurr, scissorPaint, invScale);
    drawDashedLine(canvas, pCurr, fillet.cutPt2, scissorPaint, invScale);

    final nodePaint = Paint()..color = Colors.greenAccent..style = PaintingStyle.fill;
    canvas.drawCircle(fillet.cutPt1, 6.0 * invScale, nodePaint);
    canvas.drawCircle(fillet.cutPt2, 6.0 * invScale, nodePaint);
  }
}