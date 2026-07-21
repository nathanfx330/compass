// /README.md

# Compass

**A constraint-based, parametric graphic design tool built in Flutter for macOS, Windows, and Linux.**

*Compass brings the exactness of parametric design into a fluid, highly accessible graphical interface built for artists. You don't need to write code, balance equations, or understand the underlying geometry. Every living relationship is built visually—just draw, right-click, and drag. The software handles the math; you handle the art.*

---

### 🚀 Why Compass? (The Elevator Pitch)

*   **Parametric Precision, Artist-Friendly UI:** Experience the exactness of unbreakable constraints without spreadsheets or code. Build living mathematical systems visually with intuitive drag-and-drop and right-click gestures.
*   **Relationships over Pixels:** Bind shapes together with unbreakable rules (e.g., *"this circle's radius is exactly the distance between these two points"*). Move one element, and the entire system adapts instantly.
*   **Non-Destructive by Design:** Live Boolean operations, persistent corner pulleys, and dynamic stroke stacks ensure your foundational geometry is never permanently flattened or lost. 
*   **Bridge 2D and 3D Pipelines:** Export to crisp SVGs, retro-filtered PNGs (Dithered & Halftone), or bridge 2D directly into 3D by exporting your flat booleans into `.obj` meshes with perfect hole preservation and custom topology.

---

### The Manifesto

Modern graphic design software is built on mathematics. Every Bézier handle, every alignment guide, and every pathfinder operation is a genuine mathematical idea exposed as a tool. But that is all it is: a collection of isolated tools, each representing its own fragment of the underlying math. There is no shared foundation or unifying model, so the structure you build with one tool dissolves the moment you reach for the next. The mathematics is there. It was simply never designed to cohere.

This becomes most apparent in **direct manipulation**, the cursor and the brush. It is not unique to Illustrator. It is the dominant paradigm behind almost every modern graphics application. Direct manipulation is genuinely the right tool for fine detail. Eventually, a specific vertex has to sit in a specific place, and nothing is more intuitive than simply reaching out and moving it.

The problem is not direct manipulation itself. The problem is that it is the *only* altitude these tools offer.

It is the correct primitive at the leaf level. It excels at moving an individual point or adjusting a single Bézier handle, but it is the wrong organizing principle for an entire design. We have built software that excels at microscopic edits to isolated pieces of geometry, much like editing a novel one character at a time, yet offers almost no way to express the larger structure those details belong to. Making a sweeping structural change often means tediously selecting and dragging dozens of unrelated objects by hand.

Compass was built to introduce the missing altitude. It adds high-level, hierarchical transformations that naturally cascade down into the precise vertex edits that direct manipulation already does well.

High-level design is not about *drawing*. It is about defining **rules, systems, constraints, and relationships**.

Consider the Apple logo. It is famously believed to have been constructed from intersecting circles and Golden Ratio proportions. Recreating that construction in a traditional vector editor means overlapping circles and using a Shape Builder or Pathfinder operation to cut out the final silhouette. The moment you click **Merge**, those circles cease to exist. If you later decide one curve should be five percent wider, there is nothing left to modify. You either rebuild the construction from scratch or manually reshape the finished path. The geometry survives, but the reasoning behind it does not.

This is not a cursor problem. It is a storage problem. Traditional vector software has nowhere to preserve the relationships that produced the design.

The same limitation appears in Smart Guides. They help you position objects once, then disappear. They never become part of the document itself. The alignment exists only during the edit, never as a persistent relationship the software can continue enforcing.

**Compass** is built on a different philosophy. Design is fundamentally relational, and the software should preserve those relationships as **Persistent Mathematical Truth**.

In Compass, you do not merely draw lines and circles. You define how they relate to one another.

*"Create Point A. Create Point B. Draw a line between them. Now create a circle centered on Point A whose radius always equals the distance between A and B."*

Drag Point A and the entire construction moves together. Drag Point B and the line stretch while the circle scales perfectly to maintain its constraint. Nothing needs to be rebuilt because nothing was ever destroyed.

