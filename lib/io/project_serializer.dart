// lib/io/project_serializer.dart

import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../engine.dart';
import '../constraints.dart'; 
import '../models/geometry/point.dart';
import '../models/geometry/shape.dart';
import '../models/geometry/line.dart';
import '../models/geometry/circle.dart';
import '../models/geometry/spiral.dart';
import '../models/geometry/spline.dart';
import '../models/geometry/rectangle.dart';
import '../models/layer.dart';

class ProjectSerializer {
  static String serialize(CompassEngine engine) {
    final buffer = StringBuffer();
    for (var p in engine.points) {
      buffer.writeln('POINT,${p.id},${p.x.value},${p.y.value}');
    }

    // Persist the rigid-body attachment graph (parent -> child). attachedPoints is
    // the live source of truth for which points move together; until now it was
    // never serialized, so baked layers, converted rectangles/circles, spliced
    // spline nodes, and constraint-ridden points all lost their cohesion on reload
    // (the anchor *reference* survived via the XSPLINE line, so rotation pivots were
    // fine, but Shift-drag no longer pulled the group through attachedPoints). We
    // emit one ATTACH per edge and replay them on load once every point exists.
    // Point ids never contain commas (they already survive this CSV round-trip), so
    // a plain comma split is safe. attach() dedupes, so the handful of edges the
    // shape-loaders also rebuild (circle/spiral center -> satellite) stay idempotent.
    for (var p in engine.points) {
      for (var child in p.attachedPoints) {
        buffer.writeln('ATTACH,${p.id},${child.id}');
      }
    }

    if (engine.referenceLayer != null) {
      final rl = engine.referenceLayer!;
      buffer.writeln('REF,${rl.imagePath},${rl.isVisible},${rl.isLocked},${rl.offset.dx},${rl.offset.dy},${rl.scale},${rl.rotation}');
    }

    for (var layer in engine.layers) {
      buffer.writeln('LAYER,${layer.id},${layer.name},${layer.isVisible},${layer.isExpanded},${layer.color.value},${layer.strokeColor.value},${layer.strokeWidth},${layer.isLocked}');
      for (var shape in layer.shapes) {
        if (shape is CompassLine) {
          buffer.writeln('SHAPE,LINE,${layer.id},${shape.operation.name},${shape.isVisible},${shape.start.id},${shape.end.id}');
        } else if (shape is CompassCircle) {
          buffer.writeln('SHAPE,CIRCLE,${layer.id},${shape.operation.name},${shape.isVisible},${shape.center.id},${shape.radiusPoint?.id ?? ""}');
        } else if (shape is CompassSpiral) {
          buffer.writeln('SHAPE,SPIRAL,${layer.id},${shape.operation.name},${shape.isVisible},${shape.center.id},${shape.startPoint.id},${shape.isClockwise},${shape.revolutions}');
        } else if (shape is CompassRectangle) {
          buffer.writeln('SHAPE,RECTANGLE,${layer.id},${shape.operation.name},${shape.isVisible},${shape.p1.id},${shape.p2.id},${shape.cornerRadius.value},${shape.isSquare}');
        } else if (shape is CompassXSpline) {
          // NEW: node token is id:tension, extended to id:tension:hInX:hInY:hOutX:hOutY:wL:wR
          // when the node carries explicit Bezier handles or variable width. 
          // "null" is used for handles that remain fluid, preserving Catmull-Rom math.
          final nodesStr = shape.nodes.map((n) {
            final hasHandles = n.handleIn != null || n.handleOut != null;
            final hasWidth = n.widthLeft.value > 0.001 || n.widthRight.value > 0.001;

            if (hasHandles || hasWidth) {
              final hIX = n.handleIn?.dx.toString() ?? 'null';
              final hIY = n.handleIn?.dy.toString() ?? 'null';
              final hOX = n.handleOut?.dx.toString() ?? 'null';
              final hOY = n.handleOut?.dy.toString() ?? 'null';
              return '${n.point.id}:${n.tension.value}:$hIX:$hIY:$hOX:$hOY:${n.widthLeft.value}:${n.widthRight.value}';
            }
            return '${n.point.id}:${n.tension.value}';
          }).join('|');
          buffer.writeln('SHAPE,XSPLINE,${layer.id},${shape.operation.name},${shape.isVisible},${shape.isClosed},${shape.anchorPoint?.id ?? ""},$nodesStr');
        }
      }
    }

    // Persist host-rider constraints: PointOnLine / PointOnCircle / PointOnSpiral.
    // These three have NO other reconstruction path (unlike DistanceRadius, rebuilt
    // by the circle loader's radius closure, and Square, rebuilt from isSquare), so
    // without this they vanish on every save/load -- and because undo() round-trips
    // through serialize/deserialize, they vanish on Ctrl+Z too. We record the rider
    // id plus the ids of the host shape's DEFINING points rather than inventing a
    // shape id: that keeps every SHAPE line byte-identical and the rebuild pass
    // matches those ids back to the freshly-built shape. Emitted last, after all
    // SHAPE lines, since a constraint references a shape that must already exist;
    // the load side also uses a dedicated pass so ordering is not actually relied on.
    // Legacy files carry no CONSTRAINT lines (clean no-op on load); older code
    // opening a new file simply ignores the unknown lines -- compatible both ways.
    for (var c in engine.constraints) {
      if (c is PointOnLineConstraint) {
        buffer.writeln('CONSTRAINT,PONLINE,${c.point.id},${c.line.start.id},${c.line.end.id}');
      } else if (c is PointOnCircleConstraint) {
        buffer.writeln('CONSTRAINT,PONCIRCLE,${c.point.id},${c.circle.center.id},${c.circle.radiusPoint?.id ?? ""}');
      } else if (c is PointOnSpiralConstraint) {
        buffer.writeln('CONSTRAINT,PONSPIRAL,${c.point.id},${c.spiral.center.id},${c.spiral.startPoint.id}');
      }
    }

    return buffer.toString();
  }

