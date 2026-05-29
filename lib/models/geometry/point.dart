import 'package:flutter/foundation.dart';

/// The fundamental building block.
class CompassPoint {
  final String id;
  final ValueNotifier<double> x;
  final ValueNotifier<double> y;

  bool isBeingDragged = false;
  final List<CompassPoint> attachedPoints = [];

  CompassPoint({required double x, required double y, String? id})
      : id = id ?? UniqueKey().toString(),
        x = ValueNotifier(x),
        y = ValueNotifier(y);

  void attach(CompassPoint child) {
    if (!attachedPoints.contains(child)) {
      attachedPoints.add(child);
    }
  }

  void detach(CompassPoint child) {
    attachedPoints.remove(child);
  }

  void moveBy(double dx, double dy, {Set<CompassPoint>? visited}) {
    visited ??= <CompassPoint>{};
    if (visited.contains(this)) return;
    visited.add(this);

    x.value += dx;
    y.value += dy;

    for (var child in attachedPoints) {
      child.moveBy(dx, dy, visited: visited); 
    }
  }
}