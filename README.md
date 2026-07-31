# Compass

**A constraint-based, parametric graphic design tool built in Flutter for macOS, Windows, and Linux.**

*Compass brings the exactness of parametric design into a fluid, highly accessible graphical interface built for artists. You don't need to write code, balance equations, or understand the underlying geometry. Every living relationship is built visually—just draw, right-click, and drag. The software handles the math; you handle the art.*

---

###  Why Compass? (The Elevator Pitch)

*   **Parametric Precision, Artist-Friendly UI:** Experience the exactness of unbreakable constraints without spreadsheets or code. Build living mathematical systems visually with intuitive drag-and-drop and right-click gestures.
*   **Relationships over Pixels:** Bind shapes together with unbreakable rules (e.g., *"this circle's radius is exactly the distance between these two points"*). Move one element, and the entire system adapts instantly.
*   **Non-Destructive by Design:** Live Boolean operations, persistent corner pulleys, and dynamic stroke stacks ensure your foundational geometry is never permanently flattened or lost.
*   **Raster Meets Parametric:** Import a PNG or JPG as an **IMG object** and it becomes a first-class citizen of the Boolean walk—carve it with circles and splines, and the pixels are masked live. Nothing is ever baked into the image.
*   **Bridge 2D and 3D Pipelines:** Export to crisp SVGs, retro-filtered PNGs (Dithered & Halftone), or bridge 2D directly into 3D by exporting your flat booleans into `.obj` meshes with perfect hole preservation, custom topology, and optional **UV-mapped image textures**.

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
5. **Even Pixels Are Geometry:** A raster image is not an opaque rectangle pasted on top of the artwork. Its frame is three live Points, and its visible extent is whatever the Boolean walk resolves it to—so a photograph obeys the same rules as a circle.

---

###  Current Features

Compass is rapidly evolving into a desktop-grade parametric engine. It currently supports:

