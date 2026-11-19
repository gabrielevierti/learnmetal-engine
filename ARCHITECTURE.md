# How the engine works

This is the map. It says what each part does and why it is built that way; the source files say how, and their comments are written to be read. Names are given as `Folder/File`: the Swift file is `Swift/LMEngine/Folder/File.swift`, the C++ files are `Cpp/engine/Folder/File.hpp` and `.cpp`.

## Conventions

Get these wrong and everything is upside down or inside out, so here they are in one place.

- **Space.** Right-handed. +Y is up. A camera, a directional light and a spot light all look down their own -Z axis.
- **Triangles** are counter-clockwise seen from the front.
- **Depth** goes from 0 at the near plane to 1 at the far plane.
- **Texture coordinates** start at the top left. So does the 2D canvas, which is measured in points.
- **Colors.** Material colors and light colors are linear. Canvas colors are sRGB, the values a color picker shows. Color textures are sRGB and are converted by the GPU; data textures (normals, roughness) are not.
- **Tangents.** A vertex tangent points toward increasing u; its w is the sign that makes `cross(normal, tangent) * w` point to the top of the texture. Normal maps have green pointing up.
- **Vectors and matrices** are Apple's simd types in both languages.

## One frame

`Core/Engine` owns everything and runs the loop. Each frame:

1. **Input.** The window layer reports events to `Input/Input`.
2. **Fixed steps.** Real time is poured into an accumulator and consumed in steps of exactly 1/60 s (`Core/Time`). Each step calls the game's `fixedUpdate`, then `Physics.step`. A frame may run zero, one or several steps.
3. **Interpolation.** `Physics.writeTransforms` places every body between its last two physics positions, according to how much time is left in the accumulator. Motion looks smooth at any frame rate even though physics runs at 60 Hz.
4. **Update.** The game's `update`, then every `Behavior` component.
5. **Housekeeping.** Destroyed entities are removed, world matrices are computed parents first, particles move.
6. **Draw.** The game's `draw` fills the 2D canvas; `Renderer.render` draws the scene and then the canvas.

Why a fixed step: physics that advances by a different amount each frame gives different results on different machines, and becomes unstable when a frame is slow. The price is that key presses must be read in `update`, not in `fixedUpdate`, which may not run on a given frame.

## The scene

`Scene/Scene` is a small entity-component system. An entity is an index plus a generation number, so a handle to a destroyed entity can be recognized as stale. Each component type has its own storage, a "sparse set": the components sit back to back in one array, which is what a system walking all of them wants.

A component is any plain struct. The engine defines `Transform`, `Camera`, `Light`, `MeshRenderer`, `RigidBody`, `Collider`, `ParticleEmitter` and `Behavior`; the Marble game adds `Gem`, `MovingPlatform` and `Lifetime` without the engine knowing.

`destroy` only marks an entity; it disappears at the end of the frame. That makes it safe to destroy things from inside a loop over components or from a collision callback.

## The renderer

`Rendering/Renderer` decides what to draw; `Rendering/RenderPasses` contains the draw calls.

### Extraction

Before any pass, the renderer walks the scene once and builds plain arrays: the camera's matrices, the lights (the first directional light is "the sun"), and one item per visible mesh. Items outside the view frustum are dropped. Opaque items are sorted so that those sharing a material and a mesh are adjacent, and each run becomes **one instanced draw call**: the per-instance matrices go into a buffer, and the vertex function indexes it with `instance_id`. Transparent items are sorted from far to near instead.

### Passes

| | Pass | Draws into | Notes |
|---|---|---|---|
| 0 | Environment | sky cubemap, irradiance cubemap, prefiltered cubemap, BRDF table | Only when the sky changes. One small pass per cube face and mip level. |
| 1 | Shadow maps | one slice of a depth array per cascade | Depth only. Depth clamping keeps casters that are in front of the cascade's box. |
| 2 | Depth and normals | depth + view-space normals | Only if ambient occlusion is on. Not multisampled. |
| 3 | Ambient occlusion, blur | one-channel textures | Twelve samples per pixel in a hemisphere, then a 4 x 4 blur. |
| 4 | Scene | HDR color (multisampled, resolved at the end) | Opaque, then sky, then transparent, particles, debug lines. |
| 5 | Bloom | a chain of half-size textures | Prefilter, downsample, then add back up. |
| 6 | Final | the drawable | Tone mapping; then the canvas, which must not be tone mapped. |

