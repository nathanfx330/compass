// lib/models/geometry/spline.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'point.dart';
import 'shape.dart';
import 'stroke_outline.dart';

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
  final ValueNotifier<double> tension;

  Offset? handleIn;
  Offset? handleOut;

  final ValueNotifier<double> widthLeft;
  final ValueNotifier<double> widthRight;

  bool isLeftWidthPinned;
  bool isRightWidthPinned;

  final ValueNotifier<double> cornerRadius;
  final ValueNotifier<double> miterSize;

  CompassSplineNode({
    required this.point, 
    double tension = 1.0, 
    this.handleIn, 
    this.handleOut,
    double widthLeft = 0.0,
    double widthRight = 0.0,
    this.isLeftWidthPinned = false,
    this.isRightWidthPinned = false,
    double cornerRadius = 0.0,
    double miterSize = 0.0,
  }) : tension = ValueNotifier(tension),
       widthLeft = ValueNotifier(widthLeft),
       widthRight = ValueNotifier(widthRight),
       cornerRadius = ValueNotifier(cornerRadius),
       miterSize = ValueNotifier(miterSize);
}

class ResolvedSplineNode {
  final Offset point;
  Offset hIn;
  Offset hOut;
  final double widthLeft;
  final double widthRight;
  final int rawIndex;

  ResolvedSplineNode({
    required this.point,
    required this.hIn,
    required this.hOut,
    required this.widthLeft,
    required this.widthRight,
    required this.rawIndex,
  });
}

class CompassXSpline extends CompassShape {
  final List<CompassSplineNode> nodes = [];
  bool isClosed;
  CompassPoint? anchorPoint;

  // Shared spline geometry caches. A single render revision can ask for the
  // resolved pulley nodes, center path, visible ribbon, SVG data, hit testing,
  // and several stroke dilations. Previously each request rebuilt the full
  // tension/pulley solution independently.
  int? _pathCacheGeometryHash;
  List<ResolvedSplineNode>? _resolvedNodesCache;
  Path? _centerPathCache;
  Path? _visiblePathCache;

  int? _strokeCacheGeometryHash;
  bool? _strokeCacheInteractive;
  StrokeOutlineGeometry? _preparedStrokeGeometry;
  final Map<double, Path> _strokeDilationCache = {};
  final Map<(double, double), Path> _strokeOutlineCache = {};

  CompassXSpline({
    this.isClosed = false,
    this.anchorPoint,
    super.operation,
    super.strokeRegions,
    super.isVisible,
  });

  void addNode(CompassSplineNode node) {
    nodes.add(node);
  }

  bool get hasWidthProfile => nodes.any((n) => n.widthLeft.value > 0.01 || n.widthRight.value > 0.01);

  int _strokeGeometryHash() {
    var hash = Object.hash(isClosed, nodes.length);
    for (final node in nodes) {
      hash = Object.hash(
        hash,
        node.point.x.value,
        node.point.y.value,
        node.tension.value,
        node.widthLeft.value,
        node.widthRight.value,
        node.cornerRadius.value,
        node.miterSize.value,
      );
      hash = Object.hash(
        hash,
        node.handleIn?.dx,
        node.handleIn?.dy,
        node.handleOut?.dx,
        node.handleOut?.dy,
      );
    }
    return hash;
  }

  int _syncPathCaches() {
    final hash = _strokeGeometryHash();
    if (_pathCacheGeometryHash != hash) {
      _pathCacheGeometryHash = hash;
      _resolvedNodesCache = null;
      _centerPathCache = null;
      _visiblePathCache = null;
    }
    return hash;
  }

