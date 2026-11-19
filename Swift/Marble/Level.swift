// Level.swift
// The level: what is in it and where. Also the game's own components, which shows that
// a component can be any plain struct: the engine does not need to know about them.

import LMEngine
import simd

/// Something to collect. The entity also carries a mesh, a light and a trigger collider.
struct Gem {
    var home: Vec3              // the gem bobs up and down around this point
    var phase: Float            // so that the gems do not all move in step
    var color: Vec3
}

/// A platform that glides back and forth between two points.
struct MovingPlatform {
    var from: Vec3
    var to: Vec3
    var period: Float           // seconds for a round trip
}

/// Destroys its entity when the time runs out: for one-shot effects.
struct Lifetime {
    var seconds: Float
}

struct Level {
    static let marbleRadius: Float = 0.5

    var marble = Entity.invalid
    var camera = Entity.invalid
    var goal = Entity.invalid
    var ferry = Entity.invalid          // the moving platform
    var start = Vec3(0, 1, 0)           // where the marble begins
    var gemCount = 0
    var goalMaterial = Material()       // changes color when the goal opens
}

/// Builds the level out of boxes. Boxes of the same size share one mesh, so the
/// renderer can draw them together as instances.
@MainActor
private final class Builder {
    let engine: Engine
    var boxMeshes: [String: Mesh] = [:]

    init(_ engine: Engine) {
        self.engine = engine
    }

    func boxMesh(_ size: Vec3) -> Mesh {
        let key = "\(size.x) \(size.y) \(size.z)"
        if let found = boxMeshes[key] { return found }
        // Half a texture repeat per meter: the tile texture has 4 tiles across, so tiles are 50 cm.
        let mesh = engine.assets.makeMesh(MeshData.cube(size: size, uvPerUnit: 0.5))
        boxMeshes[key] = mesh
        return mesh
    }

    /// A solid box: something to roll on or bump into.
    @discardableResult
    func block(_ name: String, center: Vec3, size: Vec3, _ material: Material, rotation: Quat = .identity) -> Entity {
        let entity = engine.scene.create(name)
        engine.scene.add(entity, Transform(position: center, rotation: rotation))
        engine.scene.add(entity, MeshRenderer(mesh: boxMesh(size), material: material))
        engine.scene.add(entity, Collider.box(halfExtents: size * 0.5))
        return entity
    }
}

@MainActor
private func texturedMaterial(_ assets: Assets, _ name: String) -> Material {
    let prefix = "Textures/" + name
    let material = Material()
    // Factors of 1 let the textures decide: roughness comes from green, metalness from blue.
    material.metallic = 1
    material.roughness = 1
    material.baseColorTexture = assets.texture(prefix + "_basecolor.png")
    material.normalTexture = assets.texture(prefix + "_normal.png", format: .rgba8)
    material.metallicRoughnessTexture = assets.texture(prefix + "_orm.png", format: .rgba8)
    material.occlusionTexture = material.metallicRoughnessTexture      // same file: occlusion is its red channel
    return material
}