* **Parametric Geometry:** Lines, Circles, perfectly calculated Golden Spirals, and dynamic X-Splines. Splines live in two mathematical modes: a *fluid* Catmull-Rom curve whose vertex tension you adjust with the `A` key via a global distance tether, or *explicit* Bézier—right-click any vertex to **Convert to Bézier** and freeze its current tangent into independently draggable in/out handles for exact, asymmetric control. Right-click again to **Reset Handles** and dissolve back into fluid curvature. Conversion is loss-free: the curve never jumps, it simply becomes editable. Tap `S` on any selection of vertices to toggle them between a razor-sharp corner (zero tension, handles cleared, pulleys dissolved) and fluid curvature.
* **IMG Objects (Parametric Image Planes):** Import a PNG or JPG and it arrives as an ordinary ordered object in the hierarchy—not a locked backdrop. Its position is an **affine frame of three real Points**: an origin plus an X-edge and Y-edge handle, with the fourth corner derived. Because those are ordinary Points, an image translates, rotates, scales, and even *skews* through the exact same drag, `R`-rotate, and rigid-body machinery as every vertex in the document, and it participates in the attachment graph so it can be bound to other geometry. A per-object opacity slider lives in the Properties panel. The decoded pixels are runtime-only: the `.compass` file stores the path and the frame, so projects stay tiny and the image is re-linked on load.
* **Live Image Masking (Boolean Pixels):** An IMG object is a genuine Boolean operand, and the shapes stacked above it decide what survives. Compass resolves the mask as a **set** rather than a sequential chain: every later `Intersect` operand is unioned into one keep-region, and every later `Subtract` operand is unioned into one cut-region, giving `(image ∩ ⋃intersects) − ⋃subtracts`. That set interpretation is what lets a *disconnected* mask work—a logo body and its detached leaf, or three unrelated circles, keep all their pieces instead of annihilating each other the way a naïve left-to-right intersect chain would. Later `Add` shapes are not mask contributors; they simply paint over the image as ordinary foreground objects, and the image's paint clip is trimmed against them so Z-order reads correctly. Nothing is destructive: drag the cutter and the pixels re-mask at 60fps.
* **Live Corner Pulleys:** Bind a spline vertex to a *persistent* corner constraint rather than cutting it. Right-click a vertex to bind it to a **round pulley**—a rope that wraps the corner in a smooth arc, leaving and rejoining the edges tangentially—or a **miter pulley**, the same outward wrap brought to a single sharp point. A pulley is live: drag its rim on the canvas to resize it, or remove it to restore the plain corner, and it survives save/load, undo, and rotation. This is the constraint-engine counterpart to the destructive `F`-key fillet: where a fillet bakes a rounded corner into new, fixed points, a pulley is a rule the vertex carries—the underlying point never moves, so the relationship is never lost.
* **Coons Patch Gradient Meshes:** Convert any Rectangle into a live Gradient Mesh. Built on true **Bicubic Coons Patch** interpolation rather than flat planar math, you can use the `A` key to adjust node tension and seamlessly bow the internal gradient and outer boundary edges. Use the `X` key to mathematically slice new rows and columns directly into the grid without breaking structural integrity. Select nodes and use the Custom Color Picker to paint the mesh. **A mesh owns its layer:** converting a Rectangle moves the resulting mesh onto a fresh layer directly above the source, and shapes sharing that layer may only *carve* it—Subtract and Intersect are offered, Add is not. This is a deliberate model rather than a limitation. A mesh is a layer's *appearance*, closer to the layer fill color than to a circle: it never contributes a silhouette to the Boolean walk, its own operation is never read, and it paints last. Isolating it dissolves the "which one is on top" question instead of answering it inconsistently—and cross-layer stacking, already well-defined and draggable, covers the case where you genuinely want flat geometry above a mesh.
* **Linear & Circular Fill Gradients:** Paint any ordinary shape with a true multi-stop gradient whose controls are themselves **Points**—the gradient lives in the same geometric world as every vertex instead of floating in a detached properties panel. Right-click a shape and choose **Make Gradient** to seed its base stop from the current fill; place the second stop to establish the guide, then right-click anywhere on that dashed guide to insert additional stops without changing the artwork's current appearance. The first and last stops are free geometry handles: in **Linear** mode they define the direction and extent of the ramp, while in **Circular** mode the first stop becomes the center and the last controls the radius. Interior stops are constrained sliders that move only along the guide, preserving an ordered, readable color ramp even while the endpoints are repositioned. Right-click the base stop to switch between **Linear Gradient** and **Circular Gradient**, and right-click any stop to recolor or remove it. Gradient fills participate in the live Boolean system, respect shape Z-order instead of jumping above later geometry, move and rotate with their parent shape, and preserve their stops and active type through the current `.compass` save and undo pipeline.
* **Parametric Area Strokes & Width Constraints:** Hold `W` to sculpt variable-width ribbon strokes. Instead of manually smoothing hundreds of points, **Right-click a width handle** to drop a Constraint Flag (turning it orange). Drop two flags, and Compass dynamically calculates the parametric distance between them, fluidly interpolating the width of every node in-between. Dragging a pinned flag mathematically updates the entire tapered section in real-time.
* **Interactive Drag-and-Drop Hierarchy:** Fully reorderable Z-layers and shapes. Drag a layer to change global Z-order, drag a shape within a layer to dynamically change its Boolean evaluation order, or seamlessly drag a shape across layers to migrate it. Flat fills, gradient fills, image pixels, meshes, strokes, and Boolean cutters all honor that visible ordering, so a lower gradient cannot overpaint an ordinary shape above it. Layers can be **renamed inline** (double-click the name) and **locked** to freeze underlying scaffolding while you work on top of complex construction geometry.
* **Universal Stroke Stacking:** Shapes are not limited to a single outline. Build an ordered stack of outward-expanding stroke rings on **Circles, Rectangles, and X-Splines alike**—each primitive supplies an exact parallel offset for its own silhouette (a true annulus for a circle, a radius-corrected expanded round-rect for a rectangle, and a sampled outward dilation of the resolved curve or variable-width ribbon for a spline). Each ring is an independent Boolean operand: set it to **Fill** with its own custom color, or **Cut** to non-destructively carve a gap through the underlying geometry. Rings butt against one another with no gaps or overlaps, and can be restacked inward and outward from the hierarchy panel to build concentric gaps or tree-ring effects. Rings also **reflow after the Boolean walk**—when a later shape carves the geometry a ring belongs to, the ring re-wraps the newly created contour instead of tracing the original uncut silhouette.
* **Live Boolean Engine:** Assign Union, Subtract, Intersect, or "Construction" (invisible guide) rules to any shape, stroke ring, or image, recalculating the master path at 60fps. Layer resolution is signature-cached, so panning, hovering, and tool previews reuse the resolved Boolean result instead of recomputing it every frame.
* **Parametric Mirror Modifier:** Enable a live axis of symmetry on any layer and its geometry is reflected across a draggable plane in real time—grab the teal axis handle on the canvas to sweep the line of symmetry and watch the mirrored half recalculate at 60fps. Crucially, the mirror does not stamp out a duplicate; it fuses the master half and its reflection into a *single continuous silhouette*. A gradient laid across a mirrored shape therefore shades that whole fused form cohesively—as if the shape had simply grown into the reflected area, one world-space ramp flowing straight across the seam rather than a folded or duplicated copy of itself. The reflection is honored identically across the live canvas, the PNG raster compiler, and the SVG exporter. The mirror is a per-layer modifier: right-click the empty canvas and choose **Enable Mirror Here** to plant the axis of symmetry at the cursor on the active layer, **Mirror Axis: Vertical → Horizontal** to flip its orientation, or **Disable Mirror** to switch it off.
* **Rigid Body Transformations:** Use `Shift+R` to mathematically rotate an entire hierarchical system around a pivot, `R` to rotate a shape locally, `Ctrl/Cmd+R` to explicitly rotate isolated Bézier handles, or `Shift+Drag` to translate complex shape groupings. Explicit Bézier handles rotate in perfect lockstep with their points, so a hand-tuned corner stays mathematically true through any rotation.
* **Axis-Locked Editing:** Hold `1` or `2` while dragging a vertex to constrain its motion to a single axis—horizontal or vertical—anchored exactly to the point where the drag began, for pixel-true orthogonal moves without guesswork.
* **Infinite Mathematical Canvas:** Pan infinitely using the middle mouse button and zoom seamlessly without breaking underlying coordinate math.
* **Native Image Picking:** Import IMG objects and choose reference imagery through the operating system's native file picker on macOS, Windows, and Linux, filtered to PNG/JPG files.
* **Reference Imagery:** Load, scale, position, and lock an underlying raster sketch to trace over with perfect mathematics. (Distinct from an IMG object: a reference image is a pinned, non-Boolean backdrop that never exports.)
* **Bake Layers to Editable Splines:** Right-click any layer to *bake* its live Boolean result into clean, editable X-Splines on a fresh layer above—the source layer is preserved and simply switched off, never destroyed. Because the merged Boolean boundary exists only as an opaque rendered path, Compass samples that outline and reconstructs it with a **least-squares Bézier curve fit**: the output is sparse, smooth, and fully handle-editable, and—unlike a flattened polygon—stays mathematically smooth at *any* zoom level on the infinite canvas. Holes and disjoint islands are faithfully preserved by emitting outer contours as Union and inner contours as Subtract, so the baked silhouette is identical to the original. A **mirrored** layer bakes into its single fused silhouette—the reflected half fully included—and any **fill gradient** is carried onto the resulting spline with its own fresh, independent stops, so the ramp survives the bake exactly as it appeared live and stays editable on the new layer. An IMG object contributes its *resolved mask outline* to the bake, so you can convert a photo's carved silhouette into editable vector geometry.
* **Bake to Triangulated Spline:** A second bake mode that fills the layer's resolved silhouette with a seeded Delaunay point cloud and walks the resulting graph into one continuous "Sci-Fi veins" spline—an instant wireframe/circuitry treatment of any solid shape.
* **Scaffolding Toggle:** Right-click the canvas (or use the View menu) to instantly hide all points, rules, and wireframes, leaving only your pure, clean vector geometry.
* **Ghost Vertices Mode:** Hide the vertex dots while keeping every point fully live. Sweep the cursor along a bare wireframe and each invisible vertex lights up with a hover ring the instant you reach it—points stay clickable, draggable, and box-selectable, and every live tool preview (fillet, tension tether, mesh slice, rubber-banding) still paints. Unlike the full Scaffolding Toggle, which hides *all* construction, Ghost Vertices clears only the dot clutter; pair it with vertex-index labels for a clean "labels only" reading of a dense spline. Toggle it from the empty-canvas right-click menu (**Ghost Vertices (Hide Dots, Keep Editable)**).
* **Native `.compass` Serialization:** Save and Open projects directly to your local file system, preserving every mathematical constraint, attachment edge, gradient stop, stroke ring, mirror axis, and IMG frame. The format is forward- and backward-compatible: new fields ride the end of existing lines, so older files load unchanged and older builds ignore what they do not recognize.
* **3D Mesh Compiler (.obj):** Right-click any layer to export its fully resolved boolean fill as a 2D Wavefront `.obj` mesh. This bridges 2D design directly into 3D/game-engine pipelines (like Blender or Godot) where SVG masks typically fail to handle boolean holes. Features four custom tessellation engines: a **Scanline** algorithm that traces curves robustly for high-fidelity silhouettes, a **Grid** mode that generates uniform quad-based topology perfect for subdivision and displacement, an **Organic** mode that runs a seeded **Delaunay triangulation** (the same Bowyer–Watson math as the in-app Triangulated Spline bake) to produce roughly-equilateral triangles hugging the exact silhouette—the natural topology for organic deformation and wireframe render styles, with a tunable triangle size—and a **Skeleton** mode (Straight Skeleton / Medial Axis Transform) that computes the internal mathematical ridge lines of complex boolean shapes, generating perfect "roof-like" topology for 3D beveling and chiseled edges.
* **Multi-Material OBJ Export (Layer Appearance):** The OBJ dialog can carry a layer's entire *look* into the mesh, not just its silhouette. The insight is that every fill Compass paints is a pure function of world position, and therefore a UV projection: a flat fill is a constant, a gradient is its own `projectPosition()` (linear and circular alike), and an IMG is its affine frame inverted. Each becomes a **disjoint material region**—flat fill, per-shape gradients, variable-width stroke areas, colored stroke bands, gradient meshes, and IMG masks—and Compass writes a portable package: an `.obj` with `usemtl` groups, a companion `.mtl`, and one small texture per textured region. Gradients bake to a **1-D ramp** sampled along their own axis, so the color is mathematically exact at any mesh scale and costs about a kilobyte rather than a megapixel; gradient meshes bake to a **2-D Coons patch** with a planar unwrap; IMG objects reuse the exact affine projection below. Regions are made mutually exclusive in paint order before tessellation, so coplanar faces can never Z-fight, and every UV is inset to texel centres so bilinear filtering never samples across the wrap seam. Gradient meshes export here even though the geometry-only path skips them. Every export appends a full diagnostic trace to `compass_export_log.txt`—per-region decisions, triangle counts, and the outcome—so a "nothing to export" result names the test that rejected each shape instead of leaving you guessing.
* **Textured OBJ Export (UV-Mapped Image Planes):** When a layer contains a visible IMG object, the OBJ dialog also offers it as the export's sole material. Compass then writes an `.obj` whose **mesh boundary is the image's resolved Boolean mask** (a circle-intersected photo exports as a circular mesh, not a rectangle with a painted-on circle), a companion `.mtl`, and a copy of the source image beside them. Every emitted vertex is projected back through the IMG object's affine frame to generate a matching `vt` coordinate, so the texture lands in perfect registration no matter which tessellation mode built the triangles. Transparent PNGs additionally emit a `map_d` alpha map, and per-object opacity is carried through as the material's `d` value. Skeleton mode is excluded from both textured paths (it emits loose edges, not faces). Mirrored layers are excluded from *IMG* texturing—a fused mirror silhouette needs a UV-seam pass that has not landed yet—but Layer Appearance still exports their flat and gradient regions correctly, since a world-space ramp flows across the seam unchanged.
* **Vector & Raster Compilers:** Export pure XML-based SVG files—Compass calculates complex bounding boxes and utilizes native SVG `<mask...>` tags to perfectly replicate dynamic Boolean Subtractions for external image viewers. Gradients export as native `userSpaceOnUse` `<linearGradient>` and `<radialGradient>` definitions, and a mirrored layer is reflected with a transformed `<use>` instantiation—so those gradients, masks, and mesh clips all mirror *together* with the geometry, exactly as they do on the canvas. For pixel-based workflows, export crisp **PNG** images at preset or custom fractional resolutions (e.g., 0.5x, 4x); the raster compiler re-renders the design offscreen from the same mathematical truth, emitting only the clean geometry on a transparent background. The PNG exporter also features advanced post-processing modes: **Floyd-Steinberg Dithering** for a retro 1-bit quantized aesthetic, and **Bubble Jet (Halftone)**, which converts shading into scaled ink dots. Both effects fully support Alpha transparency and can be rendered in full color or true grayscale.
* **ASCII Art Compiler:** Render the entire document into a text file using a 70-character luminance ramp, with optional inversion for dark terminals and optional Floyd-Steinberg dithering to smooth gradients into dot patterns.
* **Desktop UI & Themes:** Complete with a native desktop Menu Bar, floating toolbars, contextual right-click menus, a fully customizable theme system (Light / Dim / Dark backgrounds per theme, persisted to disk), and a Debug menu with a live frame-timing overlay.

