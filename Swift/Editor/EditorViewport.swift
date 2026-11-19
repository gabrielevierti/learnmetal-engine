// What happens in the 3D view: outlines, the grid, picking with the mouse, the gizmo.

import LMEngine
import simd

private let axisColors = [rgb(0xe5484d), rgb(0x46a758), rgb(0x3e7bfa)]         // x red, y green, z blue
private let axes = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]

private func distanceToSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Float {
    let ab = b - a
    let lengthSquared = simd_dot(ab, ab)
    let t = lengthSquared > 0 ? min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1) : 0
    return simd_length(p - (a + ab * t))
}

extension Editor {
    /// Where a point of the world appears on screen, in points. Nil if it is behind the camera.
    func project(_ engine: Engine, _ world: Vec3) -> Vec2? {
        guard let transform = engine.scene[camera, Transform.self], let lens = engine.scene[camera, Camera.self] else { return nil }
        let size = engine.screenSize
        let view = Mat4.compose(position: transform.position, rotation: transform.rotation, scale: Vec3(1, 1, 1)).inverse
        let clip = lens.projection(aspect: size.x / size.y) * view * Vec4(world, 1)
        if clip.w <= 0.001 { return nil }
        return Vec2((clip.x / clip.w * 0.5 + 0.5) * size.x, (0.5 - clip.y / clip.w * 0.5) * size.y)
    }

    /// The entity under a point of the screen: the nearest one hit by the ray through it.
    func pick(_ engine: Engine, _ point: Vec2) -> Entity {
        guard let ray = engine.screenRay(point) else { return .invalid }
        var best = Entity.invalid
        var bestDistance = Float.greatestFiniteMagnitude
        for entity in entities {
            guard let transform = engine.scene[entity, Transform.self] else { continue }
            var hit: Float?
            if let mesh = engine.scene[entity, MeshRenderer.self]?.mesh {
                // Test against the mesh's box in the mesh's own space: bring the ray there.
                // The direction is left unnormalized, so the distance keeps its world scale.
                let toLocal = transform.world.inverse
                let local = Ray(origin: toLocal.transformPoint(ray.origin), direction: toLocal.transformDirection(ray.direction))
                hit = intersectAABB(local, mesh.bounds)
            } else {
                hit = intersectSphere(ray, center: transform.worldPosition, radius: 0.35)      // lights and cameras: their icon
            }
            if let distance = hit, distance < bestDistance {
                bestDistance = distance
                best = entity
            }
        }
        return best
    }

    func drawGrid(_ engine: Engine) {
        let lines = engine.debug
        let half = 10
        for i in -half...half {
            let color = i == 0 ? Vec4(0.5, 0.5, 0.5, 1) : Vec4(0.22, 0.24, 0.27, 1)
            lines.line(Vec3(Float(i), 0.002, Float(-half)), Vec3(Float(i), 0.002, Float(half)), color)
            lines.line(Vec3(Float(-half), 0.002, Float(i)), Vec3(Float(half), 0.002, Float(i)), color)
        }
    }

    /// Lines around the selected entity: the box of its mesh, and what its other components mean in space.
    func drawOutline(_ engine: Engine, _ entity: Entity) {
        let lines = engine.debug
        guard let transform = engine.scene[entity, Transform.self] else { return }
        let orange = Vec4(1.0, 0.55, 0.24, 1)
        let position = transform.worldPosition

        if let mesh = engine.scene[entity, MeshRenderer.self]?.mesh {
            // The eight corners of the mesh's box, moved to the world, joined by twelve edges.
            let box = mesh.bounds
            var corners: [Vec3] = []
            for i in 0..<8 {
                let corner = Vec3(i & 1 != 0 ? box.max.x : box.min.x, i & 2 != 0 ? box.max.y : box.min.y, i & 4 != 0 ? box.max.z : box.min.z)
                corners.append(transform.world.transformPoint(corner))
            }
            for i in 0..<8 {
                for bit in [1, 2, 4] where i & bit == 0 {
                    lines.line(corners[i], corners[i | bit], orange)
                }
            }
        }
        if let light = engine.scene[entity, Light.self] {
            let color = Vec4(light.color, 1)
            let forward = safeNormalize(transform.world.transformDirection(Vec3(0, 0, -1)))
            if light.type == .point {
                lines.sphere(center: position, radius: light.range, color, segments: 32)
            } else {
                lines.line(position, position + forward * (light.type == .spot ? light.range : 3), color)
            }
        }
        if engine.scene.has(Camera.self, entity) { lines.axes(transform.world, size: 1) }
        if let collider = engine.scene[entity, Collider.self] {
            let green = Vec4(0.3, 1.0, 0.4, 1)
            let center = transform.position + transform.rotation.act(collider.offset)
            switch collider.shape {
            case .sphere:
                lines.sphere(center: center, radius: collider.radius, green)
            case .box:
                lines.box(center: center, halfExtents: collider.halfExtents, rotation: transform.rotation, green)
            case .capsule:
                let axis = transform.rotation.act(Vec3(0, collider.halfHeight, 0))
                lines.sphere(center: center + axis, radius: collider.radius, green, segments: 16)
                lines.sphere(center: center - axis, radius: collider.radius, green, segments: 16)
            }
        }
    }