You are not pushing dead pixels around a canvas. You are constructing a living mathematical system. When you eventually reach in to move a single point by hand, that direct edit is simply the lowest altitude of the same system. It is not a separate mode that discards the relationships you have already established.

**Most importantly, building this system is entirely visual.** There are no spreadsheets or property matrices required to link objects. You establish constraints through intuitive graphical gestures, allowing anyone to build robust, scalable vector art.

---

### Core Concepts

1. **Points are the Source of Truth:** Shapes do not own their own coordinates. Every shape is merely a visual manifestation of the relationships between underlying mathematical Points.
2. **Constraints over Clicks:** Objects are bound together by unbreakable rules. A radius isn't "100 pixels"—it is a live formula driven by the canvas state, **established effortlessly via right-click menus and simple drag-and-drop gestures.**
3. **Parent/Child Relativity:** Moving an anchor point calculates a mathematical delta and pushes that movement down to all dependent geometries, ensuring complex structures move as a single rigid body without ever "grouping" them.
4. **Pure Geometry:** Toggle off the scaffolding to hide the points and rules, revealing only the mathematically perfect design you have constructed.

---

### ✨ Current Features

Compass is rapidly evolving into a desktop-grade parametric engine. It currently supports:

* **Parametric Geometry:** Lines, Circles, perfectly calculated Golden Spirals, and dynamic X-Splines. Splines live in two mathematical modes: a *fluid* Catmull-Rom curve whose vertex tension you adjust with the `A` key via a global distance tether, or *explicit* Bézier—right-click any vertex to **Convert to Bézier** and freeze its current tangent into independently draggable in/out handles for exact, asymmetric control. Right-click again to **Reset Handles** and dissolve back into fluid curvature. Conversion is loss-free: the curve never jumps, it simply becomes editable.
* **Live Corner Pulleys:** Bind a spline vertex to a *persistent* corner constraint rather than cutting it. Right-click a vertex to bind it to a **round pulley**—a rope that wraps the corner in a smooth arc, leaving and rejoining the edges tangentially—or a **miter pulley**, the same outward wrap brought to a single sharp point. A pulley is live: drag its rim on the canvas to resize it, or remove it to restore the plain corner, and it survives save/load, undo, and rotation. This is the constraint-engine counterpart to the destructive `F`-key fillet: where a fillet bakes a rounded corner into new, fixed points, a pulley is a rule the vertex carries—the underlying point never moves, so the relationship is never lost.
* **Coons Patch Gradient Meshes:** Convert any Rectangle into a live Gradient Mesh. Built on true **Bicubic Coons Patch** interpolation rather than flat planar math, you can use the `A` key to adjust node tension and seamlessly bow the internal gradient and outer boundary edges. Meshes are fully integrated into the Boolean Engine—drop a Subtract shape over a mesh to non-destructively punch a hole through the color field. Use the `X` key to mathematically slice new rows and columns directly into the grid without breaking structural integrity. Select nodes and use the Custom Color Picker to paint the mesh.
* **Linear Fill Gradients:** Paint any shape with a true linear gradient whose color stops are themselves **Points**—a gradient is not a floating property bolted onto a shape, but a first-class citizen of the same mathematical system as every vertex. Drag a stop anywhere on the canvas and the ramp follows it live; the axis is simply the line from the first stop to the last, and each stop's position along the ramp is its scalar projection onto that axis. Because stops *are* points, the gradient drags, rotates, coheres with its parent shape, serializes, and undoes through the exact same machinery as everything else—there is no bespoke gradient state to keep in sync. Seed a shape with a single stop and it renders as a flat solid; add a second and it blooms into a live ramp. Gradients are lifted into their own Boolean-clipped fill pass, so a Subtract shape carves the color field exactly as it carves geometry. Right-click a shape and choose **Make Gradient** to seed a single stop from its current fill; once present, the shape's menu offers **Add Gradient Stop Here** and **Remove Gradient**, and right-clicking any stop dot gives **Set Gradient Stop Color…** or **Remove Gradient Stop**.
* **Parametric Area Strokes & Width Constraints:** Hold `W` to sculpt variable-width ribbon strokes. Instead of manually smoothing hundreds of points, **Right-click a width handle** to drop a Constraint Flag (turning it orange). Drop two flags, and Compass dynamically calculates the parametric distance between them, fluidly interpolating the width of every node in-between. Dragging a pinned flag mathematically updates the entire tapered section in real-time. 
* **Interactive Drag-and-Drop Hierarchy:** Fully reorderable Z-layers and shapes. Drag a layer to change global Z-order, drag a shape within a layer to dynamically change its Boolean evaluation order, or seamlessly drag a shape across layers to migrate it. **Lock layers** to freeze underlying scaffolding and safely work on top of complex construction geometry.
* **Advanced Stroke Stacking:** Shapes are not limited to a single outline. Build an ordered stack of outward-expanding stroke rings per shape. Each ring acts as an independent Boolean operand—set it to "Fill" with a custom color, or "Cut" to non-destructively carve a gap through the underlying geometry. Drag rings up and down the stack to build complex concentric gaps or tree-ring effects.
* **Live Boolean Engine:** Assign Union, Subtract, Intersect, or "Construction" (invisible guide) rules to any shape or stroke, recalculating the master path at 60fps.
* **Parametric Mirror Modifier:** Enable a live axis of symmetry on any layer and its geometry is reflected across a draggable plane in real time—grab the teal axis handle on the canvas to sweep the line of symmetry and watch the mirrored half recalculate at 60fps. Crucially, the mirror does not stamp out a duplicate; it fuses the master half and its reflection into a *single continuous silhouette*. A gradient laid across a mirrored shape therefore shades that whole fused form cohesively—as if the shape had simply grown into the reflected area, one world-space ramp flowing straight across the seam rather than a folded or duplicated copy of itself. The reflection is honored identically across the live canvas, the PNG raster compiler, and the SVG exporter. The mirror is a per-layer modifier: right-click the empty canvas and choose **Enable Mirror Here** to plant the axis of symmetry at the cursor on the active layer, **Mirror Axis: Vertical → Horizontal** to flip its orientation, or **Disable Mirror** to switch it off.
* **Rigid Body Transformations:** Use `Shift+R` to mathematically rotate an entire hierarchical system around a pivot, `R` to rotate a shape locally, `Ctrl/Cmd+R` to explicitly rotate isolated Bézier handles, or `Shift+Drag` to translate complex shape groupings. Explicit Bézier handles rotate in perfect lockstep with their points, so a hand-tuned corner stays mathematically true through any rotation.
* **Axis-Locked Editing:** Hold `1` or `2` while dragging a vertex to constrain its motion to a single axis—horizontal or vertical—anchored exactly to the point where the drag began, for pixel-true orthogonal moves without guesswork.
* **Infinite Mathematical Canvas:** Pan infinitely using the middle mouse button and zoom seamlessly without breaking underlying coordinate math.
* **Reference Imagery:** Load, scale, position, and lock underlying raster sketches to trace over with perfect mathematics.
* **Bake Layers to Editable Splines:** Right-click any layer to *bake* its live Boolean result into clean, editable X-Splines on a fresh layer above—the source layer is preserved and simply switched off, never destroyed. Because the merged Boolean boundary exists only as an opaque rendered path, Compass samples that outline and reconstructs it with a **least-squares Bézier curve fit**: the output is sparse, smooth, and fully handle-editable, and—unlike a flattened polygon—stays mathematically smooth at *any* zoom level on the infinite canvas. Holes and disjoint islands are faithfully preserved by emitting outer contours as Union and inner contours as Subtract, so the baked silhouette is identical to the original. Only filled geometry is baked; pure strokes and construction guides are correctly ignored. A **mirrored** layer bakes into its single fused silhouette—the reflected half fully included—and any **linear fill gradient** is carried onto the resulting spline with its own fresh, independent stops, so the ramp survives the bake exactly as it appeared live and stays editable on the new layer.
* **Scaffolding Toggle:** Right-click the canvas (or use the View menu) to instantly hide all points, rules, and wireframes, leaving only your pure, clean vector geometry.
* **Ghost Vertices Mode:** Hide the vertex dots while keeping every point fully live. Sweep the cursor along a bare wireframe and each invisible vertex lights up with a hover ring the instant you reach it—points stay clickable, draggable, and box-selectable, and every live tool preview (fillet, tension tether, mesh slice, rubber-banding) still paints. Unlike the full Scaffolding Toggle, which hides *all* construction, Ghost Vertices clears only the dot clutter; pair it with vertex-index labels for a clean "labels only" reading of a dense spline. Toggle it from the empty-canvas right-click menu (**Ghost Vertices (Hide Dots, Keep Editable)**).
* **Native `.compass` Serialization:** Save and Open projects directly to your local file system, preserving every mathematical constraint.
* **3D Mesh Compiler (.obj):** Right-click any layer to export its fully resolved boolean fill as a 2D Wavefront `.obj` mesh. This bridges 2D design directly into 3D/game-engine pipelines (like Blender or Godot) where SVG masks typically fail to handle boolean holes. Features four custom tessellation engines: a **Scanline** algorithm that traces curves robustly for high-fidelity silhouettes, a **Grid** mode that generates uniform quad-based topology perfect for subdivision and displacement, an **Organic** mode that runs a seeded **Delaunay triangulation** (the same Bowyer–Watson math as the in-app Triangulated Spline bake) to produce roughly-equilateral triangles hugging the exact silhouette—the natural topology for organic deformation and wireframe render styles, with a tunable triangle size—and a **Skeleton** mode (Straight Skeleton / Medial Axis Transform) that computes the internal mathematical ridge lines of complex boolean shapes, generating perfect "roof-like" topology for 3D beveling and chiseled edges.
* **Vector & Raster Compilers:** Export pure XML-based SVG files—Compass calculates complex bounding boxes and utilizes native SVG `<mask...>` tags to perfectly replicate dynamic Boolean Subtractions for external image viewers. Linear gradients export as native `userSpaceOnUse` `<linearGradient>` definitions, and a mirrored layer is reflected with a transformed `<use>` instantiation—so those gradients, masks, and mesh clips all mirror *together* with the geometry, exactly as they do on the canvas. For pixel-based workflows, export crisp **PNG** images at preset or custom fractional resolutions (e.g., 0.5x, 4x); the raster compiler re-renders the design offscreen from the same mathematical truth, emitting only the clean geometry on a transparent background. The PNG exporter also features advanced post-processing modes: **Floyd-Steinberg Dithering** for a retro 1-bit quantized aesthetic, and **Bubble Jet (Halftone)**, which converts shading into scaled ink dots. Both effects fully support Alpha transparency and can be rendered in full color or true grayscale.
* **Desktop UI & Themes:** Complete with a native desktop Menu Bar, floating toolbars, contextual right-click menus, and dynamic Light/Dark modes.

