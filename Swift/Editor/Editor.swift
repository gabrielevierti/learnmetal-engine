// Editor.swift
// The scene editor of the LearnMetal Engine.
//
// It is an ordinary program made with the engine: a Game whose "gameplay" is editing
// the scene it shows. Everything on screen is drawn with the engine's own Gui and Canvas.
//
//   Editor.swift          the frame, the camera, files, undo, play mode
//   EditorViewport.swift  what happens in the 3D view: picking, the gizmo, outlines
//   EditorPanels.swift    the panels: scene list, assets, inspector, materials, settings

import Foundation
import LMEngine
import simd

let toolbarHeight: Float = 64
private let leftWidth: Float = 250
private let rightWidth: Float = 320
private let undoLevels = 100

final class Editor: Game {
    enum Tool: Int {
        case move, rotate, scale
    }
    enum Shape: Int {
        case empty, cube, sphere, plane, cylinder, pointLight, camera
    }

    /// The scene to open, as a name in Assets/Scenes without ".scene". Empty starts a new scene.
    var sceneName = ""
    var tool = Tool.move
    var selected = Entity.invalid
    private(set) var isPlaying = false

    let gui = Gui()
    var materials: [NamedMaterial] = []
    var entities: [Entity] = []                 // everything in the scene, in file order
    var selectedMaterial = 0
    var rightTab = 0                            // inspector, materials, scene settings

    // The editor's own camera. It is in the scene (the renderer needs it there) but
    // marked EditorOnly, so it is never saved.
    var camera = Entity.invalid
    var cameraPosition = Vec3(6, 5, 9)
    var cameraYaw: Float = 0.6
    var cameraPitch: Float = -0.42

    // The gizmo: which axis is being dragged (-1 for none), and how screen movement maps to it.
    var dragAxis = -1
    var dragDirection = Vec2(1, 0)
    var dragPointsPerUnit: Float = 1
    var shownAngles = Vec3(0, 0, 0)             // the rotation of the selection as the inspector shows it
    var shownRotation = Quat.identity

    // Undo: the scene as text after every finished edit.
    private var undoStack: [String] = []
    private var redoStack: [String] = []
    private var current = ""
    var touched = false

    private var beforePlay = ""

    var meshNames: [String] = []
    var textureNames: [String] = []
    var sceneNames: [String] = []
    var status = ""
    var statusUntil = 0.0
    var now = 0.0

    // MARK: - Start

    func start(_ engine: Engine) {
        engine.isSimulationPaused = true        // nothing falls while it is being placed
        try? FileManager.default.createDirectory(atPath: engine.assets.path("Scenes"), withIntermediateDirectories: true)
        refreshLists(engine)
        if sceneName.isEmpty || !openScene(engine, sceneName) { newScene(engine) }
    }

    func refreshLists(_ engine: Engine) {
        meshNames = ["cube", "sphere", "plane", "cylinder"] + engine.assets.listFiles("Models", ".obj")
        textureNames = engine.assets.listFiles("Textures", ".png") + engine.assets.listFiles("Textures", ".jpg")
        // "Scenes/demo.scene" -> "demo"
        sceneNames = engine.assets.listFiles("Scenes", ".scene").map { String($0.dropFirst(7).dropLast(6)) }
    }

    func say(_ message: String) {
        status = message
        statusUntil = now + 4
    }

    /// The material new things get: the one selected in the Materials tab. There is always one.
    func defaultMaterial() -> Material {
        if materials.isEmpty { materials.append(NamedMaterial(name: "Default", material: Material())) }
        selectedMaterial = min(max(selectedMaterial, 0), materials.count - 1)
        return materials[selectedMaterial].material
    }

    private func createCamera(_ engine: Engine) {
        camera = engine.scene.create("Editor camera")
        engine.scene.add(camera, Transform(position: cameraPosition, rotation: Quat(pitch: cameraPitch, yaw: cameraYaw)))
        engine.scene.add(camera, Camera())
        engine.scene.add(camera, EditorOnly())
        engine.renderer.cameraOverride = isPlaying ? .invalid : camera
    }

