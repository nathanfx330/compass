// /lib/models/geometry/mesh.dart

import 'package:flutter/material.dart';
import 'dart:ui' show Vertices, VertexMode;

import 'point.dart';
import 'shape.dart';
import 'spline.dart'; // <--- NEW: Imported to use CompassSplineNode for tension

/// A rectangular GRADIENT MESH: a row-major grid of CompassSplineNode nodes, each
/// carrying a color, rendered as a smoothly Gouraud/Bicubic-interpolated color
/// field via canvas.drawVertices.
///
/// Upgraded to Coons Patches: Nodes now have a Tension value (via the A key).
/// The grid mathematically evaluates cubic curves horizontally and vertically,
/// and the internal gradient is warped perfectly to fit those curved boundaries.
class CompassMesh extends CompassShape {
  final int rows;
  final int cols;
  
  /// Node grid, ROW-MAJOR: node(r, c) == nodes[r * cols + c]. 
  /// Upgraded to CompassSplineNode so each intersection has tension control.
  final List<CompassSplineNode> nodes;

  final List<Color> colors;

  CompassPoint? anchorPoint;

  CompassMesh({
    required this.rows,
    required this.cols,
    required this.nodes,
    required this.colors,
    this.anchorPoint,
    super.operation,
    super.isVisible,
  });

  // ---------------------------------------------------------------------------
  // ROW-MAJOR ACCESSORS
  // ---------------------------------------------------------------------------

  CompassSplineNode node(int r, int c) => nodes[r * cols + c];
  Color colorAt(int r, int c) => colors[r * cols + c];
  void setColorAt(int r, int c, Color color) => colors[r * cols + c] = color;

  Offset _nodeOffset(int r, int c) {
    final p = node(r, c).point;
    return Offset(p.x.value, p.y.value);
  }

  int indexOfPoint(CompassPoint p) => nodes.indexWhere((n) => n.point == p);

  bool containsNode(CompassPoint p) => indexOfPoint(p) != -1;

  Color? colorForPoint(CompassPoint p) {
    final i = indexOfPoint(p);
    return i == -1 ? null : colors[i];
  }

  bool setColorForPoint(CompassPoint p, Color color) {
    final i = indexOfPoint(p);
    if (i == -1) return false;
    colors[i] = color;
    return true;
  }

  // ---------------------------------------------------------------------------
  // COONS PATCH & CUBIC MATH (BICUBIC INTERPOLATION)
  // ---------------------------------------------------------------------------