The scene is drawn **forward**: one fragment function computes a pixel completely. That suits Apple GPUs, which determine the visible surface of every pixel before running any fragment function, and it works with multisampling and transparency without special cases.

**Shadows.** The view distance is cut into four slices, and each gets its own shadow map fitted around it (`Rendering/Cascades`). Each cascade is a sphere around its slice, snapped to whole texels, so shadows do not shimmer as the camera moves or turns. The lookup is offset along the surface normal by two texels, which removes self-shadowing without pushing shadows away from their casters.

**Image-based lighting.** The sky is a few lines of shader code. It is rendered into a cubemap, and that cubemap is filtered into the two maps of the split-sum approximation. Reflections and ambient light therefore always agree with the sky the player sees, and changing the sky's colors relights the scene.

### Memory per frame

Everything that changes each frame (uniforms, instance matrices, canvas vertices, particles) is copied into one large buffer by a bump allocator (`Rendering/FrameAllocator`). There are three such buffers, used in turn, because the GPU may still be reading the previous two frames' data; a semaphore keeps the CPU from getting further ahead than that.

On Apple GPUs the multisampled color target and the depth target of the main pass are **memoryless**: they exist only in the GPU's tile memory while the pass runs, and take no RAM.

### Shaders and pipelines

`Rendering/ShaderSource` joins the `.metal` files into one text, resolving `#include "..."` itself, and `Rendering/ShaderLibrary` compiles it at startup. A render pipeline state is created the first time a combination of functions, formats, sample count and blending is needed, and kept. If a shader file changes on disk it is recompiled; if that fails, the error is logged and the old shaders stay in use.

### Binding slots

Declared once in `Shaders/Shared/ShaderTypes.h`:

| Buffers | | Textures | | Samplers | |
|---|---|---|---|---|---|
| 0 | vertices | 0 | base color | 0 | material (repeat, anisotropic) |
| 1 | per-pass uniforms | 1 | normal | 1 | shadow (comparison) |
| 2 | instances | 2 | metallic-roughness | 2 | linear, clamped |
| 3 | material | 3 | occlusion | | |
| 4 | per-frame uniforms | 4 | emissive | | |
| 5 | lights | 5 | shadow map array | | |
| | | 6 | irradiance cube | | |
| | | 7 | prefiltered cube | | |
| | | 8 | BRDF table | | |
| | | 9 | ambient occlusion | | |

## Physics

`Physics/Collision` answers one question exactly: do these two shapes overlap, and if so, along which direction and how deep? It handles every pair of sphere, oriented box and capsule. `Physics/Physics` builds the simulation on top: integrate, find overlapping pairs (sort and sweep along x), resolve velocities with impulses over a few iterations, then push bodies apart.

It is an arcade model on purpose. Bodies do not spin from impacts, there are no joints, and fast objects can pass through thin ones. Those are the hard parts of a physics engine, and a game that needs them should use a dedicated library. What is here is enough for platforms, pushing crates, triggers and rolling a marble, and it is small enough to read.

## Sound

`Audio/Mixer` is the whole audio engine: a list of playing voices and a function that fills a block of samples by reading each voice's clip at its pitch, scaling by volume and pan, and adding. It knows nothing about sound cards. `Audio/Audio` connects it to one: miniaudio in C++, an `AVAudioSourceNode` in Swift. Both simply call `Mixer.render` from the audio thread.

`Audio/AudioClip` can also synthesize clips from a waveform, a pitch and a duration, which is how Marble has sound effects without shipping audio files.

## The window layer

`Platform/Window` is the only code that talks to the window system. In C++ that is GLFW, plus one Objective-C++ function that gives the window a `CAMetalLayer`. In Swift it is AppKit and an `MTKView`, with the engine driven by the view's draw callback. Both translate events into the same calls on `Input`.

With `--capture` no window is created at all: the engine renders into an ordinary texture, copies it to memory and writes a PNG.