    private func listEntities(_ engine: Engine) {
        entities.removeAll(keepingCapacity: true)
        let scene = engine.scene
        scene.each(Transform.self) { entity, _ in
            if !scene.has(EditorOnly.self, entity) { self.entities.append(entity) }
        }
    }

    // MARK: - Files

    /// Replaces the scene with the one described by `text`, keeping the selection if it can.
    private func restore(_ engine: Engine, _ text: String) {
        let selectedIndex = entities.firstIndex(of: selected)
        engine.scene.clear()
        engine.physics.reset()
        createCamera(engine)
        readScene(text, into: engine.scene, materials: &materials, settings: &engine.renderer.settings, assets: engine.assets.sceneAssets)
        _ = defaultMaterial()

        listEntities(engine)
        if let index = selectedIndex, index < entities.count {
            selected = entities[index]
        } else {
            selected = .invalid
        }
        engine.scene.updateTransforms()
    }

    func newScene(_ engine: Engine) {
        let scene = engine.scene
        sceneName = "untitled"
        scene.clear()
        engine.physics.reset()
        engine.renderer.settings = RenderSettings()
        selectedMaterial = 0
        createCamera(engine)

        // A floor, something on it, a sun and a camera: enough to see the lighting.
        let ground = Material()
        ground.baseColor = Vec4(0.55, 0.57, 0.6, 1)
        ground.roughness = 0.9
        materials = [NamedMaterial(name: "Default", material: Material()), NamedMaterial(name: "Ground", material: ground)]

        let sun = scene.create("Sun")
        scene.add(sun, Transform(position: Vec3(0, 6, 0), rotation: .lookRotation(forward: Vec3(0.5, -0.8, -0.35))))
        scene.add(sun, Light(type: .directional, color: Vec3(1.0, 0.95, 0.85), intensity: 3.5, castsShadows: true))

        let floor = scene.create("Floor")
        scene.add(floor, Transform(scale: Vec3(20, 1, 20)))
        scene.add(floor, MeshRenderer(mesh: engine.assets.plane, material: ground))
        var floorCollider = Collider.box(halfExtents: Vec3(10, 0.5, 10))
        floorCollider.offset = Vec3(0, -0.5, 0)
        scene.add(floor, floorCollider)

        let cube = scene.create("Cube")
        scene.add(cube, Transform(position: Vec3(0, 0.5, 0)))
        scene.add(cube, MeshRenderer(mesh: engine.assets.cube, material: materials[0].material))
        scene.add(cube, Collider.box(halfExtents: Vec3(0.5, 0.5, 0.5)))

        let gameCamera = scene.create("Camera")
        scene.add(gameCamera, Transform(position: Vec3(0, 2, 7), rotation: .lookRotation(forward: Vec3(0, -0.2, -1))))
        scene.add(gameCamera, Camera())

        selected = cube
        scene.updateTransforms()
        current = writeScene(scene, materials: materials, settings: engine.renderer.settings)
        undoStack.removeAll()
        redoStack.removeAll()
        say("New scene")
    }

    @discardableResult
    func openScene(_ engine: Engine, _ name: String) -> Bool {
        // Read it into a scratch scene first: a file that cannot be read must not cost the open scene.
        let probe = Scene()
        var probeMaterials: [NamedMaterial] = []
        var probeSettings = RenderSettings()
        guard let text = try? String(contentsOfFile: engine.assets.path("Scenes/\(name).scene"), encoding: .utf8),
              readScene(text, into: probe, materials: &probeMaterials, settings: &probeSettings, assets: SceneAssets()) else {
            say("Cannot open \(name)")
            return false
        }
        sceneName = name
        selected = .invalid
        entities.removeAll()
        engine.renderer.settings = RenderSettings()
        restore(engine, text)
        current = writeScene(engine.scene, materials: materials, settings: engine.renderer.settings)
        undoStack.removeAll()
        redoStack.removeAll()
        say("Opened \(name)")
        return true
    }

