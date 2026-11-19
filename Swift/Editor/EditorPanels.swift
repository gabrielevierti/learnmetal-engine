// The panels: the toolbar, the list of entities, the assets, and on the right the
// inspector, the materials and the scene settings.

import Foundation
import LMEngine
import simd

/// An angle shown in degrees and kept in radians.
@MainActor
private func dragDegrees(_ gui: Gui, _ label: String, _ radiansValue: inout Float, _ range: ClosedRange<Float>) {
    var shown = degrees(radiansValue)
    if gui.dragFloat(label, &shown, speed: 0.5, range: range) { radiansValue = radians(shown) }
}

/// The color part of a color with alpha.
@MainActor
private func colorOf(_ gui: Gui, _ label: String, _ value: inout Vec4) {
    var color = xyz(value)
    if gui.color(label, &color) { value = Vec4(color, value.w) }
}

extension Editor {
    /// The bar along the top: what is open on the left, Play in the middle, and on the right
    /// the things done to the whole scene or to the selection.
    func drawToolbar(_ engine: Engine, _ canvas: Canvas, _ screen: Vec2) {
        let height = toolbarHeight
        gui.bar(position: Vec2(0, 0), size: Vec2(screen.x, height))
        let style = gui.style
        let middle = (height - style.fontSize) * 0.5 - 1

        // The mark, the name of the scene, and a dot while there are changes to save.
        canvas.roundedRect(Vec2(12, height * 0.5 - 9), Vec2(18, 18), radius: 5, style.accent)
        gui.icon(.cube, center: Vec2(21, height * 0.5), size: 12, style.chrome)
        canvas.text("LearnMetal Editor", Vec2(40, middle), size: style.fontSize, style.text)
        let nameX = 40 + canvas.measureText("LearnMetal Editor", size: style.fontSize).x + 16
        canvas.text(sceneName + ".scene", Vec2(nameX, middle), size: style.fontSize, style.textDim)
        if hasUnsavedChanges {
            let dotX = nameX + canvas.measureText(sceneName + ".scene", size: style.fontSize).x + 9
            canvas.circle(center: Vec2(dotX, height * 0.5), radius: 3, style.accent)
        }

        let side = height - 14
        let top: Float = 7
        if gui.button("Play", position: Vec2(screen.x * 0.5 - 42, top), size: Vec2(84, side), icon: .play) { setPlaying(engine, true) }

        // From the right edge inward. A gap separates the three groups.
        let actions: [(icon: Gui.Icon, tooltip: String, gapAfter: Float)] = [
            (.trash, "Delete (Backspace)", 0), (.copy, "Duplicate (Ctrl D)", 14), (.redo, "Redo (Ctrl Y)", 0),
            (.undo, "Undo (Ctrl Z)", 14), (.save, "Save (Ctrl S)", 0), (.file, "New scene", 0),
        ]
        var x = screen.x - 10
        for (index, action) in actions.enumerated() {
            x -= side
            if gui.iconButton(action.icon, position: Vec2(x, top), size: Vec2(side, side), tooltip: action.tooltip) {
                switch index {
                case 0: deleteSelected(engine)
                case 1: duplicateSelected(engine)
                case 2: redo(engine)
                case 3: undo(engine)
                case 4: saveScene(engine)
                default: newScene(engine)
                }
            }
            x -= 2 + action.gapAfter
        }
    }

    /// The three tools, on a small card that floats over the top left corner of the view.
    func drawTools(position: Vec2) {
        let side: Float = 30, gap: Float = 2, padding: Float = 4
        gui.card(position: position, size: Vec2(padding * 2 + side * 3 + gap * 2, padding * 2 + side))
        let tools: [(icon: Gui.Icon, tooltip: String, tool: Tool)] = [
            (.move, "Move (W)", .move), (.rotate, "Rotate (E)", .rotate), (.scale, "Scale (R)", .scale),
        ]
        for (index, entry) in tools.enumerated() {
            let at = position + Vec2(padding + Float(index) * (side + gap), padding)
            if gui.iconButton(entry.icon, position: at, size: Vec2(side, side), tooltip: entry.tooltip, isSelected: tool == entry.tool) {
                tool = entry.tool
            }
        }
    }