---

### ⌨️ Controls & Hotkeys

Compass heavily utilizes keyboard modifiers to keep the UI clean while providing complex mathematical transformations.

**Mouse Controls:**
* **Left Click:** Select shapes, drag points. Drag the purple in/out dots of a Bézier vertex to sculpt its curve handles directly.
* **Right Click:** Context menu for Boolean operations, baking a layer into editable X-Splines, exporting to OBJ, converting geometry to splines/meshes, converting a vertex to or from Bézier handles, **binding a corner to a round or miter pulley**, toggling parametric width constraint flags, **making a gradient, inserting stops on its guide, switching its base node between Linear and Circular, recoloring stops, or removing them**, **enabling a per-layer mirror and flipping its axis**, and toggling scaffolding, handles, or **Ghost Vertices**.
* **Drag an IMG Frame Point:** Drag the origin to translate the whole image; drag the X or Y edge handle to scale, rotate, or skew the raster in place. The pixels resample live and the Boolean mask follows the frame.
* **Drag a Pulley Rim:** With a spline selected, drag the colored rim handle of a bound corner pulley to resize it live—light blue for a round pulley, orange for a miter. The underlying point never moves; only the constraint's size changes.
* **Drag the Mirror Axis:** With a layer's Mirror Modifier enabled, grab the teal axis line (or its center handle) to slide the plane of symmetry—the reflected geometry, and any gradient shading it, updates live as you drag.
* **Drag a Gradient Stop:** With a gradient shape selected, its stops appear along a dashed editing guide. Drag either endpoint freely to redefine the linear axis or circular center/radius; existing interior stops retain their normalized positions as the guide changes. Drag an interior stop and it slides only along the guide. Right-click the guide to insert another stop at that exact position.
* **Middle Click & Drag:** Pan the infinite canvas.
* **Scroll Wheel:** Zoom the infinite canvas.
* **Drag in Hierarchy Panel:** Grab the indicator grip next to a layer or shape to dynamically reorder Z-index, restack boolean logic, or move geometry between layers.

