import 'dart:ui' as ui;

/// The Reference Image Layer
class CompassReferenceLayer {
  String imagePath;
  ui.Image? image;
  
  bool isVisible = true;
  bool isLocked = true; 
  
  ui.Offset offset = ui.Offset.zero;
  double scale = 1.0;
  double rotation = 0.0;

  CompassReferenceLayer({required this.imagePath});
}