The Swift engine also runs on iOS. What a window gives the engine is described by a small protocol, `Surface`: a size in points, a scale, the safe area, and the next drawable. `Window` provides it on a Mac; on iOS `EngineViewController` does, with an `MTKView`, and feeds touches to `Input` (the first finger also moves the mouse, so interfaces written for a mouse work under a thumb).

## The canvas

`Rendering/Canvas` turns every 2D call into triangles in one vertex buffer; the renderer draws them after tone mapping, one draw call per change of texture or clip.

- **Smooth edges** come from the geometry, not from multisampling. A convex shape is drawn half a pixel smaller than asked and surrounded by a strip one pixel wide whose outer vertices have zero alpha; a line is a solid core with such a strip on each side. Rounded rectangles, circles, rings and arcs are paths given to those two routines. The canvas needs to know how many pixels a point is, which the engine passes to `begin`.
- **Clipping** (`pushClip`, `popClip`) is recorded per batch and applied by the renderer as a scissor rectangle, rounded to pixels and kept inside the target.

## Scene files, the Gui and the editor

- **Scene files** (`Scene/SceneFile`) are text, one statement per line: settings, then materials, then entities with one line per component. Meshes and textures are stored by name (`Mesh.name`, `Texture.name`, set by `Assets`), never as data. Unknown lines are skipped. Numbers are written in the shortest form that reads back to the same float, so saving an unchanged scene changes nothing in the file.
- **The Gui** (`UI/Gui`) is immediate-mode: a control is a function call that draws it and returns what the user did. It needs only a `Canvas` and an `Input`. A panel clips its rows with the canvas, so they scroll smoothly under its edges; rows entirely outside are skipped and do not react. Sections fold and remember it under an id made from their title. Icons are drawn by code from lines and arcs. Besides the controls laid out in panels there are free ones (`bar`, `card`, `button`, `iconButton` with a position), which is what tool bars are made of. The pop-up of a list and the tooltip are drawn in `end()`, on top of everything; a pop-up's choice reaches the control one frame later.
- **The editor** (`Cpp/editor`, `Swift/Editor`) is a `Game`. It keeps its own camera in the scene, marked `EditorOnly` so that it is not saved, and points `Renderer.cameraOverride` at it. `Engine.isSimulationPaused` keeps physics still while editing. Undo is a stack of scene files in memory: after every finished edit the scene is written to text and compared with the last one. Play does the same once, and Stop reads that text back.

## FPV

`Cpp/fpv` and `Swift/FPVKit` are the second game, and a different kind of one: its physics is its own. `FlightModel` is a rigid body with four motors, integrated 480 times per second inside the engine's 60 fixed steps, and it knows nothing about the engine beyond its math types. Each step runs, in order: the rates the sticks ask for, a PID loop per axis, a mixer, motors that lag and sag with the battery, propellers whose thrust depends on the air moving through them, drag, and the battery itself. The gains of the PID loops are computed from the airframe (mass, inertia, arm length, motor response), so that different drones answer alike.

The game around it uses the engine for everything else. The ground is a height function, which the game asks directly; other obstacles are engine colliders, found with `overlapSphere`, and a ray along the last piece of the path gives the surface to bounce off. The radio link is a distance and a raycast from where the pilot stands. The onboard look is four render settings (lens distortion, color fringes, grain, interference), and the last one is driven by the link.

## Testing

- **Unit tests** cover everything that does not need a GPU: math, the scene, input, time, meshes, collision (including a test that tries thousands of random shape pairs and checks that the reported contact really separates them), physics, cascades, particles, the synthesizer, the mixer, shader file handling, fonts, the canvas, the Gui (by feeding it mouse and key events), scene files (write, read, write again, compare), and FPV's flight model: hover throttle, the response to a stick, top speed, battery sag and endurance, and control at every throttle. The Swift tests are ports of the C++ ones, with the same expected numbers; a few C++ cases are merged into one Swift test.
- **The autopilot** (`--demo`) rolls the marble through the whole course. Combined with `--capture`, it runs unattended and exits with an error if the marble does not reach the goal. It tests the game loop, the physics, the triggers and the level together.