  FilletData? computeFillet(CompassSplineNode node, double cutDistance) {
    int index = nodes.indexOf(node);
    if (index == -1) return null;

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

    final d1 = (p3 - p0).distance;
    final d2 = (q3 - q0).distance;

    if (d1 < 0.001 || d2 < 0.001) return null;

    double d = cutDistance;
    final maxD = min(d1, d2) * 0.5;
    if (d > maxD) d = maxD;
    if (d <= 0.1) return null; 

    final t1 = 1.0 - (d / d1);
    final t2 = (d / d2);

    final m0 = Offset.lerp(p0, p1, t1)!;
    final m1 = Offset.lerp(p1, p2, t1)!;
    final m2 = Offset.lerp(p2, p3, t1)!;
    final r0 = Offset.lerp(m0, m1, t1)!;
    final r1 = Offset.lerp(m1, m2, t1)!;
    final cutPt1 = Offset.lerp(r0, r1, t1)!;

    final newPrevHandleOut = m0 - p0;
    final node1HandleIn = r0 - cutPt1;

    final n0 = Offset.lerp(q0, q1, t2)!;
    final n1 = Offset.lerp(q1, q2, t2)!;
    final n2 = Offset.lerp(q2, q3, t2)!;
    final s0 = Offset.lerp(n0, n1, t2)!;
    final s1 = Offset.lerp(n1, n2, t2)!;
    final cutPt2 = Offset.lerp(s0, s1, t2)!;

    final node2HandleOut = s1 - cutPt2;
    final newNextHandleIn = n2 - q3;

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
    final resolved = getResolvedNodes();
    if (resolved.length < 2) return (nodes.length, 0.0);
    
    double minDist = double.infinity;
    int bestRawIndex = 1; 
    double bestT = 0.5;
    
    int loopCount = isClosed ? resolved.length : resolved.length - 1;
    
    for (int j = 0; j < loopCount; j++) {
      final r1 = resolved[j];
      final r2 = resolved[(j + 1) % resolved.length];
      
      final p1 = r1.point;
      final p2 = r2.point;
      
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
        bestRawIndex = (r1.rawIndex + 1) % nodes.length;
        if (bestRawIndex == 0 && !isClosed) bestRawIndex = nodes.length; 
        bestT = t;
      }
    }
    
    if (bestRawIndex == 0 && isClosed) return (nodes.length, bestT);
    return (bestRawIndex, bestT);
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

