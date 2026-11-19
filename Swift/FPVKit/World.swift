// World.swift
// The place to fly: a mowed field ringed by hills and trees, the gates of the course,
// an unfinished concrete building to thread, and the pilot's tent by the start.
// Everything is made in code from boxes, cylinders, cones and noise: no model files.

import Foundation
import LMEngine
import simd

private let fieldCenter = Vec2(-25, -18)
private let fieldHalf: Float = 78               // the mowed square is 156 meters on a side
private let terrainSize: Float = 620

/// How far outside the mowed square a point is: 0 on the field.
private func beyondField(_ x: Float, _ z: Float) -> Float {
    max(max(abs(x - fieldCenter.x), abs(z - fieldCenter.y)) - fieldHalf, 0)
}

/// The height of the ground under a point. The field is flat, at zero; hills rise around it.
public func groundHeight(_ x: Float, _ z: Float) -> Float {
    let outside = beyondField(x, z)
    if outside <= 0 { return 0 }
    // Gentle at first, then real hills: the field sits in a bowl.
    let hills = fractalNoise(Vec2(x, z) / 80, octaves: 4, seed: 11)
    return smoothstep(0, 110, outside) * (3 + hills * 38)
}

/// Which way the ground faces there.
public func groundNormal(_ x: Float, _ z: Float) -> Vec3 {
    let step: Float = 1
    let slopeX = (groundHeight(x + step, z) - groundHeight(x - step, z)) / (2 * step)
    let slopeZ = (groundHeight(x, z + step) - groundHeight(x, z - step)) / (2 * step)
    return simd_normalize(Vec3(-slopeX, 1, -slopeZ))
}

/// Noise that repeats exactly every `period` units, so that a texture made from it tiles
/// without seams: four copies shifted by one period, cross-faded.
private func tilingNoise(_ p: Vec2, period: Float, octaves: Int, seed: UInt32) -> Float {
    let tx = p.x / period, ty = p.y / period
    let a = fractalNoise(p, octaves: octaves, seed: seed), b = fractalNoise(p - Vec2(period, 0), octaves: octaves, seed: seed)
    let c = fractalNoise(p - Vec2(0, period), octaves: octaves, seed: seed)
    let d = fractalNoise(p - Vec2(period, period), octaves: octaves, seed: seed)
    return lerp(lerp(a, b, tx), lerp(c, d, tx), ty)
}

/// Grass, as a texture: greens that vary in patches and from blade to blade. A mowed
/// field also shows the two directions the mower went, as lighter and darker bands.
private func grassTexture(_ assets: Assets, mowed: Bool) -> Texture? {
    let size = 256
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    var random = Random(seed: mowed ? 3 : 4)
    for y in 0..<size {
        for x in 0..<size {
            let p = Vec2(Float(x), Float(y))
            let patches = tilingNoise(p / 40, period: Float(size) / 40, octaves: 3, seed: 21)
            let blades = tilingNoise(p / 3, period: Float(size) / 3, octaves: 2, seed: 22)
            var shade = 0.72 + 0.38 * patches + 0.22 * (blades - 0.5) + random.range(-0.05, 0.05)
            if mowed && y >= size / 2 { shade *= 0.86 }
            // Dry patches lean toward yellow, more so away from the mowed field.
            let dry = saturate((patches - 0.55) * (mowed ? 1.2 : 2.6))
            let color = lerp(Vec3(0.30, 0.46, 0.17), Vec3(0.52, 0.52, 0.24), dry) * shade
            let index = (y * size + x) * 4
            pixels[index] = UInt8(saturate(color.x) * 255)
            pixels[index + 1] = UInt8(saturate(color.y) * 255)
            pixels[index + 2] = UInt8(saturate(color.z) * 255)
        }
    }
    return assets.makeTexture(pixels: pixels, width: size, height: size)
}

public struct World {
    public var gateParts: [[Entity]] = []               // the bars that make up each gate
    public var gateMaterial = Material()
    public var nextGateMaterial = Material()
    public var pilot = Vec3(14, 1.6, 4)                 // the radio link is measured from the pilot's hands
    public var start = Vec3(0, 0, 0)                    // the launch mat
}