    @discardableResult
    func saveScene(_ engine: Engine) -> Bool {
        if isPlaying { return false }
        let path = engine.assets.path("Scenes/\(sceneName).scene")
        let saved = saveSceneFile(path, engine.scene, materials: materials, settings: engine.renderer.settings)
        say(saved ? "Saved Scenes/\(sceneName).scene" : "Could not save \(sceneName)")
        refreshLists(engine)
        return saved
    }

    // MARK: - Editing

    var cameraRotation: Quat { Quat(pitch: cameraPitch, yaw: cameraYaw) }

    private func spawnPoint() -> Vec3 {
        // Where the camera looks at the ground; or a few meters ahead if it looks at the sky.
        let forward = cameraRotation.act(Vec3(0, 0, -1))
        let distance = forward.y < -0.05 ? min(-cameraPosition.y / forward.y, 30) : 8
        let point = cameraPosition + forward * distance
        return Vec3((point.x * 2).rounded() / 2, 0, (point.z * 2).rounded() / 2)      // on a half-meter grid
    }

    @discardableResult
    func addEntity(_ engine: Engine, _ shape: Shape) -> Entity {
        let names = ["Empty", "Cube", "Sphere", "Plane", "Cylinder", "Light", "Camera"]
        let scene = engine.scene
        let entity = scene.create(names[shape.rawValue])
        var transform = Transform(position: spawnPoint())
        let material = defaultMaterial()
        switch shape {
        case .empty:
            break
        case .cube:
            transform.position.y = 0.5
            scene.add(entity, MeshRenderer(mesh: engine.assets.cube, material: material))
            scene.add(entity, Collider.box(halfExtents: Vec3(0.5, 0.5, 0.5)))
        case .sphere:
            transform.position.y = 0.5
            scene.add(entity, MeshRenderer(mesh: engine.assets.sphere, material: material))
            scene.add(entity, Collider.sphere(radius: 0.5))
        case .plane:
            transform.position.y = 0.01
            scene.add(entity, MeshRenderer(mesh: engine.assets.plane, material: material))
        case .cylinder:
            transform.position.y = 0.5
            scene.add(entity, MeshRenderer(mesh: engine.assets.cylinder, material: material))
            scene.add(entity, Collider.capsule(radius: 0.5, halfHeight: 0))
        case .pointLight:
            transform.position.y = 2
            scene.add(entity, Light(type: .point, intensity: 8, range: 8))
        case .camera:
            transform.position = cameraPosition
            transform.rotation = cameraRotation              // looks where the editor looks now
            var lens = Camera()
            lens.isActive = scene.count(Camera.self) <= 1    // the first one becomes the game's camera
            scene.add(entity, lens)
        }
        scene.add(entity, transform)
        selected = entity
        touched = true
        return entity
    }

    @discardableResult
    func addModel(_ engine: Engine, _ meshName: String) -> Entity {
        guard let mesh = engine.assets.mesh(meshName) else {
            say("Cannot load \(meshName)")
            return .invalid
        }
        // Name the entity after the file: "Models/gem.obj" -> "gem".
        let name = URL(fileURLWithPath: meshName).deletingPathExtension().lastPathComponent
        let entity = engine.scene.create(name)
        var transform = Transform(position: spawnPoint())
        transform.position.y = -mesh.bounds.min.y           // standing on the ground
        engine.scene.add(entity, transform)
        engine.scene.add(entity, MeshRenderer(mesh: mesh, material: defaultMaterial()))
        selected = entity
        touched = true
        return entity
    }