**Keyboard Modifiers:**
* **`Shift + Drag`**: Pan a rigid-body shape hierarchy.
* **`R + Drag`**: Rotate a selected shape or point locally around its centroid.
* **`Shift + R + Drag`**: Rotate an entire hierarchical rigid-body system around the targeted centroid.
* **`Ctrl/Cmd + R + Drag`**: Rotate the explicit Bézier handles of a selected vertex (or group of vertices) around their local centroid without moving the underlying points. Automatically converts fluid Catmull-Rom nodes to explicit handles.
* **`A + Drag`**: Target an X-Spline or Gradient Mesh vertex and drag anywhere on the screen to fluidly adjust its structural tension.
* **`W + Drag`**: Target an X-Spline vertex and drag to adjust its variable stroke width. Shift+Drag to symmetrically scale both sides. Right-click the width handle to drop an Orange Width Constraint flag for automatic parametric tapering.
* **`S`**: Toggle the selected (or hovered) X-Spline vertices between **sharp** and **fluid**. Sharpening zeroes tension, clears explicit handles, and dissolves any corner pulley—making `S` a one-tap pulley remover as well. A mixed selection sharpens; only an all-sharp selection flips back to fluid.
* **`Q + Hover / Click`**: Hover a spline segment to preview an inserted vertex at that exact point on the resolved curve, then click to splice it in. The curve does not move: the segment is split with a true de Casteljau subdivision.
* **`F + Drag`**: With an X-Spline vertex selected, hold F and drag horizontally anywhere on the screen to dynamically apply a curve-aware fillet (corner rounding). Unlike a corner pulley, a fillet is destructive—it bakes the rounded corner into fixed points.
* **`X + Hover / Click`**: Hover over a Gradient Mesh to preview a slice. Compass auto-detects horizontal or vertical cuts based on edge proximity. Click to commit the topological slice without altering the visual gradient.
* **`Z + Drag`**: Select multiple nodes, hold Z, and drag to Laplacian smooth them. Hold `Shift+Z` to smooth variable widths.
* **`1 + Drag`**: Constrain a point or vertex drag to the **horizontal** axis. When using the `X` mesh slice tool, hold `1` to explicitly force a Horizontal (Row) cut.
* **`2 + Drag`**: Constrain a point or vertex drag to the **vertical** axis. When using the `X` mesh slice tool, hold `2` to explicitly force a Vertical (Column) cut.
* **`Esc`**: Deselect everything and let go. Abandons an in-progress pen spline, cancels a half-built two-click shape, clears the point and shape selection, and returns to the Select tool.
* **`Delete` / `Backspace`**: Delete the selected points and any geometry that depends on them, as a single undo step.
* **`Ctrl/Cmd + Z`**: Undo mathematical and geometric state changes.