/// Makes boxes of any size that share one mesh per size and repeat their texture per meter.
private final class Builder {
    let engine: Engine
    private var meshes: [String: Mesh] = [:]

    init(_ engine: Engine) { self.engine = engine }

    @discardableResult
    func box(_ name: String, center: Vec3, size: Vec3, _ material: Material, rotation: Quat = .identity, solid: Bool = true) -> Entity {
        let key = "\(size.x) \(size.y) \(size.z)"
        let mesh: Mesh
        if let existing = meshes[key] {
            mesh = existing
        } else {
            mesh = engine.assets.makeMesh(MeshData.cube(size: size, uvPerUnit: 0.5))
            meshes[key] = mesh
        }
        let entity = engine.scene.create(name)
        engine.scene.add(entity, Transform(position: center, rotation: rotation))
        engine.scene.add(entity, MeshRenderer(mesh: mesh, material: material))
        if solid { engine.scene.add(entity, Collider.box(halfExtents: size * 0.5)) }
        return entity
    }

    @discardableResult
    func shape(_ name: String, _ mesh: Mesh, _ material: Material, position: Vec3, scale: Vec3, tint: Vec4 = Vec4(1, 1, 1, 1)) -> Entity {
        let entity = engine.scene.create(name)
        engine.scene.add(entity, Transform(position: position, scale: scale))
        var renderer = MeshRenderer(mesh: mesh, material: material)
        renderer.tint = tint
        engine.scene.add(entity, renderer)
        return entity
    }
}

/// A gate is a frame of bars around its opening: two posts and a bar on top, and a bar
/// below if the opening does not reach the ground.
private func buildGate(_ builder: Builder, _ gate: Gate, _ material: Material) -> [Entity] {
    let thickness: Float = 0.28
    let top = gate.center.y + gate.height * 0.5
    let bottom = gate.center.y - gate.height * 0.5
    var bars: [(center: Vec3, size: Vec3)] = []
    for side: Float in [-1, 1] {
        let x = side * (gate.width + thickness) * 0.5
        bars.append((Vec3(x, (top + thickness) * 0.5 - gate.center.y, 0), Vec3(thickness, top + thickness, thickness)))
    }
    bars.append((Vec3(0, gate.height * 0.5 + thickness * 0.5, 0), Vec3(gate.width, thickness, thickness)))
    if bottom > 0.6 {
        bars.append((Vec3(0, -gate.height * 0.5 - thickness * 0.5, 0), Vec3(gate.width, thickness, thickness)))
    }
    // The bars are given in the gate's own space: turn them to face along the course.
    return bars.map { bar in
        builder.box("Gate", center: gate.center + gate.rotation.act(bar.center), size: bar.size, material, rotation: gate.rotation)
    }
}