  static void deserialize(CompassEngine engine, String data, VoidCallback onUpdate) {
    engine.points.clear();
    engine.layers.clear();
    engine.constraints.clear(); // <--- Rebuilt from CONSTRAINT lines in the third pass
    engine.referenceLayer = null;
    engine.activeLayer = null;
    engine.selectShape(null);

    final Map<String, CompassPoint> pointMap = {};
    final Map<String, CompassLayer> layerMap = {};

    final lines = data.split('\n');

    for (var line in lines) {
      final parts = line.split(',');
      if (parts.isEmpty) continue;
      
      final type = parts[0].trim();
      if (type == 'POINT' && parts.length >= 4) {
        final p = CompassPoint(
          id: parts[1], 
          x: double.tryParse(parts[2]) ?? 0, 
          y: double.tryParse(parts[3]) ?? 0,
        );
        pointMap[p.id] = p;
        engine.points.add(p);
        p.x.addListener(onUpdate);
        p.y.addListener(onUpdate);
      } 
      else if (type == 'REF' && parts.length >= 8) {
        final path = parts[1];
        engine.loadReferenceImage(path).then((_) {
          if (engine.referenceLayer != null) {
            engine.referenceLayer!.isVisible = parts[2] == 'true';
            engine.referenceLayer!.isLocked = parts[3] == 'true';
            engine.referenceLayer!.offset = ui.Offset(double.tryParse(parts[4]) ?? 0, double.tryParse(parts[5]) ?? 0);
            engine.referenceLayer!.scale = double.tryParse(parts[6]) ?? 1.0;
            engine.referenceLayer!.rotation = double.tryParse(parts[7]) ?? 0.0;
            onUpdate();
          }
        });
      }
      else if (type == 'LAYER' && parts.length >= 8) {
        final layer = CompassLayer(
          id: parts[1],
          name: parts[2],
          color: Color(int.tryParse(parts[5]) ?? 0xFF222222),
          strokeColor: Color(int.tryParse(parts[6]) ?? 0x00000000),
          strokeWidth: double.tryParse(parts[7]) ?? 2.0,
        );
        layer.isVisible = parts[3] == 'true';
        layer.isExpanded = parts[4] == 'true';
        
        if (parts.length >= 9) {
          layer.isLocked = parts[8] == 'true';
        }

        layerMap[layer.id] = layer;
        engine.layers.add(layer);
      }
    }

    for (var line in lines) {
      final parts = line.split(',');
      if (parts.isEmpty) continue;
      
      final type = parts[0].trim();

      // Replay the attachment graph now that pass 1 has created every point, so
      // lookups never miss regardless of where ATTACH lines sit in the file. Ids
      // are trimmed to shrug off a trailing '\r' from CRLF-saved files. Legacy
      // saves carry no ATTACH lines, so this is a clean no-op for them (they load
      // exactly as before), and a new save opened by older code simply ignores the
      // unknown ATTACH lines -- forward- and backward-compatible both ways.
      if (type == 'ATTACH' && parts.length >= 3) {
        final parent = pointMap[parts[1].trim()];
        final child = pointMap[parts[2].trim()];
        if (parent != null && child != null) {
          parent.attach(child);
        }
        continue;
      }

      if (type == 'SHAPE' && parts.length >= 6) {
        final shapeType = parts[1];
        final layer = layerMap[parts[2]];
        final op = CompassBooleanOp.values.firstWhere((e) => e.name == parts[3], orElse: () => CompassBooleanOp.add);
        
        if (layer != null) {
          bool isVisible = true;
          int argOffset = 4;

          if (shapeType == 'XSPLINE') {
            if (parts.length >= 7) {
              isVisible = parts[4] == 'true';
              argOffset = 5;
            }
          } else if (shapeType == 'SPIRAL' || shapeType == 'RECTANGLE') {
            if (parts.length >= 9) {
              isVisible = parts[4] == 'true';
              argOffset = 5;
            }
          } else { // LINE, CIRCLE
            if (parts.length >= 7) {
              isVisible = parts[4] == 'true';
              argOffset = 5;
            }
          }

          if (shapeType == 'LINE') {
            final p1 = pointMap[parts[argOffset]];
            final p2 = pointMap[parts[argOffset + 1]];
            if (p1 != null && p2 != null) {
              layer.shapes.add(CompassLine(start: p1, end: p2)..operation = op..isVisible = isVisible);
            }
          } else if (shapeType == 'CIRCLE') {
            final center = pointMap[parts[argOffset]];
            final radiusPoint = pointMap[parts[argOffset + 1]];
            if (center != null && radiusPoint != null) {
               final circle = CompassCircle(center: center, radiusPoint: radiusPoint, radius: 0)..operation = op..isVisible = isVisible;
               
               center.attach(radiusPoint);
               void enforceRadius() {
                 final dx = radiusPoint.x.value - center.x.value;
                 final dy = radiusPoint.y.value - center.y.value;
                 circle.radius.value = sqrt(dx * dx + dy * dy);
               }
               enforceRadius(); 
               center.x.addListener(enforceRadius);
               center.y.addListener(enforceRadius);
               radiusPoint.x.addListener(enforceRadius);
               radiusPoint.y.addListener(enforceRadius);

               layer.shapes.add(circle);
            }
          } else if (shapeType == 'SPIRAL') {
            final center = pointMap[parts[argOffset]];
            final startPoint = pointMap[parts[argOffset + 1]];
            final isClockwise = parts[argOffset + 2] == 'true';
            final revolutions = double.tryParse(parts[argOffset + 3]) ?? 4.0;
            
            if (center != null && startPoint != null) {
              final spiral = CompassSpiral(
                center: center, 
                startPoint: startPoint,
                isClockwise: isClockwise,
                revolutions: revolutions,
              )..operation = op..isVisible = isVisible;
              
              center.attach(startPoint);
              layer.shapes.add(spiral);
            }
          } else if (shapeType == 'RECTANGLE') {
            final p1 = pointMap[parts[argOffset]];
            final p2 = pointMap[parts[argOffset + 1]];
            final radius = double.tryParse(parts[argOffset + 2]) ?? 0.0;
            
            bool isSquare = false;
            if (parts.length > argOffset + 3) {
              isSquare = parts[argOffset + 3] == 'true';
            }
            
            if (p1 != null && p2 != null) {
              final rect = CompassRectangle(p1: p1, p2: p2, radius: radius, isSquare: isSquare)
                ..operation = op
                ..isVisible = isVisible;
                
              if (isSquare) {
                SquareConstraint(rect: rect);
              }
                
              layer.shapes.add(rect);
            }
          } else if (shapeType == 'XSPLINE') {
            final isClosed = parts[argOffset] == 'true';
            
            CompassPoint? anchorPt;
            String nodesRawStr = "";
            
            if (parts[argOffset + 1].contains('|') || parts[argOffset + 1].contains(':')) {
              nodesRawStr = parts[argOffset + 1];
            } else {
              final anchorId = parts[argOffset + 1];
              if (anchorId.isNotEmpty) anchorPt = pointMap[anchorId];
              nodesRawStr = parts[argOffset + 2];
            }

            final spline = CompassXSpline(isClosed: isClosed, anchorPoint: anchorPt)..operation = op..isVisible = isVisible;
            
            bool valid = true;
            final nodesData = nodesRawStr.split('|');
            for(var nd in nodesData) {
              if(nd.isEmpty) continue;
              
              final np = nd.split(':');
              if(np.length >= 2) {
                final pt = pointMap[np[0]];
                final tension = double.tryParse(np[1]) ?? 1.0;
                if (pt != null) {
                  Offset? hIn, hOut;
                  double wL = 0.0;
                  double wR = 0.0;
                  
                  if (np.length == 4) { // Legacy symmetric fallback
                    final hx = double.tryParse(np[2]) ?? 0.0;
                    final hy = double.tryParse(np[3]) ?? 0.0;
                    hOut = Offset(hx, hy);
                    hIn = Offset(-hx, -hy);
                  } else if (np.length >= 6) { // Dual explicit handles + Width
                    if (np[2] != 'null' && np[2].isNotEmpty) {
                      hIn = Offset(double.tryParse(np[2]) ?? 0.0, double.tryParse(np[3]) ?? 0.0);
                    }
                    if (np[4] != 'null' && np[4].isNotEmpty) {
                      hOut = Offset(double.tryParse(np[4]) ?? 0.0, double.tryParse(np[5]) ?? 0.0);
                    }
                    if (np.length >= 8) {
                      wL = double.tryParse(np[6]) ?? 0.0;
                      wR = double.tryParse(np[7]) ?? 0.0;
                    }
                  }
                  
                  final node = CompassSplineNode(
                    point: pt, 
                    tension: tension, 
                    handleIn: hIn, 
                    handleOut: hOut,
                    widthLeft: wL,
                    widthRight: wR,
                  );
                  node.tension.addListener(onUpdate); 
                  node.widthLeft.addListener(onUpdate);
                  node.widthRight.addListener(onUpdate);
                  spline.addNode(node);
                } else {
                  valid = false;
                }
              }
            }
            if (valid && spline.nodes.length >= 2) {
              layer.shapes.add(spline);
            }
          }
        }
      }
    }

    // --- THIRD PASS: rebuild host-rider constraints ---------------------------
    //
    // Runs only after pass 2 has built every shape, so a constraint's host always
    // exists no matter where its CONSTRAINT line sits in the file (a clean line is
    // emitted after all SHAPE lines, but we don't depend on that). For each line we
    // look the rider up in pointMap, find the host shape by the recorded ids of its
    // defining points, then construct the constraint and register it DIRECTLY in
    // engine.constraints. We deliberately do NOT route through engine.addPointOn*:
    // those snapshot the undo stack and notify listeners, which is wrong mid-load
    // (this mirrors how SquareConstraint is reconstructed inline above, just with
    // the extra list registration the engine now needs). The constraint constructor
    // runs enforce() once, but every rider was saved exactly on its host, so that is
    // a zero-delta no-op -- nothing jumps, no listener storm.

    CompassLine? findLine(String startId, String endId) {
      for (var layer in engine.layers) {
        for (var s in layer.shapes) {
          if (s is CompassLine && s.start.id == startId && s.end.id == endId) return s;
        }
      }
      return null;
    }

    CompassCircle? findCircle(String centerId, String radiusPointId) {
      for (var layer in engine.layers) {
        for (var s in layer.shapes) {
          if (s is CompassCircle && s.center.id == centerId) {
            // When a radiusPoint id was recorded, require it to match too, so two
            // concentric circles sharing a center can't get cross-bound.
            if (radiusPointId.isEmpty) return s;
            if (s.radiusPoint?.id == radiusPointId) return s;
          }
        }
      }
      return null;
    }

    CompassSpiral? findSpiral(String centerId, String startId) {
      for (var layer in engine.layers) {
        for (var s in layer.shapes) {
          if (s is CompassSpiral && s.center.id == centerId && s.startPoint.id == startId) return s;
        }
      }
      return null;
    }

    for (var line in lines) {
      final parts = line.split(',');
      if (parts.isEmpty) continue;

      final type = parts[0].trim();
      if (type != 'CONSTRAINT' || parts.length < 3) continue;

      final kind = parts[1].trim();
      final rider = pointMap[parts[2].trim()];
      if (rider == null) continue;

      if (kind == 'PONLINE' && parts.length >= 5) {
        final host = findLine(parts[3].trim(), parts[4].trim());
        if (host != null) {
          engine.constraints.add(PointOnLineConstraint(point: rider, line: host));
        }
      } else if (kind == 'PONCIRCLE' && parts.length >= 5) {
        final host = findCircle(parts[3].trim(), parts[4].trim());
        if (host != null) {
          engine.constraints.add(PointOnCircleConstraint(point: rider, circle: host));
        }
      } else if (kind == 'PONSPIRAL' && parts.length >= 5) {
        final host = findSpiral(parts[3].trim(), parts[4].trim());
        if (host != null) {
          engine.constraints.add(PointOnSpiralConstraint(point: rider, spiral: host));
        }
      }
    }

    if (engine.layers.isNotEmpty) {
      // Don't set the active layer to a locked layer on startup
      for (var l in engine.layers) {
        if (!l.isLocked) {
           engine.activeLayer = l;
           break;
        }
      }
    }
    
    onUpdate();
  }
}