    /// The bar along the bottom: the last thing the editor said, and what the renderer is drawing.
    func drawStatusBar(_ engine: Engine, _ canvas: Canvas, _ screen: Vec2, height: Float) {
        let position = Vec2(0, screen.y - height)
        gui.bar(position: position, size: Vec2(screen.x, height))
        let style = gui.style
        let y = position.y + (height - 12) * 0.5 - 1
        let hasMessage = now < statusUntil
        canvas.text(hasMessage ? status : "Right mouse button: look around. Wheel: closer and farther. Click: select.", Vec2(12, y), size: 12,
                    hasMessage ? style.text : style.textFaint)
        let stats = engine.renderer.stats
        let right = "\(entities.count) entities      \(stats.drawCalls) draw calls      \(stats.triangles) triangles"
        canvas.text(right, Vec2(screen.x - 12, y), size: 12, style.textFaint, align: .right)
    }

    func drawScenePanel(_ engine: Engine, position: Vec2, size: Vec2) {
        gui.beginPanel("Scene", position: position, size: size)
        var add = -1
        if gui.combo("Add", &add, ["Empty", "Cube", "Sphere", "Plane", "Cylinder", "Light", "Camera"]), let shape = Shape(rawValue: add) {
            addEntity(engine, shape)
        }
        gui.separator()

        for entity in entities {
            // Children are indented under their parent, one step per level.
            var indent: Float = 0
            var parent = engine.scene[entity, Transform.self]?.parent ?? .invalid
            var depth = 0
            while depth < 8, let above = engine.scene[parent, Transform.self] {
                indent += 14
                parent = above.parent
                depth += 1
            }
            let name = engine.scene[entity, Name.self]?.value ?? ""
            // The icon says what kind of thing this is: the first of these it has.
            let icon: Gui.Icon = engine.scene.has(Light.self, entity) ? .light : engine.scene.has(Camera.self, entity) ? .camera
                : engine.scene.has(MeshRenderer.self, entity) ? .cube : .empty
            if gui.selectable(name.isEmpty ? "(no name)" : name, selected: entity == selected, indent: indent, icon: icon) {
                selected = entity
                rightTab = 0
            }
        }
        gui.endPanel()
    }

    func drawAssetsPanel(_ engine: Engine, position: Vec2, size: Vec2) {
        gui.beginPanel("Assets", position: position, size: size)
        gui.textField("Save as", &sceneName)

        if gui.section("Scenes (click to open)") {
            for name in sceneNames where gui.selectable(name, selected: name == sceneName, icon: .file) {
                openScene(engine, name)
                break                               // the scene changed under our feet: stop drawing its list
            }
        }
        if gui.section("Models (click to add)") {
            for name in meshNames.dropFirst(4) where gui.selectable(String(name.dropFirst(7)), selected: false, icon: .cube) {
                addModel(engine, name)
            }
        }
        if gui.section("Textures (click: base color)") {
            for name in textureNames where gui.selectable(String(name.dropFirst(9)), selected: false, icon: .image) {
                // Goes to the material being edited, as its color map.
                defaultMaterial().baseColorTexture = engine.assets.texture(name, format: .rgba8sRGB)
                say("\(name.dropFirst(9)) is now the base color of \(materials[selectedMaterial].name)")
                rightTab = 1
                touched = true
            }
            gui.endPanel()
        }
    }

    // MARK: - Inspector

