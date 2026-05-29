import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../engine.dart';
import '../models/geometry/point.dart';
import '../models/geometry/shape.dart';
import '../models/geometry/line.dart';
import '../models/geometry/circle.dart';
import '../models/geometry/spiral.dart';
import '../models/geometry/spline.dart';
import '../models/layer.dart';

class ProjectSerializer {
  static String serialize(CompassEngine engine) {
    final buffer = StringBuffer();
    for (var p in engine.points) {
      buffer.writeln('POINT,${p.id},${p.x.value},${p.y.value}');
    }
    
    if (engine.referenceLayer != null) {
      final rl = engine.referenceLayer!;
      buffer.writeln('REF,${rl.imagePath},${rl.isVisible},${rl.isLocked},${rl.offset.dx},${rl.offset.dy},${rl.scale},${rl.rotation}');
    }

    for (var layer in engine.layers) {
      buffer.writeln('LAYER,${layer.id},${layer.name},${layer.isVisible},${layer.isExpanded},${layer.color.value},${layer.strokeColor.value},${layer.strokeWidth}');
      for (var shape in layer.shapes) {
        if (shape is CompassLine) {
          buffer.writeln('SHAPE,LINE,${layer.id},${shape.operation.name},${shape.isVisible},${shape.start.id},${shape.end.id}');
        } else if (shape is CompassCircle) {
          buffer.writeln('SHAPE,CIRCLE,${layer.id},${shape.operation.name},${shape.isVisible},${shape.center.id},${shape.radiusPoint?.id ?? ""}');
        } else if (shape is CompassSpiral) {
          buffer.writeln('SHAPE,SPIRAL,${layer.id},${shape.operation.name},${shape.isVisible},${shape.center.id},${shape.startPoint.id},${shape.isClockwise},${shape.revolutions}');
        } else if (shape is CompassXSpline) {
          final nodesStr = shape.nodes.map((n) => '${n.point.id}:${n.tension.value}').join('|');
          buffer.writeln('SHAPE,XSPLINE,${layer.id},${shape.operation.name},${shape.isVisible},${shape.isClosed},${shape.anchorPoint?.id ?? ""},$nodesStr');
        }
      }
    }
    return buffer.toString();
  }

  static void deserialize(CompassEngine engine, String data, VoidCallback onUpdate) {
    engine.points.clear();
    engine.layers.clear();
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
        layerMap[layer.id] = layer;
        engine.layers.add(layer);
      }
    }

    for (var line in lines) {
      final parts = line.split(',');
      if (parts.isEmpty) continue;
      
      final type = parts[0].trim();
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
          } else if (shapeType == 'SPIRAL') {
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
              if(np.length == 2) {
                final pt = pointMap[np[0]];
                final tension = double.tryParse(np[1]) ?? 1.0;
                if (pt != null) {
                  final node = CompassSplineNode(point: pt, tension: tension);
                  node.tension.addListener(onUpdate); 
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

    if (engine.layers.isNotEmpty) {
      engine.activeLayer = engine.layers.first;
    }
    
    onUpdate();
  }
}