  // --- Dynamic Pulley Constraints: round (cornerRadius) and sharp/miter (miterSize) ---
  List<ResolvedSplineNode> _buildResolvedNodes() {
    final controls = getEvaluatedControls();
    final n = nodes.length;
    
    final resolvedBase = List<ResolvedSplineNode>.generate(n, (i) => ResolvedSplineNode(
      point: Offset(nodes[i].point.x.value, nodes[i].point.y.value),
      hIn: controls[i].$2,
      hOut: controls[i].$1,
      widthLeft: nodes[i].widthLeft.value,
      widthRight: nodes[i].widthRight.value,
      rawIndex: i,
    ));

    if (n < 2) return resolvedBase;

    // --- Effective peg-radius table (the fix for adjacent pulleys) ---
    // Each node's effective peg radius: the active pulley size (round
    // cornerRadius, else sharp miterSize, else 0), clamped ONCE here to 0.99 of
    // its shorter incident raw edge. Open-spline endpoints carry no peg (0), and
    // a node with no pulley is 0.
    //
    // This table is what makes a pulley and its NEIGHBOR agree on the tangent of
    // the edge they share. Each pulley below builds its entry/exit tangent as the
    // common EXTERNAL tangent to the neighbor's peg via acos((R - R_neighbor)/d).
    // When the neighbor is a bare vertex (R_neighbor == 0) this is exactly the old
    // acos(R/d), so plain-neighbor behavior is unchanged. When the neighbor is
    // itself a peg (round or miter), both ends derive the SAME common tangent
    // line, so the straight seam between them lands ON that line instead of the
    // arc over-wrapping toward where a bare-vertex tangent would have sat.
    final effR = List<double>.filled(n, 0.0);
    for (int i = 0; i < n; i++) {
      final bool canPulley = isClosed || (i > 0 && i < n - 1);
      if (!canPulley) continue;
      final double raw = nodes[i].cornerRadius.value > 0.01
          ? nodes[i].cornerRadius.value
          : (nodes[i].miterSize.value > 0.01 ? nodes[i].miterSize.value : 0.0);
      if (raw <= 0.0) continue;
      final prevIdx = (i - 1 + n) % n;
      final nextIdx = (i + 1) % n;
      final dA = (resolvedBase[prevIdx].point - resolvedBase[i].point).distance;
      final dC = (resolvedBase[nextIdx].point - resolvedBase[i].point).distance;
      final maxR = min(dA, dC) * 0.99;
      effR[i] = raw > maxR ? maxR : raw;
    }

    final result = <ResolvedSplineNode>[];

    for(int i = 0; i < n; i++) {
       final node = nodes[i];
       
       if (node.cornerRadius.value > 0.01 && (isClosed || (i > 0 && i < n - 1))) {
          // ==============================
          // CIRCULAR PULLEY (Round Wrap)
          // ==============================
          int prevIdx = (i - 1 + n) % n;
          int nextIdx = (i + 1) % n;
          Offset pPrev = resolvedBase[prevIdx].point;
          Offset pCurr = resolvedBase[i].point;
          Offset pNext = resolvedBase[nextIdx].point;

          Offset vA = pPrev - pCurr;
          Offset vC = pNext - pCurr;
          double dA = vA.distance;
          double dC = vC.distance;

          if (dA < 0.001 || dC < 0.001) {
             result.add(resolvedBase[i]);
             continue;
          }

          double R = effR[i];

          double thetaA = atan2(vA.dy, vA.dx);
          double thetaC = atan2(vC.dy, vC.dx);

          // Common external tangent to each neighbor's peg (effR[neighbor] == 0
          // for a bare vertex -> reduces to acos(R/d)).
          double betaA = acos(((R - effR[prevIdx]) / dA).clamp(-1.0, 1.0));
          double betaC = acos(((R - effR[nextIdx]) / dC).clamp(-1.0, 1.0));

          double Z = vA.dx * vC.dy - vA.dy * vC.dx;
          double S = Z > 0 ? 1.0 : -1.0;

          double phiA = thetaA - S * betaA;
          double phiC = thetaC + S * betaC;

          double delta = phiC - phiA;
          if (S > 0) {
            while (delta > 0) delta -= 2 * pi;
          } else {
            while (delta < 0) delta += 2 * pi;
          }

          int N_arcs = (delta.abs() / (pi / 2)).ceil();
          if (N_arcs < 1) N_arcs = 1;
          double step = delta / N_arcs;
          double L = (4.0 / 3.0) * tan(step.abs() / 4.0) * R;

          List<ResolvedSplineNode> arcNodes = [];
          for (int k = 0; k <= N_arcs; k++) {
            double angle = phiA + k * step;
            Offset pt = pCurr + Offset(R * cos(angle), R * sin(angle));
            Offset tangentDir = Offset(-sin(angle), cos(angle)) * (step > 0 ? 1.0 : -1.0);
            
            Offset hIn = k == 0 ? Offset.zero : -tangentDir * L;
            Offset hOut = k == N_arcs ? Offset.zero : tangentDir * L;

            arcNodes.add(ResolvedSplineNode(
              point: pt, hIn: hIn, hOut: hOut,
              widthLeft: node.widthLeft.value, widthRight: node.widthRight.value,
              rawIndex: i,
            ));
          }

          if (result.isNotEmpty) {
             result.last.hOut = Offset.zero;
          } else if (isClosed) {
             resolvedBase[prevIdx].hOut = Offset.zero;
          }
          resolvedBase[nextIdx].hIn = Offset.zero;

          result.addAll(arcNodes);
          
       } else if (node.miterSize.value > 0.01 && (isClosed || (i > 0 && i < n - 1))) {
          // ============================================================
          // MITER PULLEY  (Sharp Wrap)
          // ============================================================
          // This is the circular pulley above with the round arc replaced
          // by a single SHARP apex. The rope still WRAPS around the OUTSIDE
          // of the corner -- it is not a cut into the shape -- it just comes
          // to a point instead of a curve.
          //
          // The tangent construction is byte-for-byte the circular pulley's
          // (thetaA/thetaC, betaA/betaC, Z/S, phiA/phiC), now including the
          // common-external-tangent neighbor term. That is deliberate: because
          // the round pulley already wraps on the correct (outer) side, reusing
          // its exact angle math guarantees the sharp version wraps on the SAME
          // side -- no winding-sign guesswork -- and a miter sitting next to a
          // round (or another miter) shares the same tangent line, so the seam
          // connects cleanly instead of over-wrapping.
          //
          // Geometry: picture a peg of radius R centered on the vertex. The
          // rope runs tangent to the peg, and the two tangent lines (one from
          // the incoming edge, one from the outgoing edge) meet at a single
          // sharp APEX out past the vertex, along the angular bisector of the
          // two tangent radii, at distance R / cos(halfWrap) -- the standard
          // miter point of two lines tangent to a circle. Because the apex
          // lies on BOTH tangent lines and pPrev lies on the first one, the
          // segment pPrev -> apex IS that tangent line; likewise apex -> pNext.
          // So a single relocated sharp corner carries the whole wrap -- no
          // separate tangent-point nodes are needed, and the rope leaves /
          // rejoins the edges exactly as the round pulley's rope does, pointed.
          //
          // As R grows the apex pushes outward and the approach lines deflect,
          // mirroring the round pulley's behavior.
          //
          // NOT YET (next pass, each needs a new node field):
          //   * SKEW -- lean the apex off the bisector to aim the tip and steer
          //     the in/out lines.
          //   * BALLPOINT -- round ONLY the apex (a small arc tangent to the two
          //     rope segments) so the tip is a rounded nub like a pen body,
          //     while the sides stay straight.
          int prevIdx = (i - 1 + n) % n;
          int nextIdx = (i + 1) % n;
          Offset pPrev = resolvedBase[prevIdx].point;
          Offset pCurr = resolvedBase[i].point;
          Offset pNext = resolvedBase[nextIdx].point;

          Offset vA = pPrev - pCurr;
          Offset vC = pNext - pCurr;
          double dA = vA.distance;
          double dC = vC.distance;

          if (dA < 0.001 || dC < 0.001) {
             result.add(resolvedBase[i]);
             continue;
          }

          double R = effR[i];

          // --- Tangent construction: IDENTICAL to the circular pulley. ---
          double thetaA = atan2(vA.dy, vA.dx);
          double thetaC = atan2(vC.dy, vC.dx);

          double betaA = acos(((R - effR[prevIdx]) / dA).clamp(-1.0, 1.0));
          double betaC = acos(((R - effR[nextIdx]) / dC).clamp(-1.0, 1.0));

          double Z = vA.dx * vC.dy - vA.dy * vC.dx;
          double S = Z > 0 ? 1.0 : -1.0;

          double phiA = thetaA - S * betaA;
          double phiC = thetaC + S * betaC;

          double delta = phiC - phiA;
          if (S > 0) {
            while (delta > 0) delta -= 2 * pi;
          } else {
            while (delta < 0) delta += 2 * pi;
          }

          // Bisector of the two tangent radii + miter distance R / cos(halfWrap)
          // = the sharp apex. Guard the cosine so a near-hairpin corner (wrap
          // approaching 180 degrees) can't shoot the apex to infinity -- cap the
          // miter length instead of dividing by ~0.
          double phiMid = phiA + delta / 2.0;
          double halfWrap = delta.abs() / 2.0;
          double cosHalf = cos(halfWrap);
          double mitreLen = cosHalf < 0.05 ? R * 20.0 : R / cosHalf;

          final Offset apex =
              pCurr + Offset(cos(phiMid), sin(phiMid)) * mitreLen;

          // Straight rope into and out of the sharp apex (mirrors the circular
          // pulley's handle zeroing): kill the previous node's hOut, the next
          // base node's hIn, and give the apex no handles so the tip is sharp.
          if (result.isNotEmpty) {
             result.last.hOut = Offset.zero;
          } else if (isClosed) {
             resolvedBase[prevIdx].hOut = Offset.zero;
          }
          resolvedBase[nextIdx].hIn = Offset.zero;

          result.add(ResolvedSplineNode(
            point: apex, hIn: Offset.zero, hOut: Offset.zero,
            widthLeft: node.widthLeft.value, widthRight: node.widthRight.value,
            rawIndex: i,
          ));
          
       } else {
          // Standard fluid vertex
          result.add(resolvedBase[i]);
       }
    }

    return result;
  }