    func drawInspector(_ engine: Engine) {
        let scene = engine.scene
        guard var transform = scene[selected, Transform.self] else {
            gui.label("Nothing selected.")
            gui.label("Click something in the view or in the list.")
            return
        }

        var name = scene[selected, Name.self]?.value ?? ""
        if gui.textField("Name", &name) { scene.add(selected, Name(name)) }

        // The parent: any other entity, as long as that does not close a loop.
        var parentNames = ["(none)"]
        var parentChoices = [Entity.invalid]
        for candidate in entities {
            var isDescendant = false
            var up = candidate
            var depth = 0
            while depth < 64 && scene.isAlive(up) {
                if up == selected { isDescendant = true }
                up = scene[up, Transform.self]?.parent ?? .invalid
                depth += 1
            }
            if isDescendant { continue }
            parentNames.append(scene[candidate, Name.self]?.value ?? "(no name)")
            parentChoices.append(candidate)
        }
        var parentIndex = parentChoices.firstIndex(of: transform.parent) ?? 0
        if gui.combo("Parent", &parentIndex, parentNames) { transform.parent = parentChoices[parentIndex] }

        if gui.section("Transform") {
            gui.dragVec3("Position", &transform.position, speed: 0.02)
            // Angles are shown in degrees and remembered while the selection stays the same:
            // converting the rotation back to angles every frame would make the numbers jump.
            if simd_dot(shownRotation.vector, transform.rotation.vector) < 0.999999 {
                shownAngles = transform.rotation.eulerAngles * (180 / Float.pi)
                shownRotation = transform.rotation
            }
            if gui.dragVec3("Rotation", &shownAngles, speed: 0.5) {
                transform.rotation = Quat(pitch: radians(shownAngles.x), yaw: radians(shownAngles.y), roll: radians(shownAngles.z))
                shownRotation = transform.rotation
            }
            gui.dragVec3("Scale", &transform.scale, speed: 0.01)
        }
        // Components are values: what was edited above is a copy, and this stores it back.
        scene[selected, Transform.self] = transform

        if var renderer = scene[selected, MeshRenderer.self] {
            if gui.section("Mesh") {
                var meshIndex = renderer.mesh.flatMap { meshNames.firstIndex(of: $0.name) } ?? -1
                if gui.combo("Mesh", &meshIndex, meshNames) { renderer.mesh = engine.assets.mesh(meshNames[meshIndex]) }
                var materialIndex = materials.firstIndex { $0.material === renderer.material } ?? -1
                if gui.combo("Material", &materialIndex, materials.map { $0.name }) {
                    renderer.material = materials[materialIndex].material
                    selectedMaterial = materialIndex
                }
                colorOf(gui, "Tint", &renderer.tint)
                gui.checkbox("Casts shadows", &renderer.castsShadows)
                gui.checkbox("Visible", &renderer.isVisible)
                if gui.button("Remove mesh") {
                    scene.remove(MeshRenderer.self, selected)
                } else {
                    scene[selected, MeshRenderer.self] = renderer
                }
            }
        }

        if var light = scene[selected, Light.self] {
            if gui.section("Light") {
                var type = Int(light.type.rawValue)
                if gui.combo("Type", &type, ["Directional", "Point", "Spot"]) { light.type = LightType(rawValue: UInt32(type)) ?? .point }
                gui.color("Color", &light.color)
                gui.dragFloat("Intensity", &light.intensity, speed: 0.05, range: 0...1000)
                if light.type != .directional { gui.dragFloat("Range", &light.range, speed: 0.05, range: 0.1...500) }
                if light.type == .spot {
                    dragDegrees(gui, "Inner cone", &light.innerConeAngle, 0...89)
                    dragDegrees(gui, "Outer cone", &light.outerConeAngle, 0...89)
                }
                if light.type == .directional { gui.checkbox("Casts shadows", &light.castsShadows) }
                if gui.button("Remove light") {
                    scene.remove(Light.self, selected)
                } else {
                    scene[selected, Light.self] = light
                }
            }
        }

        if var lens = scene[selected, Camera.self] {
            if gui.section("Camera") {
                dragDegrees(gui, "Field of view", &lens.fovY, 5...150)
                gui.dragFloat("Near", &lens.nearPlane, speed: 0.01, range: 0.01...10)
                gui.dragFloat("Far", &lens.farPlane, speed: 1, range: 1...5000)
                gui.checkbox("Used when playing", &lens.isActive)
                if gui.button("Remove camera") {
                    scene.remove(Camera.self, selected)
                } else {
                    scene[selected, Camera.self] = lens
                }
            }
        }

        if var collider = scene[selected, Collider.self] {
            if gui.section("Collider") {
                let shapes = [ColliderShape.sphere, .box, .capsule]
                var shape = shapes.firstIndex(of: collider.shape) ?? 1
                if gui.combo("Shape", &shape, ["Sphere", "Box", "Capsule"]) { collider.shape = shapes[shape] }
                if collider.shape == .box {
                    gui.dragVec3("Half size", &collider.halfExtents, speed: 0.01)
                } else {
                    gui.dragFloat("Radius", &collider.radius, speed: 0.01, range: 0.01...100)
                    if collider.shape == .capsule { gui.dragFloat("Half height", &collider.halfHeight, speed: 0.01, range: 0...100) }
                }
                gui.dragVec3("Offset", &collider.offset, speed: 0.01)
                gui.checkbox("Trigger", &collider.isTrigger)
            }
            if let mesh = scene[selected, MeshRenderer.self]?.mesh, gui.button("Fit to mesh") {
                // Colliders ignore Transform.scale, so the scale goes into their size.
                let half = mesh.bounds.halfExtents * transform.scale
                collider.halfExtents = half
                collider.radius = collider.shape == .sphere ? max(half.x, half.y, half.z) : max(half.x, half.z)
                collider.halfHeight = max(half.y - collider.radius, 0)
                collider.offset = mesh.bounds.center * transform.scale
                touched = true
            }
            if gui.button("Remove collider") {
                scene.remove(Collider.self, selected)
            } else {
                scene[selected, Collider.self] = collider
            }
        }

        if var body = scene[selected, RigidBody.self] {
            if gui.section("Body") {
                let types = [BodyType.static, .kinematic, .dynamic]
                var type = types.firstIndex(of: body.type) ?? 2
                if gui.combo("Type", &type, ["Static", "Kinematic", "Dynamic"]) { body.type = types[type] }
                gui.dragFloat("Mass", &body.mass, speed: 0.05, range: 0.01...10000)
                gui.dragFloat("Bounce", &body.restitution, speed: 0.01, range: 0...1)
                gui.dragFloat("Friction", &body.friction, speed: 0.01, range: 0...2)
                gui.dragFloat("Air drag", &body.linearDamping, speed: 0.01, range: 0...10)
                gui.dragFloat("Gravity", &body.gravityScale, speed: 0.01, range: -10...10)
                if gui.button("Remove body") {
                    scene.remove(RigidBody.self, selected)
                } else {
                    scene[selected, RigidBody.self] = body
                }
            }
        }

        if var emitter = scene[selected, ParticleEmitter.self] {
            if gui.section("Particles") {
                gui.dragFloat("Per second", &emitter.rate, speed: 0.5, range: 0...5000)
                gui.dragFloat("Life, shortest", &emitter.lifetimeMin, speed: 0.01, range: 0.01...60)
                gui.dragFloat("Life, longest", &emitter.lifetimeMax, speed: 0.01, range: 0.01...60)
                gui.dragFloat("Speed, slowest", &emitter.speedMin, speed: 0.02, range: 0...100)
                gui.dragFloat("Speed, fastest", &emitter.speedMax, speed: 0.02, range: 0...100)
                gui.dragVec3("Direction", &emitter.direction, speed: 0.01)
                dragDegrees(gui, "Spread", &emitter.spread, 0...180)
                gui.dragVec3("Gravity", &emitter.gravity, speed: 0.02)
                gui.dragFloat("Size at start", &emitter.sizeStart, speed: 0.005, range: 0...10)
                gui.dragFloat("Size at end", &emitter.sizeEnd, speed: 0.005, range: 0...10)
                colorOf(gui, "Color at start", &emitter.colorStart)
                colorOf(gui, "Color at end", &emitter.colorEnd)
                gui.checkbox("Additive", &emitter.isAdditive)
                if gui.button("Remove particles") {
                    scene.remove(ParticleEmitter.self, selected)
                } else {
                    scene[selected, ParticleEmitter.self] = emitter
                }
            }
        }

        // Only the components the entity does not have yet are offered.
        if gui.section("Add a component") {
            var missing: [String] = []
            if !scene.has(MeshRenderer.self, selected) { missing.append("Mesh") }
            if !scene.has(Light.self, selected) { missing.append("Light") }
            if !scene.has(Camera.self, selected) { missing.append("Camera") }
            if !scene.has(Collider.self, selected) { missing.append("Collider") }
            if !scene.has(RigidBody.self, selected) { missing.append("Body") }
            if !scene.has(ParticleEmitter.self, selected) { missing.append("Particles") }
            var choice = -1
            if gui.combo("Component", &choice, missing) {
                switch missing[choice] {
                case "Mesh": scene.add(selected, MeshRenderer(mesh: engine.assets.cube, material: defaultMaterial()))
                case "Light": scene.add(selected, Light())
                case "Camera":
                    var lens = Camera()
                    lens.isActive = false
                    scene.add(selected, lens)
                case "Collider": scene.add(selected, Collider())
                case "Body": scene.add(selected, RigidBody())
                default: scene.add(selected, ParticleEmitter())
                }
            }
        }
    }