---

### ⌨️ Controls & Hotkeys

Compass heavily utilizes keyboard modifiers to keep the UI clean while providing complex mathematical transformations.

**Mouse Controls:**
* **Left Click:** Select shapes, drag points. Drag the purple in/out dots of a Bézier vertex to sculpt its curve handles directly.
* **Right Click:** Context menu for Boolean operations, baking a layer into editable X-Splines, exporting to OBJ, converting geometry to splines/meshes, converting a vertex to or from Bézier handles, **binding a corner to a round or miter pulley**, toggling parametric width constraint flags, **making a gradient and adding, coloring, or removing its stops**, **enabling a per-layer mirror and flipping its axis**, and toggling scaffolding, handles, or **Ghost Vertices**.
* **Drag a Pulley Rim:** With a spline selected, drag the colored rim handle of a bound corner pulley to resize it live—light blue for a round pulley, orange for a miter. The underlying point never moves; only the constraint's size changes.
* **Drag the Mirror Axis:** With a layer's Mirror Modifier enabled, grab the teal axis line (or its center handle) to slide the plane of symmetry—the reflected geometry, and any gradient shading it, updates live as you drag.
* **Drag a Gradient Stop:** With a gradient shape selected, its color stops appear as ringed dots joined by a dashed axis line. Drag any stop to reshape the ramp; because stops are ordinary points, they also respond to axis-locking and rotation like any other vertex.
* **Middle Click & Drag:** Pan the infinite canvas.
* **Scroll Wheel:** Zoom the infinite canvas.
* **Drag in Hierarchy Panel:** Grab the indicator dot next to a layer or shape to dynamically reorder Z-index, restack boolean logic, or move geometry between layers.