public func buildWorld(_ engine: Engine) -> World {
    let scene = engine.scene
    let assets = engine.assets
    var world = World()
    let builder = Builder(engine)

    // ---- light: a sun in the afternoon
    let sun = scene.create("Sun")
    scene.add(sun, Transform(rotation: .lookRotation(forward: Vec3(0.45, -0.62, -0.42))))
    scene.add(sun, Light(type: .directional, color: Vec3(1.0, 0.94, 0.84), intensity: 3.6, castsShadows: true))

    // ---- the ground. The mowed field is one flat square; the land around it is a grid
    // whose height comes from groundHeight(). Under the field the grid dips a little,
    // so that the two never fight over the same pixels.
    let fieldGrass = assets.makeMaterial(baseColor: Vec4(1, 1, 1, 1), metallic: 0, roughness: 0.95)
    fieldGrass.baseColorTexture = grassTexture(assets, mowed: true)
    let fieldSide = fieldHalf * 2 + 2
    fieldGrass.uvScale = Vec2(fieldSide / 12, fieldSide / 12)                   // a 12 m tile: two 6 m mowing bands
    builder.shape("Field", assets.plane, fieldGrass, position: Vec3(fieldCenter.x, 0, fieldCenter.y), scale: Vec3(fieldSide, 1, fieldSide))

    let wildGrass = assets.makeMaterial(baseColor: Vec4(1, 1, 1, 1), metallic: 0, roughness: 0.97)
    wildGrass.baseColorTexture = grassTexture(assets, mowed: false)
    let land = MeshData.heightfield(width: terrainSize, depth: terrainSize, columns: 124, rows: 124, uvScale: terrainSize / 9) { x, z in
        let worldX = x + fieldCenter.x, worldZ = z + fieldCenter.y
        return groundHeight(worldX, worldZ) - 0.35 * (1 - smoothstep(0, 5, beyondField(worldX, worldZ)))
    }
    builder.shape("Land", assets.makeMesh(land), wildGrass, position: Vec3(fieldCenter.x, 0, fieldCenter.y), scale: Vec3(1, 1, 1))

    // ---- gates: bands of checkered fabric. The next one to fly through glows green.
    world.gateMaterial = assets.makeMaterial(baseColor: Vec4(1.0, 0.38, 0.06, 1), metallic: 0, roughness: 0.75)
    world.gateMaterial.baseColorTexture = assets.texture("Textures/checker_basecolor.png")
    world.gateMaterial.emissive = Vec3(0.20, 0.06, 0.01)
    world.nextGateMaterial = assets.makeMaterial(baseColor: Vec4(0.05, 0.5, 0.15, 1), metallic: 0, roughness: 0.6)
    world.nextGateMaterial.emissive = Vec3(0.08, 1.1, 0.25)
    world.gateParts = courseGates.map { gate in buildGate(builder, gate, world.gateMaterial) }

    // ---- flags beside every other gate: a pole and a tall strip of cloth
    let pole = assets.makeMaterial(baseColor: Vec4(0.8, 0.8, 0.82, 1), metallic: 1, roughness: 0.4)
    let cloths = [Vec4(0.1, 0.3, 0.9, 1), Vec4(0.95, 0.95, 0.95, 1), Vec4(0.9, 0.12, 0.1, 1), Vec4(0.98, 0.8, 0.1, 1)]
    let cloth = assets.makeMaterial(baseColor: Vec4(1, 1, 1, 1), metallic: 0, roughness: 0.8)
    cloth.isDoubleSided = true
    var flagCount = 0
    for index in stride(from: 0, to: courseGates.count, by: 2) {
        let gate = courseGates[index]
        for side: Float in [-1, 1] {
            var foot = gate.center + gate.right * (side * (gate.width * 0.5 + 2.2))
            foot.y = 0
            builder.shape("Flag pole", assets.cylinder, pole, position: foot + Vec3(0, 2.3, 0), scale: Vec3(0.05, 4.6, 0.05))
            let flag = builder.box("Flag", center: foot + Vec3(0, 3.1, 0) + gate.right * 0.36, size: Vec3(0.66, 2.6, 0.02), cloth,
                                   rotation: gate.rotation, solid: false)
            scene[flag, MeshRenderer.self]?.tint = cloths[flagCount % 4]
            flagCount += 1
        }
    }

    // ---- the start: a rubber mat, and the pilot's tent beside it
    let rubber = assets.makeMaterial(baseColor: Vec4(0.05, 0.05, 0.055, 1), metallic: 0, roughness: 0.9)
    builder.box("Launch mat", center: world.start + Vec3(0, 0.01, 0), size: Vec3(1.4, 0.02, 1.4), rubber, solid: false)
    let canvasWhite = assets.makeMaterial(baseColor: Vec4(0.92, 0.92, 0.9, 1), metallic: 0, roughness: 0.7)
    let tent = Vec3(world.pilot.x + 1, 0, world.pilot.z)
    builder.box("Tent roof", center: tent + Vec3(0, 2.35, 0), size: Vec3(3.2, 0.08, 3.2), canvasWhite)
    for x: Float in [-1.5, 1.5] {
        for z: Float in [-1.5, 1.5] {
            builder.shape("Tent leg", assets.cylinder, pole, position: tent + Vec3(x, 1.15, z), scale: Vec3(0.05, 2.3, 0.05))
        }
    }
    let wood = assets.makeMaterial(baseColor: Vec4(0.62, 0.45, 0.28, 1), metallic: 0, roughness: 0.7)
    builder.box("Table", center: tent + Vec3(0.4, 0.74, -0.6), size: Vec3(1.6, 0.05, 0.7), wood)

    // ---- the unfinished building: columns and slabs, open on every side
    let concrete = Material()
    concrete.baseColor = Vec4(0.8, 0.8, 0.8, 1)
    concrete.metallic = 1                           // factors of 1 let the texture maps decide
    concrete.roughness = 1
    concrete.baseColorTexture = assets.texture("Textures/tiles_basecolor.png")
    concrete.normalTexture = assets.texture("Textures/tiles_normal.png", format: .rgba8)
    concrete.metallicRoughnessTexture = assets.texture("Textures/tiles_orm.png", format: .rgba8)
    let corner = Vec3(22, 0, -74)
    let bay: Float = 5, storey: Float = 3.4
    for floor in 0..<2 {
        let base = Float(floor) * storey
        for i in 0..<4 {
            for j in 0..<3 {
                builder.box("Column", center: corner + Vec3(Float(i) * bay, base + storey * 0.5 - 0.125, Float(j) * bay),
                            size: Vec3(0.4, storey - 0.25, 0.4), concrete)
            }
        }
        // The slab above this storey. The upper one has a bay missing: a way out through the roof.
        if floor == 0 {
            builder.box("Slab", center: corner + Vec3(bay * 1.5, base + storey - 0.125, bay), size: Vec3(bay * 3 + 0.6, 0.25, bay * 2 + 0.6), concrete)
        } else {
            builder.box("Slab", center: corner + Vec3(bay * 1.0, base + storey - 0.125, bay), size: Vec3(bay * 2 + 0.6, 0.25, bay * 2 + 0.6), concrete)
            builder.box("Slab", center: corner + Vec3(bay * 2.5, base + storey - 0.125, bay * 0.5), size: Vec3(bay + 0.6, 0.25, bay + 0.6), concrete)
        }
    }
    // Two walls with a window each, to dive through.
    for z: Float in [0, bay * 2] {
        builder.box("Wall", center: corner + Vec3(bay * 0.5, 0.55, z), size: Vec3(bay - 0.4, 1.1, 0.2), concrete)
        builder.box("Wall", center: corner + Vec3(bay * 0.5, storey - 0.65, z), size: Vec3(bay - 0.4, 0.8, 0.2), concrete)
    }

    // ---- trees: a ring of them around the field and on the hills, and a few on the
    // field itself to fly around. A fixed seed puts them in the same places every time.
    let bark = assets.makeMaterial(baseColor: Vec4(0.26, 0.18, 0.11, 1), metallic: 0, roughness: 0.9)
    let needles = assets.makeMaterial(baseColor: Vec4(0.10, 0.26, 0.12, 1), metallic: 0, roughness: 0.85)
    let leaves = assets.makeMaterial(baseColor: Vec4(0.20, 0.36, 0.12, 1), metallic: 0, roughness: 0.85)
    let cone = assets.makeMesh(MeshData.cone(radius: 0.5, height: 1, segments: 14))
    var random = Random(seed: 7)
    func plant(_ foot: Vec3) {
        let height = random.range(7, 14)
        let tint = Vec4(random.range(0.8, 1.15), random.range(0.85, 1.1), random.range(0.8, 1.05), 1)
        if random.next() < 0.6 {
            // A conifer: three cones, each smaller and higher than the one below.
            let trunk = builder.shape("Tree", assets.cylinder, bark, position: foot + Vec3(0, height * 0.12, 0),
                                      scale: Vec3(height * 0.045, height * 0.24, height * 0.045))
            scene.add(trunk, Collider.capsule(radius: height * 0.03, halfHeight: height * 0.1))
            for tier in 0..<3 {
                let width = height * (0.42 - 0.09 * Float(tier)), tall = height * 0.42
                let part = builder.shape("Tree", cone, needles, position: foot + Vec3(0, height * (0.18 + 0.24 * Float(tier)) + tall * 0.5, 0),
                                         scale: Vec3(width, tall, width), tint: tint)
                var collider = Collider.sphere(radius: width * 0.33)
                collider.offset = Vec3(0, -tall * 0.2, 0)           // a cone is widest near its base
                scene.add(part, collider)
            }
        } else {
            // A broadleaf: a trunk and a round crown.
            let trunk = builder.shape("Tree", assets.cylinder, bark, position: foot + Vec3(0, height * 0.22, 0),
                                      scale: Vec3(height * 0.05, height * 0.44, height * 0.05))
            scene.add(trunk, Collider.capsule(radius: height * 0.03, halfHeight: height * 0.2))
            let crown = height * 0.62
            let top = builder.shape("Tree", assets.sphere, leaves, position: foot + Vec3(0, height * 0.68, 0),
                                    scale: Vec3(crown, crown * 0.85, crown), tint: tint)
            scene.add(top, Collider.sphere(radius: crown * 0.42))
        }
    }
    var planted = 0
    while planted < 120 {
        var spot = Vec3(fieldCenter.x + random.range(-250, 250), 0, fieldCenter.y + random.range(-250, 250))
        let outside = beyondField(spot.x, spot.z)
        if outside < 4 || outside > 170 { continue }
        if outside > 60 && random.next() < 0.5 { continue }         // thinner far away
        spot.y = groundHeight(spot.x, spot.z) - 0.2
        plant(spot)
        planted += 1
    }
    planted = 0
    while planted < 7 {
        let spot = Vec3(fieldCenter.x + random.range(-70, 70), -0.1, fieldCenter.y + random.range(-70, 70))
        // Keep the racing line, the start and the building clear.
        if distanceToCourse(Vec2(spot.x, spot.z)) < 11 || simd_length(Vec2(spot.x, spot.z)) < 22 { continue }
        if spot.x > corner.x - 8 && spot.z < corner.z + bay * 2 + 8 { continue }
        plant(spot)
        planted += 1
    }
    return world
}