    // MARK: - Materials

    /// One texture of a material: a list of the image files, with "(none)" first.
    func textureSlot(_ engine: Engine, _ label: String, _ slot: inout Texture?, _ format: TextureFormat) {
        let names = ["(none)"] + textureNames.map { String($0.dropFirst(9)) }      // without "Textures/"
        var index = slot.flatMap { textureNames.firstIndex(of: $0.name) }.map { $0 + 1 } ?? 0
        if gui.combo(label, &index, names) {
            slot = index > 0 ? engine.assets.texture(textureNames[index - 1], format: format) : nil
        }
    }

    func drawMaterials(_ engine: Engine) {
        _ = defaultMaterial()
        for (i, named) in materials.enumerated() where gui.selectable(named.name, selected: i == selectedMaterial, icon: .material) {
            selectedMaterial = i
        }
        switch gui.buttonRow(["New", "Copy", "Delete", "Assign"]) {
        case 0:
            materials.append(NamedMaterial(name: "Material \(materials.count + 1)", material: Material()))
            selectedMaterial = materials.count - 1
            touched = true
        case 1:
            let source = materials[selectedMaterial]
            materials.append(NamedMaterial(name: source.name + " copy", material: source.material.copy()))
            selectedMaterial = materials.count - 1
            touched = true
        case 2:
            if materials.count > 1 {
                // Whatever used it falls back to the first material.
                let gone = materials.remove(at: selectedMaterial).material
                selectedMaterial = 0
                let fallback = materials[0].material
                engine.scene.each(MeshRenderer.self) { _, renderer in
                    if renderer.material === gone { renderer.material = fallback }
                }
                touched = true
            }
        case 3:
            if engine.scene.has(MeshRenderer.self, selected) {
                engine.scene[selected, MeshRenderer.self]?.material = materials[selectedMaterial].material
                touched = true
            }
        default:
            break
        }

        let material = materials[selectedMaterial].material
        if gui.section("Surface") {
            gui.textField("Name", &materials[selectedMaterial].name)
            colorOf(gui, "Base color", &material.baseColor)
            gui.dragFloat("Opacity", &material.baseColor.w, speed: 0.005, range: 0...1)
            gui.dragFloat("Metallic", &material.metallic, speed: 0.005, range: 0...1)
            gui.dragFloat("Roughness", &material.roughness, speed: 0.005, range: 0...1)
            gui.color("Emissive", &material.emissive)
            let modes = [AlphaMode.opaque, .mask, .blend]
            var alpha = modes.firstIndex(of: material.alphaMode) ?? 0
            if gui.combo("Transparency", &alpha, ["Opaque", "Cut out", "Blend"]) { material.alphaMode = modes[alpha] }
            if material.alphaMode == .mask { gui.dragFloat("Cut below", &material.alphaCutoff, speed: 0.005, range: 0...1) }
            gui.checkbox("Double sided", &material.isDoubleSided)
            gui.checkbox("Unlit", &material.isUnlit)
        }

        if gui.section("Textures") {
            textureSlot(engine, "Base color", &material.baseColorTexture, .rgba8sRGB)
            textureSlot(engine, "Normal", &material.normalTexture, .rgba8)
            textureSlot(engine, "Rough / metal", &material.metallicRoughnessTexture, .rgba8)
            textureSlot(engine, "Occlusion", &material.occlusionTexture, .rgba8)
            textureSlot(engine, "Emissive", &material.emissiveTexture, .rgba8sRGB)
            gui.dragFloat("Normal strength", &material.normalScale, speed: 0.01, range: 0...4)
            gui.dragFloat("Repeat X", &material.uvScale.x, speed: 0.01, range: 0.01...100)
            gui.dragFloat("Repeat Y", &material.uvScale.y, speed: 0.01, range: 0.01...100)
        }
    }