  /// Computes Catmull-Rom style tangents for every node in the grid based on
  /// its physical neighbors and its live Tension value.
  /// Returns a tuple of (HorizontalTangents, VerticalTangents).
  (List<List<Offset>>, List<List<Offset>>) _computeTangents() {
    final tx = List.generate(rows, (_) => List.filled(cols, Offset.zero));
    final ty = List.generate(rows, (_) => List.filled(cols, Offset.zero));

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final t = node(r, c).tension.value;
        final p = _nodeOffset(r, c);

        // Horizontal Tangents (Tx)
        if (cols > 1) {
          if (c == 0) {
            tx[r][c] = (_nodeOffset(r, 1) - p) * t;
          } else if (c == cols - 1) {
            tx[r][c] = (p - _nodeOffset(r, c - 1)) * t;
          } else {
            tx[r][c] = (_nodeOffset(r, c + 1) - _nodeOffset(r, c - 1)) * 0.5 * t;
          }
        }

        // Vertical Tangents (Ty)
        if (rows > 1) {
          if (r == 0) {
            ty[r][c] = (_nodeOffset(1, c) - p) * t;
          } else if (r == rows - 1) {
            ty[r][c] = (p - _nodeOffset(r - 1, c)) * t;
          } else {
            ty[r][c] = (_nodeOffset(r + 1, c) - _nodeOffset(r - 1, c)) * 0.5 * t;
          }
        }
      }
    }
    return (tx, ty);
  }

  Offset _cubic(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
    final u = 1.0 - t;
    final a = u * u * u;
    final b = 3 * u * u * t;
    final c = 3 * u * t * t;
    final d = t * t * t;
    return Offset(
      a * p0.dx + b * p1.dx + c * p2.dx + d * p3.dx,
      a * p0.dy + b * p1.dy + c * p2.dy + d * p3.dy,
    );
  }

  Offset _evalHorizontalEdge(int r, int c, double u, List<List<Offset>> tx) {
    final p0 = _nodeOffset(r, c);
    final p1 = _nodeOffset(r, c + 1);
    return _cubic(p0, p0 + tx[r][c] / 3, p1 - tx[r][c + 1] / 3, p1, u);
  }

  Offset _evalVerticalEdge(int r, int c, double v, List<List<Offset>> ty) {
    final p0 = _nodeOffset(r, c);
    final p1 = _nodeOffset(r + 1, c);
    return _cubic(p0, p0 + ty[r][c] / 3, p1 - ty[r + 1][c] / 3, p1, v);
  }

  /// Evaluates a true Coons Patch coordinate given the patch boundaries.
  Offset _coonsOffset(int r, int c, double u, double v, List<List<Offset>> tx, List<List<Offset>> ty) {
    final p00 = _nodeOffset(r, c);
    final p01 = _nodeOffset(r, c + 1);
    final p10 = _nodeOffset(r + 1, c);
    final p11 = _nodeOffset(r + 1, c + 1);

    final top = _cubic(p00, p00 + tx[r][c] / 3, p01 - tx[r][c + 1] / 3, p01, u);
    final bot = _cubic(p10, p10 + tx[r + 1][c] / 3, p11 - tx[r + 1][c + 1] / 3, p11, u);
    final lft = _cubic(p00, p00 + ty[r][c] / 3, p10 - ty[r + 1][c] / 3, p10, v);
    final rgt = _cubic(p01, p01 + ty[r][c + 1] / 3, p11 - ty[r + 1][c + 1] / 3, p11, v);

    final bilerp = Offset(
      (1 - v) * ((1 - u) * p00.dx + u * p01.dx) + v * ((1 - u) * p10.dx + u * p11.dx),
      (1 - v) * ((1 - u) * p00.dy + u * p01.dy) + v * ((1 - u) * p10.dy + u * p11.dy),
    );

    return Offset(
      (1 - v) * top.dx + v * bot.dx + (1 - u) * lft.dx + u * rgt.dx - bilerp.dx,
      (1 - v) * top.dy + v * bot.dy + (1 - u) * lft.dy + u * rgt.dy - bilerp.dy,
    );
  }

  // ---------------------------------------------------------------------------
  // SLICING  (X-key: insert a full row or column at a parametric position)
  // ---------------------------------------------------------------------------

  MeshSliceData insertRowData(int gap, [double t = 0.5]) {
    assert(gap >= 0 && gap <= rows - 2, 'row gap out of range');
    final tt = t.clamp(0.0, 1.0);
    final newRows = rows + 1;
    final newCols = cols;

    final existing = List<CompassSplineNode?>.filled(newRows * newCols, null);
    final reusedColors = List<Color?>.filled(newRows * newCols, null);
    final newPositions = List<Offset?>.filled(newRows * newCols, null);
    final newColors = List<Color?>.filled(newRows * newCols, null);

    for (int r = 0; r < rows; r++) {
      final nr = r <= gap ? r : r + 1;
      for (int c = 0; c < cols; c++) {
        final src = r * cols + c;
        final dst = nr * newCols + c;
        existing[dst] = node(r, c);
        reusedColors[dst] = colors[src];
      }
    }

    final tangents = _computeTangents();
    final ty = tangents.$2;

    final insRow = gap + 1;
    for (int c = 0; c < cols; c++) {
      final dst = insRow * newCols + c;
      // Evaluate exactly on the cubic boundary!
      newPositions[dst] = _evalVerticalEdge(gap, c, tt, ty);
      newColors[dst] = Color.lerp(colorAt(gap, c), colorAt(gap + 1, c), tt)!;
    }

    return MeshSliceData(
      rows: newRows,
      cols: newCols,
      existing: existing,
      reusedColors: reusedColors,
      newPositions: newPositions,
      newColors: newColors,
    );
  }

  MeshSliceData insertColumnData(int gap, [double t = 0.5]) {
    assert(gap >= 0 && gap <= cols - 2, 'column gap out of range');
    final tt = t.clamp(0.0, 1.0);
    final newRows = rows;
    final newCols = cols + 1;

    final existing = List<CompassSplineNode?>.filled(newRows * newCols, null);
    final reusedColors = List<Color?>.filled(newRows * newCols, null);
    final newPositions = List<Offset?>.filled(newRows * newCols, null);
    final newColors = List<Color?>.filled(newRows * newCols, null);

    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        final nc = c <= gap ? c : c + 1;
        final src = r * cols + c;
        final dst = r * newCols + nc;
        existing[dst] = node(r, c);
        reusedColors[dst] = colors[src];
      }
    }

    final tangents = _computeTangents();
    final tx = tangents.$1;

    final insCol = gap + 1;
    for (int r = 0; r < rows; r++) {
      final dst = r * newCols + insCol;
      // Evaluate exactly on the cubic boundary!
      newPositions[dst] = _evalHorizontalEdge(r, gap, tt, tx);
      newColors[dst] = Color.lerp(colorAt(r, gap), colorAt(r, gap + 1), tt)!;
    }

    return MeshSliceData(
      rows: newRows,
      cols: newCols,
      existing: existing,
      reusedColors: reusedColors,
      newPositions: newPositions,
      newColors: newColors,
    );
  }

  int rowGapAt(Offset local) {
    if (rows < 2) return -1;
    for (int r = 0; r < rows - 1; r++) {
      final yTop = rowY(r);
      final yBot = rowY(r + 1);
      final lo = yTop < yBot ? yTop : yBot;
      final hi = yTop < yBot ? yBot : yTop;
      if (local.dy >= lo && local.dy <= hi) return r;
    }
    return -1;
  }

  int colGapAt(Offset local) {
    if (cols < 2) return -1;
    for (int c = 0; c < cols - 1; c++) {
      final xLeft = colX(c);
      final xRight = colX(c + 1);
      final lo = xLeft < xRight ? xLeft : xRight;
      final hi = xLeft < xRight ? xRight : xLeft;
      if (local.dx >= lo && local.dx <= hi) return c;
    }
    return -1;
  }

  double rowY(int r) {
    double sum = 0;
    for (int c = 0; c < cols; c++) sum += _nodeOffset(r, c).dy;
    return sum / cols;
  }

  double colX(int c) {
    double sum = 0;
    for (int r = 0; r < rows; r++) sum += _nodeOffset(r, c).dx;
    return sum / rows;
  }

  double rowParamAt(int gap, Offset local) {
    if (gap < 0 || gap > rows - 2) return 0.5;
    final yTop = rowY(gap);
    final yBot = rowY(gap + 1);
    final span = yBot - yTop;
    if (span.abs() < 1e-9) return 0.5;
    return ((local.dy - yTop) / span).clamp(0.0, 1.0);
  }

  double colParamAt(int gap, Offset local) {
    if (gap < 0 || gap > cols - 2) return 0.5;
    final xLeft = colX(gap);
    final xRight = colX(gap + 1);
    final span = xRight - xLeft;
    if (span.abs() < 1e-9) return 0.5;
    return ((local.dx - xLeft) / span).clamp(0.0, 1.0);
  }

  (Offset, Offset)? rowSlicePreview(int gap, [double t = 0.5]) {
    if (gap < 0 || gap > rows - 2) return null;
    final tangents = _computeTangents();
    final left = _evalVerticalEdge(gap, 0, t.clamp(0.0, 1.0), tangents.$2);
    final right = _evalVerticalEdge(gap, cols - 1, t.clamp(0.0, 1.0), tangents.$2);
    return (left, right);
  }

  (Offset, Offset)? colSlicePreview(int gap, [double t = 0.5]) {
    if (gap < 0 || gap > cols - 2) return null;
    final tangents = _computeTangents();
    final top = _evalHorizontalEdge(0, gap, t.clamp(0.0, 1.0), tangents.$1);
    final bottom = _evalHorizontalEdge(rows - 1, gap, t.clamp(0.0, 1.0), tangents.$1);
    return (top, bottom);
  }

  // ---------------------------------------------------------------------------
  // OUTER BOUNDARY  (the silhouette before booleans carve it)
  // ---------------------------------------------------------------------------

  @override
  Path getPath() {
    final path = Path();
    if (rows < 2 || cols < 2) return path;

    final tangents = _computeTangents();
    final tx = tangents.$1;
    final ty = tangents.$2;

    final start = _nodeOffset(0, 0);
    path.moveTo(start.dx, start.dy);

    // Top edge (L -> R)
    for (int c = 0; c < cols - 1; c++) {
      final p0 = _nodeOffset(0, c);
      final p1 = _nodeOffset(0, c + 1);
      final cp1 = p0 + tx[0][c] / 3;
      final cp2 = p1 - tx[0][c + 1] / 3;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);
    }

    // Right edge (T -> B)
    for (int r = 0; r < rows - 1; r++) {
      final p0 = _nodeOffset(r, cols - 1);
      final p1 = _nodeOffset(r + 1, cols - 1);
      final cp1 = p0 + ty[r][cols - 1] / 3;
      final cp2 = p1 - ty[r + 1][cols - 1] / 3;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);
    }

    // Bottom edge (R -> L)
    for (int c = cols - 2; c >= 0; c--) {
      final p0 = _nodeOffset(rows - 1, c + 1);
      final p1 = _nodeOffset(rows - 1, c);
      final cp1 = p0 - tx[rows - 1][c + 1] / 3;
      final cp2 = p1 + tx[rows - 1][c] / 3;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);
    }

    // Left edge (B -> T)
    for (int r = rows - 2; r >= 0; r--) {
      final p0 = _nodeOffset(r + 1, 0);
      final p1 = _nodeOffset(r, 0);
      final cp1 = p0 - ty[r + 1][0] / 3;
      final cp2 = p1 + ty[r][0] / 3;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);
    }

    path.close();
    return path;
  }

  Rect getBounds() {
    // Relying on the true cubic path guarantees we capture curve bulges
    return getPath().getBounds();
  }

  // ---------------------------------------------------------------------------
  // VERTEX / COLOR BUILD  (the gradient surface itself)
  // ---------------------------------------------------------------------------

  Vertices buildVertices({int subdivisions = 8}) {
    final int sub = subdivisions < 1 ? 1 : (subdivisions > 64 ? 64 : subdivisions);

    final positions = <Offset>[];
    final vertexColors = <Color>[];
    final indices = <int>[];

    final tangents = _computeTangents();
    final tx = tangents.$1;
    final ty = tangents.$2;

    for (int r = 0; r < rows - 1; r++) {
      for (int c = 0; c < cols - 1; c++) {
        final kTL = colorAt(r, c);
        final kTR = colorAt(r, c + 1);
        final kBL = colorAt(r + 1, c);
        final kBR = colorAt(r + 1, c + 1);

        final base = positions.length;
        for (int i = 0; i <= sub; i++) {
          final v = i / sub;
          for (int j = 0; j <= sub; j++) {
            final u = j / sub;
            positions.add(_coonsOffset(r, c, u, v, tx, ty));
            vertexColors.add(Color.lerp(
              Color.lerp(kTL, kTR, u)!,
              Color.lerp(kBL, kBR, u)!,
              v,
            )!);
          }
        }

        final stride = sub + 1;
        for (int i = 0; i < sub; i++) {
          for (int j = 0; j < sub; j++) {
            final i0 = base + i * stride + j;
            final i1 = i0 + 1;
            final i2 = i0 + stride;
            final i3 = i2 + 1;
            indices.add(i0);
            indices.add(i1);
            indices.add(i2);
            indices.add(i1);
            indices.add(i3);
            indices.add(i2);
          }
        }
      }
    }

    return Vertices(
      VertexMode.triangles,
      positions,
      colors: vertexColors,
      indices: indices,
    );
  }

  // ---------------------------------------------------------------------------
  // SCAFFOLDING
  // ---------------------------------------------------------------------------

  @override
  void paint(Canvas canvas, Paint paint, {bool showScaffolding = false, bool isSelected = false}) {
    final linePaint = Paint()
      ..color = paint.color
      ..strokeWidth = paint.strokeWidth
      ..style = PaintingStyle.stroke;

    final tangents = _computeTangents();
    final tx = tangents.$1;
    final ty = tangents.$2;
    
    final path = Path();

    // Horizontal grid curves
    for (int r = 0; r < rows; r++) {
      path.moveTo(_nodeOffset(r, 0).dx, _nodeOffset(r, 0).dy);
      for (int c = 0; c < cols - 1; c++) {
        final p0 = _nodeOffset(r, c);
        final p1 = _nodeOffset(r, c + 1);
        final cp1 = p0 + tx[r][c] / 3;
        final cp2 = p1 - tx[r][c + 1] / 3;
        path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);
      }
    }
    
    // Vertical grid curves
    for (int c = 0; c < cols; c++) {
      path.moveTo(_nodeOffset(0, c).dx, _nodeOffset(0, c).dy);
      for (int r = 0; r < rows - 1; r++) {
        final p0 = _nodeOffset(r, c);
        final p1 = _nodeOffset(r + 1, c);
        final cp1 = p0 + ty[r][c] / 3;
        final cp2 = p1 - ty[r + 1][c] / 3;
        path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p1.dx, p1.dy);
      }
    }
    
    canvas.drawPath(path, linePaint);
  }
}

class MeshSliceData {
  final int rows;
  final int cols;
  final List<CompassSplineNode?> existing;
  final List<Color?> reusedColors;
  final List<Offset?> newPositions;
  final List<Color?> newColors;

  MeshSliceData({
    required this.rows,
    required this.cols,
    required this.existing,
    required this.reusedColors,
    required this.newPositions,
    required this.newColors,
  });
}