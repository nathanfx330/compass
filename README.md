# Compass

**A constraint-based, parametric graphic design tool built in Flutter.**

---

### The Manifesto
Modern graphic design software is broken. 

When you use Illustrator or any of its inspirations, the software treats you like a painter holding a digital brush. The paradigm is **Direct Manipulation**. You are given a "cursor" and asked to move Bézier handles manually. 

But high-level design is not about *drawing*; it is about establishing **rules, systems, constraints, and relationships**. 

Consider the Apple logo. It is famously speculated to be constructed using the Golden Ratio and intersecting circles. If you try to recreate this in traditional vector software, you have to manually overlap circles and use a "Shape Builder" to cut out the final shape. **The moment you do that, the circles are destroyed.** They become dead, static paths. If you realize one curve needs to be 5% wider, you have to start over. The structural relationship was lost the moment you clicked "merge." 

Traditional graphic design tools use "Smart Guides." But Smart Guides are *transient*. They help you place something once, and then they vanish, leaving behind dead pixels. 

**Compass** is built on a different philosophy: Design is built upon rules, and Compass should respect that with a **Persistent Mathematical Truth.**

In Compass, you do not draw lines or circles. You establish relationships. You state rules: *"Draw Point A. Draw Point B. Make a line between them. Now draw a circle anchored to Point A, and force its radius to always equal the exact distance to Point B."*

If you drag Point A, the line moves, and the circle moves. If you drag Point B, the line stretches, and the circle scales perfectly. You are not pushing dead pixels; you are rigging a 2D system. 

---

### Core Concepts

1. **Points are the Source of Truth:** Shapes do not own their own coordinates. Every shape is merely a visual manifestation of the relationships between underlying mathematical Points.
2. **Constraints over Clicks:** Objects are bound together by unbreakable rules. A radius isn't "100 pixels"—it is a live formula driven by the canvas state.
3. **Parent/Child Relativity:** Moving an anchor point calculates a mathematical delta and pushes that movement down to all dependent geometries, ensuring complex structures move as a single rigid body without ever "grouping" them.
4. **Pure Geometry:** Toggle off the scaffolding to hide the points and rules, revealing only the mathematically perfect design you have constructed.

---

### ✨ Current Features

Compass is rapidly evolving into a desktop-grade parametric engine. It currently supports:

* **Parametric Geometry:** Lines, Circles, perfectly calculated Golden Spirals, and dynamic X-Splines (Catmull-Rom). Use the `A` key to fluidly adjust vertex tension via a global distance tether.
* **Rigid Body Transformations:** Use `Shift+R` to mathematically rotate an entire hierarchical system around a pivot, `R` to rotate a shape locally, or `Shift+Drag` to translate complex shape groupings.
* **Infinite Mathematical Canvas:** Pan infinitely using the middle mouse button and zoom seamlessly without breaking underlying coordinate math.
* **Reference Imagery:** Load, scale, position, and lock underlying raster sketches to trace over with perfect mathematics.
* **Hierarchical Z-Layers:** Create layers, reorder shapes, and assign independent Fill Colors, Stroke Colors, and Stroke Widths. **Lock layers** to freeze underlying scaffolding and safely work on top of complex construction geometry.
* **Live Boolean Engine:** Assign Union, Subtract, Intersect, or "Construction" (invisible guide) rules to any shape, recalculating the master path at 60fps.
* **Scaffolding Toggle:** Right-click the canvas (or use the View menu) to instantly hide all points, rules, and wireframes, leaving only your pure, clean vector geometry.
* **Native `.compass` Serialization:** Save and Open projects directly to your local file system, preserving every mathematical constraint.
* **Advanced SVG Compiler:** Export pure XML-based SVG files. Compass calculates complex bounding boxes and utilizes native SVG `<mask...>` tags to perfectly replicate dynamic Boolean Subtractions for external image viewers.
* **Desktop UI & Themes:** Complete with a native desktop Menu Bar, floating toolbars, contextual right-click menus, and dynamic Light/Dark modes.

---

### ⌨️ Controls & Hotkeys

Compass heavily utilizes keyboard modifiers to keep the UI clean while providing complex mathematical transformations.

**Mouse Controls:**
* **Left Click:** Select shapes, drag points.
* **Right Click:** Context menu for Boolean operations, layer manipulation, converting geometry to splines, and hiding scaffolding.
* **Middle Click & Drag:** Pan the infinite canvas.
* **Scroll Wheel:** Zoom the infinite canvas.

**Keyboard Modifiers:**
* **`Shift + Drag`**: Pan a rigid-body shape hierarchy.
* **`R + Drag`**: Rotate a selected shape or point locally around its centroid.
* **`Shift + R + Drag`**: Rotate an entire hierarchical rigid-body system around the targeted centroid.
* **`A + Drag`**: Target an X-Spline vertex and drag anywhere on the screen to fluidly adjust its Catmull-Rom curve tension.
* **`Ctrl/Cmd + Z`**: Undo mathematical and geometric state changes.

---

### 🏗️ Project Architecture

Compass uses a highly decoupled, feature-driven architecture to ensure scalable mathematics and 60fps rendering:
* `models/geometry/`: The pure data models representing shapes, splines, and points.
* `constraints.dart`: The mathematical rule engine enforcing logic (e.g., Point-on-Circle, Distance-Radius).
* `engine.dart`: The centralized state holder that cascades updates from the models to the UI.
* `io/`: Standalone `.compass` serializers and SVG XML compilers.
* `ui/`: Modular UI panels, dynamic HUDs, and the interactive `CustomPainter` canvas.

---

### Getting Started

Compass is built entirely in **Flutter**, utilizing the reactive UI framework to instantly cascade mathematical updates to the `CustomPainter` canvas.

**To run the application:**
```bash
flutter pub get
flutter run -d linux
```

---

### License

Compass is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. 

This means you are free to use, study, share, and modify the software. However, if you modify the code and distribute it—or offer it as a service over a network (like a web app)—you **must** make your modified source code available to the public under the same AGPL-3.0 license. 

For full terms, see the [LICENSE](LICENSE) file. Copyright (C) 2026 Nathaniel Westveer.