  List<ResolvedSplineNode> getResolvedNodes() {
    _syncPathCaches();
    final cached = _resolvedNodesCache;
    if (cached != null) return cached;

    final resolved = _buildResolvedNodes();
    _resolvedNodesCache = resolved;
    return resolved;
  }

  // Calculate normals using the dynamically resolved virtual nodes
  List<Offset> calculateResolvedNormals(List<ResolvedSplineNode> resolved) {
    final normals = <Offset>[];
    int n = resolved.length;
    for (int i = 0; i < n; i++) {
      final pt = resolved[i].point;
      
      Offset prevPt = isClosed ? resolved[(i - 1 + n) % n].point : (i > 0 ? resolved[i - 1].point : pt);
      Offset nextPt = isClosed ? resolved[(i + 1) % n].point : (i < n - 1 ? resolved[i + 1].point : pt);

      Offset vOut = resolved[i].hOut;
      if (vOut.distance < 0.001) vOut = nextPt - pt;
      
      Offset vIn = Offset(-resolved[i].hIn.dx, -resolved[i].hIn.dy);
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

  // --- Extracts pure 1D center spine (using resolved nodes) ---
  Path _buildCenterPath() {
    final path = Path();
    if (nodes.isEmpty) return path;

    final resolvedNodes = getResolvedNodes();
    int n = resolvedNodes.length;
    int loopCount = isClosed ? n : n - 1;

    final startOffset = resolvedNodes[0].point;
    path.moveTo(startOffset.dx, startOffset.dy);

    if (n == 1) return path;

    for (int i = 0; i < loopCount; i++) {
      final pt0 = resolvedNodes[i].point;
      final pt1 = resolvedNodes[(i + 1) % n].point;
      
      final hOut = resolvedNodes[i].hOut;
      final hIn = resolvedNodes[(i + 1) % n].hIn;

      final cp1 = pt0 + hOut;
      final cp2 = pt1 + hIn;

      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, pt1.dx, pt1.dy);
    }
    
    if (isClosed) path.close();
    return path;
  }

  Path getCenterPath() {
    _syncPathCaches();
    final cached = _centerPathCache;
    if (cached != null) return cached;

    final path = _buildCenterPath();
    _centerPathCache = path;
    return path;
  }

  Path _buildVisiblePath() {
    if (!hasWidthProfile) {
      return getCenterPath()..fillType = PathFillType.evenOdd;
    }

    final path = Path();
    path.fillType = PathFillType.evenOdd;
    
    final resolvedNodes = getResolvedNodes();
    final normals = calculateResolvedNormals(resolvedNodes);
    int n = resolvedNodes.length;
    int loopCount = isClosed ? n : n - 1;

    final leftPts = <Offset>[];
    final rightPts = <Offset>[];

    for (int i = 0; i < n; i++) {
      final pt = resolvedNodes[i].point;
      final N = normals[i];
      leftPts.add(pt + N * resolvedNodes[i].widthLeft);
      rightPts.add(pt - N * resolvedNodes[i].widthRight);
    }

    // Trace the Forward (Left) Boundary
    path.moveTo(leftPts[0].dx, leftPts[0].dy);
    for (int i = 0; i < loopCount; i++) {
      final nextIdx = (i + 1) % n;
      final cp1 = leftPts[i] + resolvedNodes[i].hOut;
      final cp2 = leftPts[nextIdx] + resolvedNodes[nextIdx].hIn;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, leftPts[nextIdx].dx, leftPts[nextIdx].dy);
    }

    if (isClosed) {
      path.close(); // Close the Outer/Left contour
      
      // Trace the Inner/Right Boundary BACKWARD so boolean union honors the hole
      path.moveTo(rightPts[0].dx, rightPts[0].dy);
      for (int i = n; i > 0; i--) {
        final currIdx = i % n;
        final prevIdx = i - 1;
        final cp1 = rightPts[currIdx] + resolvedNodes[currIdx].hIn;
        final cp2 = rightPts[prevIdx] + resolvedNodes[prevIdx].hOut;
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
          clockwise: false, // Outward bulge in Flutter space
        );
      } else {
        path.lineTo(rightPts[n - 1].dx, rightPts[n - 1].dy);
      }
      
      // Trace Backward (Right) Boundary
      for (int i = n - 1; i > 0; i--) {
        final prevIdx = i - 1;
        final cp1 = rightPts[i] + resolvedNodes[i].hIn; 
        final cp2 = rightPts[prevIdx] + resolvedNodes[prevIdx].hOut; 
        path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, rightPts[prevIdx].dx, rightPts[prevIdx].dy);
      }
      