    func duplicateSelected(_ engine: Engine) {
        let scene = engine.scene
        guard var transform = scene[selected, Transform.self] else { return }
        let copy = scene.create(scene[selected, Name.self]?.value ?? "")
        transform.position += Vec3(1, 0, 0)                 // beside the original, so that both can be seen
        scene.add(copy, transform)
        // Components are plain values: copying an entity is copying each one.
        if let c = scene[selected, MeshRenderer.self] { scene.add(copy, c) }
        if let c = scene[selected, Light.self] { scene.add(copy, c) }
        if var c = scene[selected, Camera.self] {
            c.isActive = false
            scene.add(copy, c)
        }
        if let c = scene[selected, Collider.self] { scene.add(copy, c) }
        if let c = scene[selected, RigidBody.self] { scene.add(copy, c) }
        if var c = scene[selected, ParticleEmitter.self] {
            c.particles.removeAll()
            scene.add(copy, c)
        }
        selected = copy
        touched = true
    }

    func deleteSelected(_ engine: Engine) {
        let scene = engine.scene
        guard scene.isAlive(selected) else { return }
        // Children of the deleted entity stay, and become independent.
        let gone = selected
        scene.each(Transform.self) { _, transform in
            if transform.parent == gone { transform.parent = .invalid }
        }
        scene.destroy(gone)
        selected = .invalid
        touched = true
    }

    // MARK: - Undo and play

    /// Called at the end of every frame. When an edit has just been finished, the scene as
    /// it was before becomes the next thing Undo goes back to.
    private func recordUndo(_ engine: Engine) {
        if !touched || isPlaying || gui.isBusy || dragAxis >= 0 { return }
        touched = false
        let state = writeScene(engine.scene, materials: materials, settings: engine.renderer.settings)
        if state == current { return }
        undoStack.append(current)
        if undoStack.count > undoLevels { undoStack.removeFirst() }
        redoStack.removeAll()
        current = state
    }

    func undo(_ engine: Engine) {
        guard !isPlaying, let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
        restore(engine, current)
        say("Undo")
    }

    func redo(_ engine: Engine) {
        guard !isPlaying, let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
        restore(engine, current)
        say("Redo")
    }

    /// Play runs the scene: physics starts and the scene's own camera takes over. Stop puts
    /// everything back exactly as it was, from the text the scene was saved to in memory.
    func setPlaying(_ engine: Engine, _ playing: Bool) {
        if playing == isPlaying { return }
        if playing {
            beforePlay = writeScene(engine.scene, materials: materials, settings: engine.renderer.settings)
            isPlaying = true
            engine.physics.reset()
            // Without a camera of its own the scene is watched through the editor's.
            var hasCamera = false
            let own = camera
            engine.scene.each(Camera.self) { entity, lens in
                hasCamera = hasCamera || (entity != own && lens.isActive)
            }
            engine.renderer.cameraOverride = hasCamera ? .invalid : camera
            engine.scene[camera, Camera.self]?.isActive = !hasCamera
            engine.isSimulationPaused = false
            say("Playing. Press F5 or Stop to go back to editing")
        } else {
            isPlaying = false
            engine.isSimulationPaused = true
            restore(engine, beforePlay)
            say("Stopped")
        }
    }

    // MARK: - The frame

    private func handleShortcuts(_ engine: Engine) {
        let input = engine.input
        if gui.wantsKeyboard { return }
        if input.wasPressed(Key.f5) { setPlaying(engine, !isPlaying) }
        if isPlaying {
            if input.wasPressed(Key.escape) { setPlaying(engine, false) }
            return
        }
        let control = input.isDown(Key.leftControl) || input.isDown(Key.rightControl)
        let looking = input.isDown(MouseButton.right)       // W, E and R then move the camera instead
        if control {
            if input.wasPressed(Key.s) { saveScene(engine) }
            if input.wasPressed(Key.z) { undo(engine) }
            if input.wasPressed(Key.y) { redo(engine) }
            if input.wasPressed(Key.d) { duplicateSelected(engine) }
        } else if !looking {
            if input.wasPressed(Key.w) { tool = .move }
            if input.wasPressed(Key.e) { tool = .rotate }
            if input.wasPressed(Key.r) { tool = .scale }
            if input.wasPressed(Key.backspace) { deleteSelected(engine) }
            if input.wasPressed(Key.escape) { selected = .invalid }
            if input.wasPressed(Key.f), let transform = engine.scene[selected, Transform.self] {
                // Frame the selection: step back from it along the view direction.
                let forward = cameraRotation.act(Vec3(0, 0, -1))
                let size = max(transform.scale.x, transform.scale.y, transform.scale.z, 1)
                cameraPosition = transform.worldPosition - forward * (size * 4)
            }
        }
    }