**Keyboard Modifiers:**
* **`Shift + Drag`**: Pan a rigid-body shape hierarchy.
* **`R + Drag`**: Rotate a selected shape or point locally around its centroid.
* **`Shift + R + Drag`**: Rotate an entire hierarchical rigid-body system around the targeted centroid.
* **`Ctrl/Cmd + R + Drag`**: Rotate the explicit Bézier handles of a selected vertex (or group of vertices) around their local centroid without moving the underlying points. Automatically converts fluid Catmull-Rom nodes to explicit handles.
* **`A + Drag`**: Target an X-Spline or Gradient Mesh vertex and drag anywhere on the screen to fluidly adjust its structural tension.
* **`W + Drag`**: Target an X-Spline vertex and drag to adjust its variable stroke width. Shift+Drag to symmetrically scale both sides. Right-click the width handle to drop an Orange Width Constraint flag for automatic parametric tapering.
* **`F + Drag`**: With an X-Spline vertex selected, hold F and drag horizontally anywhere on the screen to dynamically apply a curve-aware fillet (corner rounding). Unlike a corner pulley, a fillet is destructive—it bakes the rounded corner into fixed points.
* **`X + Hover / Click`**: Hover over a Gradient Mesh to preview a slice. Compass auto-detects horizontal or vertical cuts based on edge proximity. Click to commit the topological slice without altering the visual gradient.
* **`Z + Drag`**: Select multiple nodes, hold Z, and drag to Laplacian smooth them. Hold `Shift+Z` to smooth variable widths.
* **`1 + Drag`**: Constrain a point or vertex drag to the **horizontal** axis. When using the `X` mesh slice tool, hold `1` to explicitly force a Horizontal (Row) cut.
* **`2 + Drag`**: Constrain a point or vertex drag to the **vertical** axis. When using the `X` mesh slice tool, hold `2` to explicitly force a Vertical (Column) cut.
* **`Ctrl/Cmd + Z`**: Undo mathematical and geometric state changes.