// MARK: - The drone, to look at

/// The drone as something to look at: frame, motors, battery, camera, spinning propellers.
/// It is rebuilt when the pilot chooses another airframe.
public struct DroneModel {
    public var root = Entity.invalid
    var parts: [Entity] = []
    var blades: [Entity] = []
    var discs: [Entity] = []
    var bladeAngle: [Float] = [0, 0, 0, 0]

    public init() {}

    public static func build(_ engine: Engine, _ a: Airframe) -> DroneModel {
        let scene = engine.scene
        let assets = engine.assets
        var model = DroneModel()
        model.root = scene.create("Drone")
        scene.add(model.root, Transform())
        let root = model.root
        var parts: [Entity] = []

        func part(_ name: String, _ mesh: Mesh, _ material: Material, _ position: Vec3, _ scale: Vec3, rotation: Quat = .identity) -> Entity {
            let entity = scene.create(name)
            var transform = Transform(position: position, rotation: rotation, scale: scale)
            transform.parent = root
            scene.add(entity, transform)
            scene.add(entity, MeshRenderer(mesh: mesh, material: material))
            parts.append(entity)
            return entity
        }

        let s = a.armX / 0.0795                         // everything is sized from the 5-inch frame
        let carbon = assets.makeMaterial(baseColor: Vec4(0.03, 0.03, 0.035, 1), metallic: 0, roughness: 0.38)
        let metal = assets.makeMaterial(baseColor: Vec4(0.75, 0.76, 0.8, 1), metallic: 1, roughness: 0.35)
        let pack = assets.makeMaterial(baseColor: Vec4(0.08, 0.08, 0.09, 1), metallic: 0, roughness: 0.5)
        let bladeMaterial = assets.makeMaterial(baseColor: Vec4(1.0, 0.42, 0.1, 1), metallic: 0, roughness: 0.5)
        let discMaterial = assets.makeMaterial(baseColor: Vec4(1.0, 0.5, 0.2, 0.16), metallic: 0, roughness: 0.6)
        discMaterial.alphaMode = .blend

        // Frame: a body plate, a top plate, and two arms that cross.
        _ = part("Frame", assets.cube, carbon, Vec3(0, 0, 0), Vec3(0.05 * s, 0.006, 0.17 * s))
        _ = part("Frame", assets.cube, carbon, Vec3(0, 0.03 * s, 0), Vec3(0.042 * s, 0.004, 0.13 * s))
        let armLength = 2 * (a.armX * a.armX + a.armZ * a.armZ).squareRoot() + 0.02 * s
        let armAngle = atan2(a.armX, a.armZ)
        for side: Float in [-1, 1] {
            _ = part("Arm", assets.cube, carbon, Vec3(0, -0.003, 0), Vec3(0.02 * s, 0.006, armLength),
                     rotation: Quat(angle: side * armAngle, axis: Vec3(0, 1, 0)))
        }
        _ = part("Battery", assets.cube, pack, Vec3(0, 0.05 * s, 0.005 * s), Vec3(0.038 * s, 0.034 * s, 0.078 * s))
        // The camera looks up by the same angle as the view from it.
        _ = part("Camera", assets.cube, pack, Vec3(0, 0.017 * s, -0.082 * s), Vec3(0.02 * s, 0.02 * s, 0.02 * s),
                 rotation: Quat(angle: radians(a.cameraTilt), axis: Vec3(1, 0, 0)))

        for i in 0..<4 {
            let at = Vec3((i % 2 == 0 ? 1 : -1) * a.armX, 0, (i < 2 ? -1 : 1) * a.armZ)
            _ = part("Motor", assets.cylinder, metal, at + Vec3(0, 0.012 * s, 0), Vec3(0.028 * s, 0.022 * s, 0.028 * s))
            let span = a.propRadius * 2
            model.blades.append(part("Propeller", assets.cube, bladeMaterial, at + Vec3(0, 0.027 * s, 0), Vec3(span, 0.002, 0.014 * s)))
            let disc = part("Propeller disc", assets.cylinder, discMaterial, at + Vec3(0, 0.027 * s, 0), Vec3(span, 0.001, span))
            scene[disc, MeshRenderer.self]?.castsShadows = false
            model.discs.append(disc)
            // A whoop's propellers turn inside rings that let it bounce off things.
            if s < 0.7 {
                let duct = assets.makeMaterial(baseColor: Vec4(0.9, 0.9, 0.92, 0.35), metallic: 0, roughness: 0.5)
                duct.alphaMode = .blend
                let ring = part("Duct", assets.cylinder, duct, at + Vec3(0, 0.02 * s, 0), Vec3(span + 0.008, 0.016, span + 0.008))
                scene[ring, MeshRenderer.self]?.castsShadows = false
            }
        }
        model.parts = parts
        return model
    }