/// Fills the scene (which must be empty) and says where the important things are.
@MainActor
func buildLevel(_ engine: Engine) -> Level {
    let scene = engine.scene
    let assets = engine.assets
    var level = Level()
    let builder = Builder(engine)

    // ---- materials
    let stone = texturedMaterial(assets, "tiles")
    let paint = assets.makeMaterial(baseColor: Vec4(0.95, 0.42, 0.08, 1), metallic: 0, roughness: 0.45)     // the moving platform
    let wood = assets.makeMaterial(baseColor: Vec4(0.72, 0.5, 0.28, 1), metallic: 0, roughness: 0.8)
    wood.baseColorTexture = assets.texture("Textures/checker_basecolor.png")
    let fence = texturedMaterial(assets, "grate")
    fence.alphaMode = .mask                 // the holes are cut out, also from its shadow
    fence.isDoubleSided = true
    fence.uvScale = Vec2(3, 1)

    // ---- light: one sun. It is the first directional light, so it casts the shadows.
    let sun = scene.create("Sun")
    let sunDirection = simd_normalize(Vec3(0.55, -0.75, -0.4))             // the direction the light travels
    scene.add(sun, Transform(rotation: .lookRotation(forward: sunDirection)))
    scene.add(sun, Light(type: .directional, color: Vec3(1.0, 0.94, 0.82), intensity: 3.5, castsShadows: true))

    // ---- the course. Platforms are 1 m thick; y is the height of their top surface minus 0.5.
    builder.block("Start", center: Vec3(0, -0.5, 0), size: Vec3(8, 1, 8), stone)
    builder.block("Bridge", center: Vec3(0, -0.5, -9), size: Vec3(2.5, 1, 10), stone)
    builder.block("Plaza", center: Vec3(0, -0.5, -18), size: Vec3(8, 1, 8), stone)
    // A ramp is a box tilted around the z axis: it climbs 2.5 m toward +x.
    builder.block("Ramp", center: Vec3(8.75, 0.72, -18), size: Vec3(10.2, 1, 3), stone,
                  rotation: Quat(angle: radians(14.5), axis: Vec3(0, 0, 1)))
    builder.block("Terrace", center: Vec3(17, 2, -18), size: Vec3(7, 1, 7), stone)
    builder.block("Landing", center: Vec3(17, 2, -1), size: Vec3(7, 1, 7), stone)
    builder.block("Path 1", center: Vec3(17, 2, 4.5), size: Vec3(1.6, 1, 4), stone)
    builder.block("Path 2", center: Vec3(15, 2, 8), size: Vec3(5.6, 1, 1.6), stone)
    builder.block("Path 3", center: Vec3(13, 2, 11.5), size: Vec3(1.6, 1, 5.4), stone)
    builder.block("Summit", center: Vec3(13, 2, 18), size: Vec3(7, 1, 7), stone)

    // Low walls so the plaza is not too easy to fall from.
    builder.block("Wall", center: Vec3(-3.75, 0.3, -18), size: Vec3(0.5, 0.6, 8), stone)
    builder.block("Wall", center: Vec3(0, 0.3, -21.75), size: Vec3(8, 0.6, 0.5), stone)

    // A fence with holes along the landing: look at its shadow. What you see is a flat
    // plane, stood up and turned to face -x; what stops the marble is an invisible box
    // on an entity of its own, because a collider follows its entity's rotation.
    let fencePosition = Vec3(20.4, 3.5, -1)
    let fenceEntity = scene.create("Fence")
    let standUp = Quat(angle: radians(-90), axis: Vec3(0, 1, 0)) * Quat(angle: radians(90), axis: Vec3(1, 0, 0))
    scene.add(fenceEntity, Transform(position: fencePosition, rotation: standUp, scale: Vec3(7, 1, 2)))
    scene.add(fenceEntity, MeshRenderer(mesh: assets.plane, material: fence))
    let fenceWall = scene.create("Fence wall")
    scene.add(fenceWall, Transform(position: fencePosition))
    scene.add(fenceWall, Collider.box(halfExtents: Vec3(0.1, 1, 3.5)))

    // The moving platform carries the marble across the gap between terrace and landing.
    let ferryStart = Vec3(17, 2.25, -12.4), ferryEnd = Vec3(17, 2.25, -6.6)
    level.ferry = builder.block("Ferry", center: ferryStart, size: Vec3(3, 0.5, 3), paint)
    scene.add(level.ferry, RigidBody(type: .kinematic, friction: 1))       // it moves, but nothing can push it
    scene.add(level.ferry, MovingPlatform(from: ferryStart, to: ferryEnd, period: 9))

    // Crates: dynamic bodies the marble can push around.
    for i in 0..<3 {
        let crate = scene.create("Crate")
        var position = Vec3(-1.6 + 0.95 * Float(i % 2), 0.45 + 0.9 * Float(i / 2), -19.5)
        if i == 2 { position.x = -1.1 }
        scene.add(crate, Transform(position: position))
        scene.add(crate, MeshRenderer(mesh: builder.boxMesh(Vec3(0.9, 0.9, 0.9)), material: wood))
        scene.add(crate, Collider.box(halfExtents: Vec3(0.45, 0.45, 0.45)))
        scene.add(crate, RigidBody(mass: 0.4, friction: 0.5))
    }

    // ---- gems: a mesh from a file, a colored light, and a trigger to detect the marble.
    let gemPositions = [
        Vec3(0, 1.0, -7), Vec3(0, 1.0, -11), Vec3(2.2, 1.0, -16), Vec3(8.5, 2.6, -18),
        Vec3(17, 3.5, -20), Vec3(17, 4.6, -9.5), Vec3(17, 3.5, 4.5), Vec3(13, 3.5, 11.5),      // the sixth needs a jump from the ferry
    ]
    let gemColors = [Vec3(0.15, 0.8, 1.0), Vec3(1.0, 0.3, 0.6), Vec3(1.0, 0.8, 0.2), Vec3(0.4, 1.0, 0.5)]
    let gemMesh = assets.mesh("Models/gem.obj")
    let gemMaterials = gemColors.map { color -> Material in
        let material = assets.makeMaterial(baseColor: Vec4(color, 1), metallic: 0, roughness: 0.06)
        material.emissive = color * 0.9                 // a soft glow, picked up by the bloom
        return material
    }
    for position in gemPositions {
        let index = level.gemCount
        level.gemCount += 1
        let color = gemColors[index % 4]
        let gem = scene.create("Gem")
        scene.add(gem, Transform(position: position, scale: Vec3(0.9, 0.9, 0.9)))
        scene.add(gem, MeshRenderer(mesh: gemMesh, material: gemMaterials[index % 4]))
        scene.add(gem, Gem(home: position, phase: 0.9 * Float(index), color: color))
        scene.add(gem, Light(type: .point, color: color, intensity: 5, range: 5))
        var trigger = Collider.sphere(radius: 0.75)
        trigger.isTrigger = true
        scene.add(gem, trigger)
    }

    // ---- the goal: a glowing disc on the summit. It opens when every gem has been collected.
    level.goalMaterial = assets.makeMaterial(baseColor: Vec4(0.05, 0.05, 0.05, 1), metallic: 0, roughness: 0.3)
    level.goalMaterial.emissive = Vec3(1.2, 0.25, 0.1)
    level.goal = scene.create("Goal")
    scene.add(level.goal, Transform(position: Vec3(13, 2.56, 18.5), scale: Vec3(3, 0.12, 3)))
    scene.add(level.goal, MeshRenderer(mesh: assets.cylinder, material: level.goalMaterial))
    scene.add(level.goal, Light(type: .point, color: Vec3(1.0, 0.3, 0.15), intensity: 6, range: 7))
    var goalTrigger = Collider.box(halfExtents: Vec3(1.2, 1.2, 1.2))
    goalTrigger.offset = Vec3(0, 1, 0)
    goalTrigger.isTrigger = true
    scene.add(level.goal, goalTrigger)

    // ---- the marble
    let marbleMaterial = assets.makeMaterial(baseColor: Vec4(0.25, 0.55, 1.0, 1), metallic: 0, roughness: 0.18)
    marbleMaterial.baseColorTexture = assets.texture("Textures/checker_basecolor.png")      // so that rolling is visible
    level.start = Vec3(0, Level.marbleRadius + 0.05, 2)
    level.marble = scene.create("Marble")
    scene.add(level.marble, Transform(position: level.start))
    scene.add(level.marble, MeshRenderer(mesh: assets.sphere, material: marbleMaterial))
    scene.add(level.marble, Collider.sphere(radius: Level.marbleRadius))
    var marbleBody = RigidBody(restitution: 0.35, friction: 0.03)      // a rolling ball barely slows down by itself
    marbleBody.linearDamping = 0.15
    scene.add(level.marble, marbleBody)

    // ---- the camera. The game moves it every frame.
    level.camera = scene.create("Camera")
    scene.add(level.camera, Transform())
    scene.add(level.camera, Camera(farPlane: 300))

    return level
}
