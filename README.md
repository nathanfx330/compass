# Compass

**A constraint-based, parametric graphic design tool built in Flutter.**

---

### The Manifesto
Modern graphic design software is broken. 

When you use Illustrator or any of its inspirations, the software treats you like a painter holding a digital brush. The paradigm is **Direct Manipulation**. But it isn't just Illustrator—it is the mindset of almost all digital software. We build human interfaces around a mouse, interacting through a cursor or Bézier handles. This is great for detail work, but we fail to provide the scaffolding to move from the abstract to the specific. 

The cursor represents the specific: making micro-changes to tiny fragments of a project, much like editing a word document character by character. Traditional software makes it incredibly difficult to orchestrate large, structural moves without tedious, manual UI selections. Compass was built to reverse this: abstracting from high-level hierarchical transformations all the way down to specific vertex edits.

High-level design is not about *drawing*; it is about establishing **rules, systems, constraints, and relationships**. 

Consider the Apple logo. It is famously speculated to be constructed using the Golden Ratio and intersecting circles. If you try to recreate this in traditional vector software, you have to manually overlap circles and use a "Shape Builder" to cut out the final shape. **The moment you do that, the circles are destroyed** for the new unified shape. If you realize one curve needs to be 5% wider, you have to start over. The structural relationship was lost the moment you clicked "merge." 

Traditional graphic design tools use "Smart Guides." But Smart Guides are *transient*. They help you place something once, but they are absent of meaningful relational rules. You can't establish any meaningful relative relationships with the rest of your splines.

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

* **Parametric Geometry:** Lines, Circles, perfectly calculated Golden Spirals, and dynamic X-Splines. Splines live in two mathematical modes: a *fluid* Catmull-Rom curve whose vertex tension you adjust with the `A` key via a global distance tether, or *explicit* Bézier—right-click any vertex to **Convert to Bézier** and freeze its current tangent into independently draggable in/out handles for exact, asymmetric control. Right-click again to **Reset Handles** and dissolve back into fluid curvature. Conversion is loss-free: the curve never jumps, it simply becomes editable.
* **Coons Patch Gradient Meshes:** Convert any Rectangle into a live Gradient Mesh. Built on true **Bicubic Coons Patch** interpolation rather than flat planar math, you can use the `A` key to adjust node tension and seamlessly bow the internal gradient and outer boundary edges. Meshes are fully integrated into the Boolean Engine—drop a Subtract shape over a mesh to non-destructively punch a hole through the color field. Use the `X` key to mathematically slice new rows and columns directly into the grid without breaking structural integrity.
* **Parametric Area Strokes & Width Constraints:** Hold `W` to sculpt variable-width ribbon strokes. Instead of manually smoothing hundreds of points, **Right-click a width handle** to drop a Constraint Flag (turning it orange). Drop two flags, and Compass dynamically calculates the parametric distance between them, fluidly interpolating the width of every node in-between. Dragging a pinned flag mathematically updates the entire tapered section in real-time. 
* **Rigid Body Transformations:** Use `Shift+R` to mathematically rotate an entire hierarchical system around a pivot, `R` to rotate a shape locally, `Ctrl/Cmd+R` to explicitly rotate isolated Bézier handles, or `Shift+Drag` to translate complex shape groupings. Explicit Bézier handles rotate in perfect lockstep with their points, so a hand-tuned corner stays mathematically true through any rotation.
* **Axis-Locked Editing:** Hold `1` or `2` while dragging a vertex to constrain its motion to a single axis—horizontal or vertical—anchored exactly to the point where the drag began, for pixel-true orthogonal moves without guesswork.
* **Infinite Mathematical Canvas:** Pan infinitely using the middle mouse button and zoom seamlessly without breaking underlying coordinate math.
* **Reference Imagery:** Load, scale, position, and lock underlying raster sketches to trace over with perfect mathematics.
* **Hierarchical Z-Layers:** Create layers, reorder shapes, and assign independent Fill Colors, Stroke Colors, and Stroke Widths. **Lock layers** to freeze underlying scaffolding and safely work on top of complex construction geometry.
* **Live Boolean Engine:** Assign Union, Subtract, Intersect, or "Construction" (invisible guide) rules to any shape, recalculating the master path at 60fps.
* **Bake Layers to Editable Splines:** Right-click any layer to *bake* its live Boolean result into clean, editable X-Splines on a fresh layer above—the source layer is preserved and simply switched off, never destroyed. Because the merged Boolean boundary exists only as an opaque rendered path, Compass samples that outline and reconstructs it with a **least-squares Bézier curve fit**: the output is sparse, smooth, and fully handle-editable, and—unlike a flattened polygon—stays mathematically smooth at *any* zoom level on the infinite canvas. Holes and disjoint islands are faithfully preserved by emitting outer contours as Union and inner contours as Subtract, so the baked silhouette is identical to the original. Only filled geometry is baked; pure strokes and construction guides are correctly ignored.
* **Scaffolding Toggle:** Right-click the canvas (or use the View menu) to instantly hide all points, rules, and wireframes, leaving only your pure, clean vector geometry.
* **Native `.compass` Serialization:** Save and Open projects directly to your local file system, preserving every mathematical constraint.
* **3D Mesh Compiler (.obj):** Right-click any layer to export its fully resolved boolean fill as a 2D Wavefront `.obj` mesh. This bridges 2D design directly into 3D/game-engine pipelines (like Blender or Godot) where SVG masks typically fail to handle boolean holes. Features two custom tessellation engines: a **Scanline** algorithm that traces curves robustly for high-fidelity silhouettes, and a **Grid** mode that generates uniform quad-based topology perfect for subdivision and displacement.
* **Vector & Raster Compilers:** Export pure XML-based SVG files—Compass calculates complex bounding boxes and utilizes native SVG `<mask...>` tags to perfectly replicate dynamic Boolean Subtractions for external image viewers. For pixel-based workflows, export crisp **PNG** images at 1x, 2x, or 4x resolution; the raster compiler re-renders the design offscreen from the same mathematical truth, emitting only the clean geometry on a transparent background—never the scaffolding.
* **Desktop UI & Themes:** Complete with a native desktop Menu Bar, floating toolbars, contextual right-click menus, and dynamic Light/Dark modes.