    /// Draws the three handles of the current tool on the selected entity and applies a drag
    /// on one of them. Returns true if the mouse is on the gizmo, so that the click is not
    /// also taken as "select what is behind it".
    func updateGizmo(_ engine: Engine, _ canvas: Canvas) -> Bool {
        let input = engine.input
        guard var transform = engine.scene[selected, Transform.self] else {
            dragAxis = -1
            return false
        }
        let origin = transform.worldPosition
        guard let center = project(engine, origin) else { return false }
        // The same size on screen however far away the entity is.
        let size = simd_distance(cameraPosition, origin) * 0.16

        if dragAxis >= 0 && !input.isDown(MouseButton.left) {
            dragAxis = -1
            touched = true                      // the drag is over: one step for Undo
        }

        let mouseFree = !gui.wantsMouse && !input.isDown(MouseButton.right)
        var onGizmo = dragAxis >= 0
        for i in 0..<3 {
            // Moving and rotating use the axes of the world; scaling stretches the entity
            // along its own axes, because that is what Transform.scale means.
            let axis = tool == .scale ? safeNormalize(transform.world.transformDirection(axes[i])) : axes[i]
            guard let tip = project(engine, origin + axis * size) else { continue }
            let hot = dragAxis == i || (dragAxis < 0 && mouseFree && distanceToSegment(input.mousePosition, center, tip) < 9)
            if hot { onGizmo = true }

            if hot && dragAxis < 0 && input.wasPressed(MouseButton.left) {
                dragAxis = i
                let along = tip - center
                let length = simd_length(along)
                dragDirection = length > 1 ? along / length : Vec2(1, 0)
                dragPointsPerUnit = max(length / size, 1)
            }
            if dragAxis == i {
                // How far the pointer moved along the handle, in points.
                let travel = simd_dot(input.mouseDelta, dragDirection)
                switch tool {
                case .move:
                    var delta = axis * (travel / dragPointsPerUnit)
                    // Transform.position is relative to the parent: express the step there.
                    if let parent = engine.scene[transform.parent, Transform.self] {
                        delta = parent.world.inverse.transformDirection(delta)
                    }
                    transform.position += delta
                case .rotate:
                    transform.rotation = simd_normalize(Quat(angle: travel * 0.012, axis: axis) * transform.rotation)
                case .scale:
                    transform.scale[i] = max(0.01, transform.scale[i] * (1 + travel * 0.01))
                }
                engine.scene[selected, Transform.self] = transform
            }

            canvas.line(from: center, to: tip, thickness: hot ? 5 : 3, axisColors[i])
            switch tool {
            case .move:
                canvas.circle(center: tip, radius: hot ? 8 : 6, axisColors[i], segments: 16)
            case .scale:
                let h: Float = hot ? 7 : 5.5
                canvas.rect(tip - Vec2(h, h), Vec2(h * 2, h * 2), axisColors[i])
            case .rotate:
                canvas.circle(center: tip, radius: hot ? 9 : 7, axisColors[i])
                canvas.circle(center: tip, radius: hot ? 5.5 : 4, rgb(0x14181f))        // a ring: this handle turns
            }
        }
        canvas.circle(center: center, radius: 4, rgb(0xffffff))
        return onGizmo
    }

    func drawViewport(_ engine: Engine, _ canvas: Canvas) {
        let input = engine.input
        drawGrid(engine)
        if engine.scene.isAlive(selected) { drawOutline(engine, selected) }

        // Lights, cameras and emitters have no mesh to see or click: give them a small disc.
        for entity in entities where engine.scene[entity, MeshRenderer.self]?.mesh == nil {
            let light = engine.scene[entity, Light.self]
            let letter = light != nil ? "L" : engine.scene.has(Camera.self, entity) ? "C"
                : engine.scene.has(ParticleEmitter.self, entity) ? "P" : ""
            guard !letter.isEmpty, let position = engine.scene[entity, Transform.self]?.worldPosition,
                  let at = project(engine, position) else { continue }
            canvas.circle(center: at, radius: 11, entity == selected ? rgb(0xfe8b3c) : rgb(0x14181f, alpha: 0.85), segments: 20)
            let fill = light.map { Vec4(saturate($0.color.x), saturate($0.color.y), saturate($0.color.z), 1) } ?? rgb(0x8d96a3)
            canvas.circle(center: at, radius: 8.5, fill, segments: 20)
            canvas.text(letter, at + Vec2(0, -7), size: 11, rgb(0x14181f), align: .center)
        }

        let onGizmo = updateGizmo(engine, canvas)
        if !onGizmo && !gui.wantsMouse && input.wasPressed(MouseButton.left) { selected = pick(engine, input.mousePosition) }
    }
}