---

### 🏗️ Project Architecture

Compass uses a highly decoupled, feature-driven architecture to ensure scalable mathematics and 60fps rendering:
* `models/geometry/`: The pure data models representing shapes, splines, meshes, gradients, images, and points. `image.dart` holds the IMG object's affine frame and its world↔UV projection; `stroke_outline.dart` is the shared offset-contour kernel behind every shape's stroke stack.
* `models/layer.dart`: The Boolean walk itself—fill, outline, stroke-area, gradient clip, mesh clip, and image mask resolution, plus the mirror modifier and the render-geometry signature cache.
* `constraints.dart`: The mathematical rule engine enforcing logic (e.g., Point-on-Circle, Distance-Radius), with a strict bind/unbind lifecycle so a deleted shape can never leave a rule enforcing against ghost geometry.
* `hierarchy_ops.dart`: Safely mutates Z-order and layer containment without breaking constraints.
* `engine.dart`: The centralized state holder that cascades updates from the models to the UI, and owns point garbage collection, the constraint registry, and the undo stack.
* `path_baker.dart` / `shape_converter.dart`: Reconstruct editable Bézier geometry from opaque rendered Boolean paths via least-squares curve fitting, and convert primitives between representations—the math behind Layer Baking.
* `io/`: Standalone serializers and compilers—the `.compass` project format, the SVG XML exporter, the offscreen PNG raster exporter, the ASCII compiler, and the OBJ mesh tessellator (geometry-only, textured, and multi-material) with its pure geometry kernels (`delaunay.dart` for Bowyer–Watson triangulation, `medial_axis.dart` for skeleton extraction). `obj_material.dart` is the material domain kept deliberately apart from the mesh domain: it resolves a layer's appearance into disjoint regions, bakes gradient ramps and mesh patches, and writes the MTL—never touching a triangle, just as the tessellator never touches a color.
* `ui/`: Modular UI panels (`layer_tile.dart`, `shape_row.dart`), pure-Dart color pickers, dynamic HUDs, and a two-pass `CustomPainter` canvas that separates document rasterization from the interactive scaffolding overlay.

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

**Then read [MANUAL.md](MANUAL.md).** This README is the argument for why Compass works the way it does; the manual is the reference for driving it—every tool, every hotkey, every export option, plus the handful of rules that aren't discoverable from the UI (why only `add` can seed a Boolean walk, what order a layer paints in, why a mesh owns its layer).

---

### License

Compass is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.

This means you are free to use, study, share, and modify the software. However, if you modify the code and distribute it—or offer it as a service over a network (like a web app)—you **must** make your modified source code available to the public under the same AGPL-3.0 license.

For full terms, see the [LICENSE](LICENSE) file. Copyright (C) 2026 Nathaniel Westveer.