---

### ⌨️ Controls & Hotkeys

Compass heavily utilizes keyboard modifiers to keep the UI clean while providing complex mathematical transformations.

**Mouse Controls:**
* **Left Click:** Select shapes, drag points. Drag the purple in/out dots of a Bézier vertex to sculpt its curve handles directly. Right-click a Gradient Mesh node to change its color.
* **Right Click:** Context menu for Boolean operations, baking a layer into editable X-Splines, exporting to OBJ, converting geometry to splines/meshes, converting a vertex to or from Bézier handles, **toggling parametric width constraint flags**, and hiding scaffolding.
* **Middle Click & Drag:** Pan the infinite canvas.
* **Scroll Wheel:** Zoom the infinite canvas.

**Keyboard Modifiers:**
* **`Shift + Drag`**: Pan a rigid-body shape hierarchy.
* **`R + Drag`**: Rotate a selected shape or point locally around its centroid.
* **`Shift + R + Drag`**: Rotate an entire hierarchical rigid-body system around the targeted centroid.
* **`Ctrl/Cmd + R + Drag`**: Rotate the explicit Bézier handles of a selected vertex (or group of vertices) around their local centroid without moving the underlying points. Automatically converts fluid Catmull-Rom nodes to explicit handles.
* **`A + Drag`**: Target an X-Spline or Gradient Mesh vertex and drag anywhere on the screen to fluidly adjust its structural tension.
* **`W + Drag`**: Target an X-Spline vertex and drag to adjust its variable stroke width. Shift+Drag to symmetrically scale both sides. Right-click the width handle to drop an Orange Width Constraint flag for automatic parametric tapering.
* **`F + Drag`**: With an X-Spline vertex selected, hold F and drag horizontally anywhere on the screen to dynamically apply a curve-aware fillet (corner rounding).
* **`X + Hover / Click`**: Hover over a Gradient Mesh to preview a slice. Compass auto-detects horizontal or vertical cuts based on edge proximity. Click to commit the topological slice without altering the visual gradient.
* **`Z + Drag`**: Select multiple nodes, hold Z, and drag to Laplacian smooth them. Hold `Shift+Z` to smooth variable widths.
* **`1 + Drag`**: Constrain a point or vertex drag to the **horizontal** axis. When using the `X` mesh slice tool, hold `1` to explicitly force a Horizontal (Row) cut.
* **`2 + Drag`**: Constrain a point or vertex drag to the **vertical** axis. When using the `X` mesh slice tool, hold `2` to explicitly force a Vertical (Column) cut.
* **`Ctrl/Cmd + Z`**: Undo mathematical and geometric state changes.

---

### 🏗️ Project Architecture

Compass uses a highly decoupled, feature-driven architecture to ensure scalable mathematics and 60fps rendering:
* `models/geometry/`: The pure data models representing shapes, splines, and points.
* `constraints.dart`: The mathematical rule engine enforcing logic (e.g., Point-on-Circle, Distance-Radius).
* `engine.dart`: The centralized state holder that cascades updates from the models to the UI.
* `path_baker.dart`: Reconstructs editable Bézier geometry from opaque rendered Boolean paths via least-squares curve fitting—the math behind Layer Baking.
* `io/`: Standalone serializers and compilers—the `.compass` project format, the SVG XML exporter, the offscreen PNG raster exporter, and the OBJ mesh tessellator.
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
```