    private func updateCamera(_ engine: Engine, dt: Float) {
        let input = engine.input
        // Hold the right button to look around and fly, as in most 3D editors.
        if input.isDown(MouseButton.right) && !gui.wantsMouse {
            cameraYaw -= input.mouseDelta.x * 0.005
            cameraPitch = min(max(cameraPitch - input.mouseDelta.y * 0.005, -1.5), 1.5)
            let rotation = cameraRotation
            var move = Vec3(0, 0, 0)
            if input.isDown(Key.w) { move += rotation.act(Vec3(0, 0, -1)) }
            if input.isDown(Key.s) { move += rotation.act(Vec3(0, 0, 1)) }
            if input.isDown(Key.a) { move += rotation.act(Vec3(-1, 0, 0)) }
            if input.isDown(Key.d) { move += rotation.act(Vec3(1, 0, 0)) }
            if input.isDown(Key.e) { move += Vec3(0, 1, 0) }
            if input.isDown(Key.q) { move += Vec3(0, -1, 0) }
            let speed: Float = input.isDown(Key.leftShift) ? 18 : 6
            cameraPosition += move * (speed * dt)
        }
        if !gui.wantsMouse && input.scrollDelta != 0 {
            cameraPosition += cameraRotation.act(Vec3(0, 0, -1)) * input.scrollDelta
        }
        engine.scene[camera, Transform.self]?.position = cameraPosition
        engine.scene[camera, Transform.self]?.rotation = cameraRotation
    }

    func draw(_ engine: Engine, canvas: Canvas) {
        now = engine.time.elapsed
        let screen = canvas.size

        listEntities(engine)
        if !engine.scene.isAlive(selected) { selected = .invalid }

        gui.begin(canvas, engine.input)
        handleShortcuts(engine)

        if isPlaying {
            // While playing the editor steps aside: one small panel to stop.
            gui.beginPanel("Playing", position: Vec2(screen.x * 0.5 - 90, 8), size: Vec2(180, 64))
            if gui.button("Stop (F5)") { setPlaying(engine, false) }
            gui.endPanel()
            gui.end()
            return
        }

        updateCamera(engine, dt: engine.time.unscaledDelta)
        drawViewport(engine, canvas)            // under the panels

        drawToolbar(engine, screen)
        let leftHeight = screen.y - toolbarHeight
        let sceneHeight = (leftHeight * 0.58).rounded(.down)
        drawScenePanel(engine, position: Vec2(0, toolbarHeight), size: Vec2(leftWidth, sceneHeight))
        drawAssetsPanel(engine, position: Vec2(0, toolbarHeight + sceneHeight), size: Vec2(leftWidth, leftHeight - sceneHeight))

        let titles = ["Inspector", "Materials", "Scene settings"]
        gui.beginPanel(titles[rightTab], position: Vec2(screen.x - rightWidth, toolbarHeight), size: Vec2(rightWidth, leftHeight))
        gui.tabs(["Inspector", "Materials", "Scene"], &rightTab)
        gui.separator()
        switch rightTab {
        case 0: drawInspector(engine)
        case 1: drawMaterials(engine)
        default: drawSettings(engine)
        }
        gui.endPanel()

        gui.end()
        if gui.changed { touched = true }
        recordUndo(engine)
        // What was created or moved in this frame is drawn in this frame: bring the world
        // matrices up to date again.
        engine.scene.updateTransforms()
    }
}