      // Start Endcap: Perfect semi-circle from Right -> Left
      final startRadius = (rightPts[0] - leftPts[0]).distance / 2.0;
      if (startRadius > 0.001) {
        path.arcToPoint(
          leftPts[0],
          radius: Radius.circular(startRadius),
          clockwise: false, 
        );
      } else {
        path.lineTo(leftPts[0].dx, leftPts[0].dy);
      }
      path.close(); 
    }

    return path;
  }

  @override
  Path getPath() {
    _syncPathCaches();
    final cached = _visiblePathCache;
    if (cached != null) return cached;

    final path = _buildVisiblePath();
    _visiblePathCache = path;
    return path;
  }

  /// Builds an outward stroke region around the spline's CURRENT visible
  /// silhouette. A variable-width spline therefore wraps its ribbon, including
  /// its asymmetric widths and round caps, rather than falling back to a constant
  /// centerline stroke. A closed zero-width spline is treated as a filled area; an
  /// open zero-width spline is treated as a round-capped centerline ribbon.
  @override
  Path getStrokeOutlinePath(double width, double innerOffset) {
    if (nodes.isEmpty || width <= 0) {
      return Path()..fillType = PathFillType.evenOdd;
    }

    final geometryHash = _strokeGeometryHash();
    final interactive = nodes.any((node) => node.point.isBeingDragged);
    if (_strokeCacheGeometryHash != geometryHash ||
        _strokeCacheInteractive != interactive) {
      _strokeCacheGeometryHash = geometryHash;
      _strokeCacheInteractive = interactive;
      _preparedStrokeGeometry = null;
      _strokeDilationCache.clear();
      _strokeOutlineCache.clear();
    }

    final key = (width, innerOffset);
    final cached = _strokeOutlineCache[key];
    if (cached != null) return cached;

    final sourceIsArea = hasWidthProfile || isClosed;
    final geometry = _preparedStrokeGeometry ??= StrokeOutlineBuilder.prepare(
      sourceIsArea ? getPath() : getCenterPath(),
      sourceIsArea: sourceIsArea,
      interactive: interactive,
    );

    Path dilation(double distance) {
      if (distance <= StrokeOutlineBuilder.epsilon) {
        return geometry.sourceIsArea
            ? geometry.buildDilation(0.0)
            : Path();
      }

      final cachedDilation = _strokeDilationCache[distance];
      if (cachedDilation != null) return Path.from(cachedDilation);

      final built = geometry.buildDilation(distance);
      _strokeDilationCache[distance] = Path.from(built);
      return built;
    }

    final innerDistance = innerOffset < 0.0 ? 0.0 : innerOffset;
    final outer = dilation(innerDistance + width);
    final inner = dilation(innerDistance);

    final innerIsEmpty = inner.getBounds() == Rect.zero &&
        inner.computeMetrics().isEmpty;
    final band = innerIsEmpty
        ? (Path.from(outer)..fillType = PathFillType.evenOdd)
        : (Path()
          ..fillType = PathFillType.evenOdd
          ..addPath(outer, Offset.zero)
          ..addPath(inner, Offset.zero));

    // A normal stack only needs one cumulative dilation per boundary. Keep the
    // caches bounded for live width-slider edits while retaining all values used
    // by the current stack and renderer/export passes.
    if (_strokeDilationCache.length >= 32) {
      _strokeDilationCache.clear();
    }
    if (_strokeOutlineCache.length >= 32) {
      _strokeOutlineCache.clear();
    }

    _strokeOutlineCache[key] = Path.from(band);
    return band;
  }

  // --- Centerline as an SVG path string ---
  String getCenterSvgPathData() {
    if (nodes.isEmpty) return "";
    final buffer = StringBuffer();
    final resolvedNodes = getResolvedNodes();
    int n = resolvedNodes.length;
    int loopCount = isClosed ? n : n - 1;

    final start = resolvedNodes[0].point;
    buffer.write('M ${start.dx} ${start.dy} ');

    if (n > 1) {
      for (int i = 0; i < loopCount; i++) {
        final pt0 = resolvedNodes[i].point;
        final pt1 = resolvedNodes[(i + 1) % n].point;

        final cp1 = pt0 + resolvedNodes[i].hOut;
        final cp2 = pt1 + resolvedNodes[(i + 1) % n].hIn;

        buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${pt1.dx} ${pt1.dy} ');
      }
    }
    if (isClosed) buffer.write('Z');
    return buffer.toString().trim();
  }

  String getSvgPathData() {
    if (nodes.isEmpty) return "";

    if (!hasWidthProfile) {
      return getCenterSvgPathData();
    }

    final buffer = StringBuffer();
    final resolvedNodes = getResolvedNodes();
    final normals = calculateResolvedNormals(resolvedNodes);
    int n = resolvedNodes.length;
    int loopCount = isClosed ? n : n - 1;

    final leftPts = <Offset>[];
    final rightPts = <Offset>[];

    for (int i = 0; i < n; i++) {
      final pt = resolvedNodes[i].point;
      final N = normals[i];
      leftPts.add(pt + N * resolvedNodes[i].widthLeft);
      rightPts.add(pt - N * resolvedNodes[i].widthRight);
    }

    // Left Boundary
    buffer.write('M ${leftPts[0].dx} ${leftPts[0].dy} ');
    for (int i = 0; i < loopCount; i++) {
      final nextIdx = (i + 1) % n;
      final cp1 = leftPts[i] + resolvedNodes[i].hOut;
      final cp2 = leftPts[nextIdx] + resolvedNodes[nextIdx].hIn;
      buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${leftPts[nextIdx].dx} ${leftPts[nextIdx].dy} ');
    }

    if (isClosed) {
      buffer.write('Z ');
      // Trace Inner/Right Boundary BACKWARD
      buffer.write('M ${rightPts[0].dx} ${rightPts[0].dy} ');
      for (int i = n; i > 0; i--) {
        final currIdx = i % n;
        final prevIdx = i - 1;
        final cp1 = rightPts[currIdx] + resolvedNodes[currIdx].hIn;
        final cp2 = rightPts[prevIdx] + resolvedNodes[prevIdx].hOut;
        buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${rightPts[prevIdx].dx} ${rightPts[prevIdx].dy} ');
      }
      buffer.write('Z');
    } else {
      // Forward Semicircle Endcap 
      final endRadius = (leftPts[n - 1] - rightPts[n - 1]).distance / 2.0;
      if (endRadius > 0.001) {
        buffer.write('A $endRadius $endRadius 0 0 0 ${rightPts[n - 1].dx} ${rightPts[n - 1].dy} ');
      } else {
        buffer.write('L ${rightPts[n - 1].dx} ${rightPts[n - 1].dy} ');
      }

      for (int i = n - 1; i > 0; i--) {
        final prevIdx = i - 1;
        final cp1 = rightPts[i] + resolvedNodes[i].hIn; 
        final cp2 = rightPts[prevIdx] + resolvedNodes[prevIdx].hOut; 
        buffer.write('C ${cp1.dx} ${cp1.dy}, ${cp2.dx} ${cp2.dy}, ${rightPts[prevIdx].dx} ${rightPts[prevIdx].dy} ');
      }

      // Start Semicircle Endcap 
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