---

### 🏗️ Project Architecture

Compass uses a highly decoupled, feature-driven architecture to ensure scalable mathematics and 60fps rendering:
* `models/geometry/`: The pure data models representing shapes, splines, meshes, gradients, and points.
* `constraints.dart`: The mathematical rule engine enforcing logic (e.g., Point-on-Circle, Distance-Radius).
* `hierarchy_ops.dart`: Safely mutates Z-order and layer containment without breaking constraints.
* `engine.dart`: The centralized state holder that cascades updates from the models to the UI.
* `path_baker.dart`: Reconstructs editable Bézier geometry from opaque rendered Boolean paths via least-squares curve fitting—the math behind Layer Baking.
* `io/`: Standalone serializers and compilers—the `.compass` project format, the SVG XML exporter, the offscreen PNG raster exporter, and the OBJ mesh tessellator with its pure geometry kernels (`delaunay.dart` for Bowyer–Watson triangulation, `medial_axis.dart` for skeleton extraction).
* `ui/`: Modular UI panels (`layer_tile.dart`, `shape_row.dart`), pure-Dart color pickers, dynamic HUDs, and the interactive `CustomPainter` canvas.

---

### Getting Started

Compass is built entirely in **Flutter**, utilizing the reactive UI framework to instantly cascade mathematical updates to the `CustomPainter` canvas.

**To run the application:**
```bash
flutter pub get
# Run on your respective desktop platform:
flutter run -d macos
flutter run -d windows
flutter run -d linux
```

---

### License

Compass is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**. 

This means you are free to use, study, share, and modify the software. However, if you modify the code and distribute it—or offer it as a service over a network (like a web app)—you **must** make your modified source code available to the public under the same AGPL-3.0 license. 

For full terms, see the [LICENSE](LICENSE) file. Copyright (C) 2026 Nathaniel Westveer.