    /// Moves the model to where the drone is and turns the propellers.
    public mutating func update(_ engine: Engine, _ drone: Drone, dt: Float) {
        let scene = engine.scene
        guard var transform = scene[root, Transform.self] else { return }
        transform.position = drone.position
        transform.rotation = drone.rotation
        scene[root, Transform.self] = transform
        for i in 0..<min(4, blades.count) {
            // At speed a propeller is a blur: show the disc. Slow, show the blades turning.
            // (They turn far slower on screen than in reality, or they would only flicker.)
            let isBlurred = drone.motors[i] > 0.14
            let direction: Float = (i == 0 || i == 3) ? 1 : -1
            if drone.motors[i] > 0.005 { bladeAngle[i] += direction * (4 + drone.motors[i] * 60) * dt }
            scene[blades[i], Transform.self]?.rotation = Quat(angle: bladeAngle[i], axis: Vec3(0, 1, 0))
            scene[blades[i], MeshRenderer.self]?.isVisible = !isBlurred
            scene[discs[i], MeshRenderer.self]?.isVisible = isBlurred
        }
    }

    public mutating func destroy(_ engine: Engine) {
        for entity in parts { engine.scene.destroy(entity) }
        engine.scene.destroy(root)
        parts.removeAll()
        blades.removeAll()
        discs.removeAll()
        root = .invalid
    }
}
