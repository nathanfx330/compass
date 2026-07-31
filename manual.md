# Compass — User Manual

**Version 0.4** · Linux / macOS / Windows · AGPL-3.0

A constraint-based parametric design tool. This manual covers everything the
program does. If you want the philosophy and the pitch, read `README.md` first —
this document assumes you're sitting in front of the app and want to know how to
drive it.

---

## Contents

1. [Getting started](#1-getting-started)
2. [The mental model](#2-the-mental-model)
3. [Canvas navigation](#3-canvas-navigation)
4. [Tools](#4-tools)
5. [Points and selection](#5-points-and-selection)
6. [Shapes](#6-shapes)
7. [Editing splines](#7-editing-splines)
8. [Corner pulleys and fillets](#8-corner-pulleys-and-fillets)
9. [Variable-width strokes](#9-variable-width-strokes)
10. [Constraints](#10-constraints)
11. [Layers and the hierarchy](#11-layers-and-the-hierarchy)
12. [Boolean operations](#12-boolean-operations)
13. [Stroke rings](#13-stroke-rings)
14. [Fills: flat, gradient, mesh, image](#14-fills-flat-gradient-mesh-image)
15. [Gradient meshes](#15-gradient-meshes)
16. [IMG objects](#16-img-objects)
17. [The mirror modifier](#17-the-mirror-modifier)
18. [Baking](#18-baking)
19. [Exporting](#19-exporting)
20. [Preferences and themes](#20-preferences-and-themes)
21. [Keyboard reference](#21-keyboard-reference)
22. [File format](#22-file-format)
23. [Troubleshooting](#23-troubleshooting)

---

## 1. Getting started

Compass is built in Flutter with no external Dart dependencies.

```bash
flutter pub get
flutter run -d linux     # or -d macos, -d windows
```

The window opens with a menu bar across the top, an infinite canvas filling most
of the space, a floating toolbar at the bottom left, and a two-tab panel on the
right (**Layers** and **Properties**). Drag the divider between canvas and panel
to resize.

A new document starts with one empty layer called `Layer 1`.

---

## 2. The mental model

Four ideas explain most of Compass's behavior.

**Points are the source of truth.** Shapes don't own coordinates. A circle is a
center point plus a radius; a rectangle is two corner points. Move a point and
everything derived from it follows. Delete a point and every shape depending on
it dies with it.

**Constraints are persistent rules.** A radius isn't "100 pixels" — it can be a
live formula ("always the distance between these two points"). The rule keeps
enforcing as you drag. Constraints are saved with the document and survive undo.

**Attachment is hierarchy.** Points can be attached to one another as
parent → child. Moving a parent moves its children; moving a child moves alone.
This is what makes a converted rectangle or a baked layer travel as one piece
without being "grouped."

**Layers resolve to one silhouette.** Every shape in a layer carries a boolean
operation. The layer walks its shapes in order and collapses them into a single
resolved path, which is what gets filled, stroked, and exported. Shape order
inside a layer is therefore *mathematical*, not merely visual.

---

## 3. Canvas navigation

| Action | Control |
|---|---|
| Pan | Middle-click and drag |
| Zoom | Scroll wheel |
| Deselect everything | `Esc` |
| Undo | `Ctrl/Cmd + Z` |

The canvas is mathematically infinite. Zoom range is roughly 0.05× to 50×;
geometry stays exact at any zoom because it is re-evaluated, not scaled.

### Scaffolding

"Scaffolding" is the blue construction overlay — wireframes, point dots, handles,
tension boxes, guides. Three view modes control it, all under **View** or the
empty-canvas right-click menu:

- **Show/Hide Scaffolding** — everything. Hiding it also disables point
  interaction, so this is your clean preview.
- **Show/Hide Handles** — Bézier and width handle dots only.
- **Ghost Vertices** — hides the vertex *dots* while keeping every point fully
  live. Hover a bare wireframe and each invisible vertex lights up as you reach
  it. Points stay clickable, draggable, and box-selectable. Pair with
  **Show Vertex Numbers** (Properties panel) for a clean "labels only" reading of
  a dense spline.

---

## 4. Tools

The floating toolbar, left to right:

| Icon | Tool | Behavior |
|---|---|---|
| Arrow | **Select** | Select and drag points and shapes |
| ⊕ | **Add Point** | Click to place a point; snaps onto a nearby shape as a constrained rider |
| ∿ | **Line** | Two clicks: start, end |
| ○ | **Circle** | Two clicks: center, radius |
| □ | **Rectangle** | Two clicks: opposite corners |
| ⟳ | **Golden Spiral** | Two clicks: center, start point |
| ✎ | **Pen (X-Spline)** | Click repeatedly to add vertices |

**Shift + click** with Line, Circle, Rectangle, or Spiral creates the shape
immediately at a default size instead of waiting for a second click. Rectangles
made this way are locked square, and circles get a live radius constraint.

**Pen tool:** click the first vertex again to close the loop and finish.
Right-click or press `Esc` to finish an open spline. Clicking an existing point
reuses it rather than creating a new one.

Press `Esc` at any time to abandon a half-built shape and return to Select.

---

## 5. Points and selection

**Click** a point to select it. **Shift + click** adds or removes from the
selection. **Drag on empty canvas** to box-select. **Click empty canvas** to
clear.

With 2+ points selected, a dashed orange bounding box appears with corner ticks.
Dragging anywhere inside it moves the whole selection.

| Action | Control |
|---|---|
| Move selection (with dependents) | Drag |
| Move selection (strictly, no cascade) | `Shift` + drag |
| Move whole rigid-body hierarchy | `Shift` + drag on a shape |
| Delete selected points | `Delete` or `Backspace` |
| Constrain drag to horizontal | Hold `1` |
| Constrain drag to vertical | Hold `2` |

Axis locks anchor to where the drag *began*, so they give exact orthogonal moves
rather than approximate ones.

Deleting points deletes any shape that depended on them, as a **single** undo
step no matter how many points were selected.

---

## 6. Shapes

### Line

Two points. Renders as a stroke only — it has no fillable area and contributes
nothing to the boolean walk.

### Circle

A center point, a radius, and usually a radius point. When a radius point exists,
a **Distance-Radius constraint** keeps the radius equal to the center-to-radius-point
distance, so dragging either point resizes the circle live.

### Rectangle

Two opposite corner points, plus a corner radius and an optional square lock.
Both are in the on-canvas HUD when a rectangle is selected:

- **Lock as Perfect Square** — installs a `SquareConstraint`; dragging either
  corner keeps a 1:1 aspect ratio.
- **Corner Radius** — slider, clamped to half the shortest side.

### Golden Spiral

A center and a start point. Grows by φ every 90°. HUD controls set **direction**
(clockwise / counter-clockwise) and **revolutions** (0.1–10). Stroke only, like a
line — its operation defaults to *Construction*.

### X-Spline

The general-purpose curve, and the shape most of Compass's editing tools target.
Covered in the next section.

### Gradient Mesh

A Coons patch color surface. See [§15](#15-gradient-meshes).

### IMG

A raster image with a live affine frame. See [§16](#16-img-objects).

---

## 7. Editing splines

X-Spline vertices live in two mathematical modes.

**Fluid (Catmull-Rom).** The curve's tangents are derived from neighboring
vertices, scaled by a per-vertex **tension** value. This is the default.

**Explicit (Bézier).** The vertex carries independent in/out handle vectors you
drag directly.

Conversion between them is loss-free — the curve never jumps.

| Action | Control |
|---|---|
| Adjust tension | Hold `A`, drag away from the vertex |
| Convert to Bézier | Right-click vertex → *Convert to Bézier* |
| Back to fluid | Right-click vertex → *Reset Handles* |
| Drag a handle | Click and drag the purple dot |
| Rotate handles only | `Ctrl/Cmd + R` + drag |
| Toggle sharp ↔ fluid | `S` |
| Insert a vertex | Hold `Q`, hover a segment, click |
| Smooth positions | Select 2+, hold `Z`, drag |
| Smooth widths | Select 2+, hold `Shift + Z`, drag |
| Close / open the spline | Right-click → *Close Spline* / *Open Spline* |

**Tension** is a global distance tether: with `A` held, the further you drag from
the vertex, the higher the tension. Zero tension collapses the tangents into
straight chords — the sharpest a corner can be.

**`S` (sharp toggle)** zeroes tension, clears explicit handles, and dissolves any
corner pulley in one tap. With a mixed selection it sharpens everything; only
when *every* targeted vertex is already sharp does it flip back to fluid. This
also makes `S` a fast pulley remover.

**`Q` insertion** previews the exact point on the resolved curve before you
commit, and splits the segment with a true de Casteljau subdivision — the curve
does not move.

---

## 8. Corner pulleys and fillets

Two ways to treat a corner, with different persistence.

### Pulleys (non-destructive)

A pulley is a live constraint the vertex carries. The underlying point never
moves; the rope wraps *around* the corner. Survives save, load, undo, and
rotation.

- **Round pulley** — right-click a vertex → *Bind Corner to Circle*. The rope
  wraps in a smooth arc, leaving and rejoining the edges tangentially.
- **Miter pulley** — right-click a vertex → *Bind Corner to Miter*. Same outward
  wrap, brought to a single sharp apex.

Drag the colored rim handle on canvas to resize (light blue = round, orange =
miter), or use the slider in the Properties panel. Remove by right-clicking again
or pressing `S`.

Adjacent pulleys share a common external tangent, so two pulleys next to each
other meet cleanly instead of over-wrapping.

### Fillet (destructive)

`F` + drag horizontally, or right-click → *Fillet Corner Dialog*. A fillet
**bakes** a rounded corner into two new fixed points and removes the original
vertex. Curve-aware: it follows the existing curvature rather than assuming
straight edges.

Use a pulley when you want to keep adjusting it. Use a fillet when the corner is
final and you want clean geometry.

---

## 9. Variable-width strokes

Hold `W` to sculpt a spline into a variable-width ribbon.

| Action | Control |
|---|---|
| Adjust one side | `W` + drag a diamond handle |
| Adjust both sides symmetrically | `W` + `Shift` + drag |
| Pin a width (constraint flag) | `W`, right-click a width handle |

**Constraint flags** are the parametric part. Drop a flag on two handles and
Compass interpolates the width of every node between them. Drag a pinned flag and
the whole tapered section updates live. Flagged handles turn orange.

The Properties panel has bulk controls when a spline is selected:

- **Uniform Width** — one value applied to every node.
- **Taper Width** — start and end values, linearly interpolated across the
  spline. Turn on **Show Vertex Numbers** to see which node is 0 and which is
  last.

Both bulk operations clear existing flags.

---

## 10. Constraints

Constraints are created by right-clicking a shape and choosing **Add Point to
Shape**, or by using the Add Point tool near a shape.

| Constraint | Effect |
|---|---|
| Point-on-Line | Point slides along the segment |
| Point-on-Circle | Point rides the circumference at a locked angle |
| Point-on-Spiral | Point walks the logarithmic curve |
| Distance-Radius | A circle's radius tracks two points' separation |
| Square | A rectangle stays 1:1 |

Rider constraints (the first three) are saved to `.compass` and survive undo. The
other two are rebuilt on load from the shape's own wiring.

Dragging the *rider* moves it along its host. Dragging the *host* carries the
rider with it. Dragging both at once (as part of a rigid-body move or rotation)
suspends enforcement for that frame so the transform isn't fought.

---

## 11. Layers and the hierarchy

The **Layers** tab shows layers top-of-stack first. Each layer card has:

- **Grip** (left) — drag to restack the layer in z-order
- **Expand arrow** — show/hide the layer's shapes
- **Eye** — visibility
- **Color dot** — the layer's fill color
- **Name** — double-click to rename inline (`Enter` commits, `Esc` cancels)
- **Lock** — freezes the layer's contents; locked layers can still be restacked
- **Trash** — delete the layer and everything in it

Right-click a layer for **Rename**, **Bake to X-Spline**, **Bake to Triangulated
Spline**, and **Export to OBJ**.

### Shape rows

Each shape row shows its name, its operation, and small badges: a link icon if it
shares constraints, a ring icon with the stroke count, a teal layers icon if it's
a mesh that owns its layer.

Row controls: **+** adds a stroke ring, **eye** toggles visibility, **tune** picks
the boolean operation, **trash** deletes.

### Reordering

- **Layer grip** → drag to restack layers.
- **Shape grip** → drag to reorder within a layer, or drop onto another layer to
  move it there. The drop lands *above* the row you release on. The layer header
  is a catch-all that sends the shape to the back; a strip below the last row does
  the same explicitly.

Reordering shapes changes the **boolean evaluation order**, not just paint order —
lifting a subtract above an add changes the resolved geometry.

### Reference image

Pinned below the hierarchy. Load a PNG/JPG to trace over. It never exports.
Unlock it to move (drag) and scale (scroll) it; lock it to work over it.

---

## 12. Boolean operations

Every shape carries one of four operations:

| Op | Effect |
|---|---|
| **Add** (Union) | Contributes its area |
| **Subtract** | Removes its area from what's below |
| **Intersect** | Keeps only the overlap |
| **None** | Construction geometry — invisible, exports nothing |

Set via the shape's **tune** menu in the hierarchy or by right-clicking the shape
on canvas.

**Order matters, and only `add` can seed.** The layer walks its shapes in order
building up a master path. Subtract and intersect can only modify an existing
master — an intersect shape sitting *first* in the walk is silently dropped. If a
boolean seems to do nothing, check that something adds before it.

---

## 13. Stroke rings

A shape's outline can become a boolean operand. Rings stack **outward** from the
shape's silhouette: ring 1 sits on the outline, ring 2 butts against ring 1's
outer edge, and so on — no gaps, no overlaps.

Click **+** on a shape row to add a ring, then expand **Stroke Rings** to edit:

- **FILL / CUT** — tap to toggle. A Fill ring paints; a Cut ring carves the
  geometry beneath.
- **Color chip** (Fill rings only) — tap to pick, long-press to clear back to
  "inherit layer color."
- **Up / down arrows** — restack inward and outward.
- **Remove** — delete the ring.

Ring **width** is a slider in the Properties panel, one per ring.

Supported on **circles, rectangles, and X-splines**. Each supplies exact parallel
offset geometry for its own silhouette.

Rings **reflow after the boolean walk**: when a later shape carves the geometry a
ring belongs to, the ring re-wraps the newly created contour instead of tracing
the original uncut outline.

The whole stroke stack is applied *before* the shape's own fill, so a shape's
stroke never carves its own fill.

---

## 14. Fills: flat, gradient, mesh, image

A layer paints in passes, in this order:

1. **Flat fill** — the layer color over the resolved boolean silhouette
2. **Self-painted fills** — gradients and IMG pixels, each clipped to its own
   boolean-carved region
3. **Stroke area** — variable-width ribbons
4. **Colored stroke bands** — Fill rings with their own colors
5. **Gradient meshes** — last

Knowing this order explains most "why is my shape hidden" questions.

### Flat fill

Set **Fill Color** and **Stroke Color** in the Properties panel. Choose a preset,
"none" (transparent), or **Custom…** for the built-in HSV picker with hex entry.

### Per-shape gradients

Right-click a shape → **Make Gradient**. This seeds a single stop at the cursor
using the shape's current color; the shape still renders solid.

Right-click again → **Set Gradient End Here** to place the second stop. The
dotted guide appears and the ramp becomes live.

Once the guide exists:

- **Right-click the guide** → *Add Gradient Stop Here*. The new stop samples the
  existing color, so adding it doesn't change the artwork until you recolor it.
- **Drag an endpoint** (diamond) to redefine direction and extent.
- **Drag an interior stop** (circle) — it slides along the guide only.
- **Right-click a stop** → recolor or remove.
- **Right-click the base stop** → switch between **Linear** and **Circular**.

In circular mode the first stop is the center and the last controls the radius.

Gradient stops are ordinary points: they drag, rotate, cohere with the shape,
serialize, and undo like anything else.

---

## 15. Gradient meshes

A **Coons patch** color surface — a grid of nodes, each with a color and a
tension, interpolated bicubically.

### Creating one

Right-click a **rectangle** → *Convert to Gradient Mesh*.

> **A mesh always gets its own layer.** The mesh moves to a new layer named
> `<source> Mesh` inserted directly above the source layer. If that empties the
> source layer, the empty layer is removed.

### The mesh-layer rule

**A visible mesh owns its layer.** Other shapes in that layer may only **carve**
it — Subtract or Intersect. Add is not offered, and anything that would be an Add
is coerced to Subtract:

- Drawing a new shape into a mesh layer → arrives as Subtract
- Dragging an existing Add shape in → coerced on drop
- The op menu → shows *Mesh layer — carve only*, no Add
- Stroke rings → Cut only; the FILL/CUT chip becomes a static label

The reason is paint order: meshes paint *last* in a layer, so an "Add" shape
above a mesh would silently disappear beneath it. Isolation removes the question
instead of hiding the shape. Cross-layer stacking still works normally — put the
Add shape in its own layer above.

The mesh's own row shows **MESH FILL** rather than an operation, because a mesh
never participates in the boolean walk as an operand.

Hiding the mesh releases the layer; its other shapes behave normally again.

### Editing

| Action | Control |
|---|---|
| Move a node | Drag it |
| Adjust node tension (bow the curves) | `A` + drag |
| Insert a row or column | Hold `X`, hover, click |
| Force a horizontal cut | `X` + `1` |
| Force a vertical cut | `X` + `2` |
| Color one node | Right-click → *Set Node Color…* |
| Color several nodes | Select them, click a swatch in Properties |

Slicing with `X` adds topology without changing the visible gradient — the new
row or column is evaluated exactly on the existing cubic boundary.

The Properties panel shows every color currently used in the mesh as a swatch
palette, plus a Custom option.

---

## 16. IMG objects

**File → Import IMG Layer…** and enter an absolute path to a PNG or JPG.

An IMG is an ordinary ordered object, not a locked backdrop. Its position is an
**affine frame of three real points**: an origin, an X-edge handle, and a Y-edge
handle, with the fourth corner derived.

- **Drag the origin** — translate the whole image
- **Drag an edge handle** — scale, rotate, or skew; pixels resample live
- Rotation, rigid-body drag, and attachment all work as they do for any point

**Opacity** is a slider in the Properties panel.

### Live masking

An IMG is a genuine boolean operand. Shapes stacked above it decide what
survives, resolved as a **set**:

```
(image ∩ ⋃ intersects) − ⋃ subtracts
```

Every later Intersect is unioned into one keep-region and every later Subtract
into one cut-region. That set interpretation is what lets a *disconnected* mask
work — a logo body and its detached leaf keep both pieces, where a naïve
left-to-right intersect chain would annihilate them.

Later **Add** shapes are not mask contributors; they simply paint over the image
as ordinary foreground.

Nothing is destructive — drag a cutter and the pixels re-mask at 60fps. The
`.compass` file stores the path and frame, not the pixels, so projects stay small
and the image is re-linked on load.

---

## 17. The mirror modifier

A per-layer axis of symmetry, applied *after* the boolean walk.

Right-click empty canvas:

- **Enable Mirror Here** — plants the axis at the cursor on the active layer
- **Mirror Axis: Vertical → Horizontal** — flip orientation
- **Disable Mirror**

Drag the teal axis line (or its center handle) to slide the plane of symmetry
live. The active layer's axis is bright and draggable; other layers show theirs
dimmed.

The mirror **fuses** the master half and its reflection into a single continuous
silhouette rather than stamping a duplicate. A gradient laid across a mirrored
shape therefore shades the whole fused form cohesively — one world-space ramp
flowing across the seam, not a folded copy.

Because it runs post-resolve, a subtract on the master half carves the mirrored
half symmetrically. Honored identically on canvas, in PNG export, and in SVG
export.

---

## 18. Baking

Right-click a layer to convert its resolved result into editable geometry.

### Bake to X-Spline

Samples the merged boolean boundary and reconstructs it with a **least-squares
Bézier curve fit**. Output is sparse, smooth, and fully handle-editable — and
unlike a flattened polygon it stays mathematically smooth at any zoom.

- Holes and disjoint islands are preserved (outer contours become Add, inner
  contours become Subtract)
- A mirrored layer bakes into its single fused silhouette
- A gradient fill is carried onto the result with fresh, independent stops
- An IMG contributes its *resolved mask outline*, so a carved photo becomes
  editable vector geometry

The source layer is preserved and switched off, never destroyed. This is the
equivalent of "apply modifier."

### Bake to Triangulated Spline

Fills the silhouette with a seeded Delaunay point cloud and walks the graph into
one continuous "Sci-Fi veins" spline — an instant wireframe/circuitry treatment.
Lands on a new layer with a cyan stroke and no fill.

---

## 19. Exporting

All exporters write to a path you type. Relative paths resolve against the
process working directory.

### SVG

**File → Export as SVG…**

Pure XML. Boolean subtractions become native `<mask>` tags, gradients become
`userSpaceOnUse` `<linearGradient>` / `<radialGradient>` definitions, and a
mirrored layer is reflected with a transformed `<use>`. Gradient meshes are
approximated as faceted flat polygons.

### PNG

**File → Export as PNG…**

- **Resolution scale** — 0.5×, 1×, 2×, 4×, or custom
- **Color mode** — full color or grayscale
- **Render style**:
  - *Standard* — clean vector rasterization
  - *Dithered* — Floyd–Steinberg error diffusion, 1-bit per channel
  - *Bubble Jet* — halftone; darker regions become larger ink dots, with an
    adjustable dot size

All styles preserve alpha. Output is the artwork on a transparent background —
no scaffolding.

### ASCII art

**File → Export as ASCII Art…**

70-character luminance ramp. Options: column count (40–300), invert for dark
terminals, and Floyd–Steinberg dithering to smooth gradients into dot patterns.

### OBJ (3D mesh)

Right-click a layer → **Export to OBJ…**. Scoped to one layer.

**Curve Resolution** — Fine (1px), Medium (2px), Coarse (4px). Smaller means a
truer outline in every mode.

**Mode:**

| Mode | Output | Use for |
|---|---|---|
| **Scanline** | Trapezoidal bands | Robust default, follows curves exactly |
| **Grid** | Uniform quad lattice | Subdivision and displacement; silhouette steps at cell size |
| **Organic** | Delaunay triangles | Deformation, wireframe styles; exact silhouette |
| **Skeleton** | Medial-axis edges (`l`) | Blender's Skin modifier, rigging |

Grid and Skeleton share a resolution slider (cells across the longest side).
Organic has a triangle-size slider. Skeleton adds **branch pruning (λ)** — higher
keeps only the primary frame, lower keeps finer twigs.

**Material:**

| Choice | Writes |
|---|---|
| **Geometry only** | `.obj` |
| **Layer appearance** | `.obj` + `.mtl` + one texture per gradient/mesh/image |
| **IMG texture — …** | `.obj` + `.mtl` + a copy of that image |

**Layer appearance** exports the whole look as disjoint material regions — flat
fill, gradients, stroke area, colored bands, meshes, and IMG masks. Each region
carries its own material:

- Flat regions → a solid color material
- Gradients → a small 1-D ramp texture sampled along the gradient's own axis
  (linear and circular both), so color is exact at any mesh scale
- Meshes → a baked 2-D patch texture with a planar unwrap
- IMG → a copy of the source image, UV-projected through the affine frame

Regions are made mutually exclusive before export, so nothing Z-fights.

Meshes work here even though geometry-only export skips them.

**Not available:** Skeleton mode carries no faces, so it can't carry materials.
IMG textures are unavailable on mirrored layers (one affine frame can't invert
across a reflection); Layer appearance still exports flat and gradient regions
correctly and notes the skipped IMG.

Every OBJ export appends a block to **`compass_export_log.txt`** in the working
directory, recording settings, per-region decisions, triangle counts, and the
outcome. The snackbar shows the log's path. If an export reports "nothing to
export," the log says which test rejected which shape.

### Saving projects

**File → Save Project…** writes `.compass`. **File → Open Project…** loads one.
**File → New Project** clears everything.

---

## 20. Preferences and themes

**Compass → Preferences…**

**Color mode:** Light, Dim, or Dark. Dim is a mid-tone dark that many find easier
for long sessions.

**Themes:** six built-ins — Compass Default, Ocean Blue, Engine, Nord, Gruvbox,
and Monochrome (forced zero-chroma). Create custom themes with a seed color and
separate Light / Dim / Dark canvas backgrounds. Custom themes can be edited and
deleted; built-ins can't.

Settings persist to `compass_settings.json` in the working directory.

**Debug → Show FPS Overlay** displays live frame timing (FPS, UI ms, GPU ms). It
listens to real frame timings rather than driving its own ticker, so enabling it
doesn't inflate the numbers.

---

## 21. Keyboard reference

### Global

| Key | Action |
|---|---|
| `Esc` | Deselect all; abandon in-progress shape; return to Select |
| `Delete` / `Backspace` | Delete selected points and dependent shapes |
| `Ctrl/Cmd + Z` | Undo |

### Transform

| Key | Action |
|---|---|
| `Shift` + drag | Pan a rigid-body hierarchy |
| `R` + drag | Rotate shape or point locally |
| `Shift + R` + drag | Rotate an entire hierarchy around its centroid |
| `Ctrl/Cmd + R` + drag | Rotate Bézier handles only |
| `1` + drag | Lock to horizontal axis |
| `2` + drag | Lock to vertical axis |

### Spline editing

| Key | Action |
|---|---|
| `A` + drag | Adjust vertex tension (splines and mesh nodes) |
| `S` | Toggle sharp ↔ fluid |
| `Q` + hover, click | Insert a vertex on the curve |
| `F` + drag | Fillet a corner (destructive) |
| `W` + drag | Adjust variable stroke width |
| `W + Shift` + drag | Adjust both sides symmetrically |
| `Z` + drag | Laplacian smooth positions |
| `Shift + Z` + drag | Smooth widths |

### Mesh

| Key | Action |
|---|---|
| `X` + hover, click | Slice a row or column |
| `X + 1` | Force a horizontal (row) cut |
| `X + 2` | Force a vertical (column) cut |

### Mouse

| Action | Result |
|---|---|
| Left click | Select |
| Left drag | Move, or box-select on empty canvas |
| Right click | Context menu |
| Middle drag | Pan canvas |
| Scroll | Zoom |

---

## 22. File format

`.compass` is line-based plain text — greppable, diffable, and
version-control-friendly.

```
POINT,<id>,<x>,<y>
ATTACH,<parentId>,<childId>
LAYER,<id>,<name>,<visible>,<expanded>,<fill>,<stroke>,<width>,<locked>,<mirror…>
SHAPE,<type>,<layerId>,<op>,<visible>,<definingPoints…>[,STROKE:…][,GRAD:…][,GRADTYPE:…]
CONSTRAINT,<kind>,<riderId>,<hostPoints…>
REF,<path>,<visible>,<locked>,<offset…>,<scale>,<rotation>
```

The format is **forward- and backward-compatible**: new fields ride the end of
existing lines, so older files load unchanged and older builds ignore what they
don't recognize.

Layer names are sanitized on rename (commas and newlines become spaces) because
the format is comma-delimited.

Undo works by serializing and deserializing this same format, which is why
constraints and gradients survive `Ctrl+Z` — anything the format persists,
undo restores.

---

## 23. Troubleshooting

**A boolean does nothing.** Only `add` can seed an empty layer. If your first
shape is a Subtract or Intersect, there's nothing for it to modify. Add something
before it, or reorder in the hierarchy.

**A shape in a mesh layer is invisible.** It's probably still an Add from an
older document. Meshes paint last, so it's buried. Set it to Subtract, or move it
to its own layer above the mesh.

**A shape I dragged into a mesh layer changed its operation.** Expected — Add is
coerced to Subtract in mesh layers. See [§15](#15-gradient-meshes).

**OBJ export says "nothing to export."** Read `compass_export_log.txt`. The most
common cause is a layer whose only paint is a gradient mesh exported with
*Geometry only* — meshes are skipped by geometry-only export. Use **Layer
appearance** instead.

**A gradient looks flat at one end.** The gradient's stops may not span the
shape. Positions beyond the first and last stop clamp to those colors, producing
a solid plateau. Drag the endpoint stop past the silhouette.

**Points won't select.** Check whether the layer is locked, whether scaffolding
is hidden (which disables point interaction), or whether the shape is hidden. Note
that **Ghost Vertices** hides dots but keeps points live — that's not the cause.

**A vertex drags other vertices with it.** Those points are attached in the
hierarchy. Use `Shift` + drag for a strict move, or check the link badge in the
hierarchy row.

**Undo restored more than expected.** Some operations are deliberately one undo
step — deleting a multi-point selection, or a whole drag gesture.

---

## License

Compass is licensed under the **GNU Affero General Public License v3.0**.

You may use, study, share, and modify the software. If you modify it and
distribute it — or offer it as a network service — you must make your modified
source available under the same license.

Copyright © 2026 Nathaniel Westveer.