    // MARK: - Scene settings

    func drawSettings(_ engine: Engine) {
        // The settings are a value: edit a copy, then hand it back to the renderer.
        var settings = engine.renderer.settings
        if gui.section("Sky") {
            gui.color("Zenith", &settings.sky.zenithColor)
            gui.color("Horizon", &settings.sky.horizonColor)
            gui.color("Ground", &settings.sky.groundColor)
            gui.dragFloat("Sky brightness", &settings.sky.intensity, speed: 0.01, range: 0...20)
            gui.dragFloat("Light from sky", &settings.environmentIntensity, speed: 0.01, range: 0...10)
            gui.dragFloat("Clouds", &settings.sky.cloudCoverage, speed: 0.005, range: 0...1)
            gui.dragFloat("Cloud size", &settings.sky.cloudScale, speed: 0.01, range: 0.1...8)
        }

        if gui.section("Camera") {
            gui.dragFloat("Exposure", &settings.exposure, speed: 0.01, range: 0.01...20)
            gui.combo("Tone mapping", &settings.toneMapper, ["ACES", "Reinhard", "None"])
            gui.dragFloat("Vignette", &settings.vignette, speed: 0.005, range: 0...1)
            gui.dragFloat("Lens bend", &settings.lensDistortion, speed: 0.005, range: 0...1)
            gui.dragFloat("Color fringes", &settings.chromaticAberration, speed: 0.0005, range: 0...0.05)
            gui.dragFloat("Grain", &settings.filmGrain, speed: 0.001, range: 0...0.3)
        }

        if gui.section("Effects") {
            gui.checkbox("Bloom", &settings.bloomEnabled)
            gui.dragFloat("Bloom strength", &settings.bloomIntensity, speed: 0.002, range: 0...1)
            gui.dragFloat("Bloom from", &settings.bloomThreshold, speed: 0.01, range: 0...20)
            gui.checkbox("Ambient occlusion", &settings.ambientOcclusionEnabled)
            gui.dragFloat("Occlusion radius", &settings.ambientOcclusionRadius, speed: 0.01, range: 0.05...5)
            gui.dragFloat("Occlusion strength", &settings.ambientOcclusionIntensity, speed: 0.01, range: 0...4)
            gui.checkbox("Sun shadows", &settings.shadowsEnabled)
            gui.dragFloat("Shadow distance", &settings.cascades.shadowDistance, speed: 0.5, range: 5...500)
        }

        if gui.section("Fog") {
            gui.color("Fog color", &settings.fogColor)
            gui.dragFloat("Fog density", &settings.fogDensity, speed: 0.0005, range: 0...1)
        }
        engine.renderer.settings = settings
    }
}
