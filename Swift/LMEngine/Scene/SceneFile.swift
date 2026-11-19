// SceneFile.swift
// Scenes as text files: what an editor saves and a game loads.
//
// The format is one statement per line, made to be read by people and compared by git:
//
//     learnmetal-scene 1
//     material "Stone"
//       baseColor 1 1 1 1
//       roughness 0.8
//       baseColorTexture "Textures/tiles_basecolor.png"
//     entity "Crate"
//       transform 0 2 0  0 0 0 1  1 1 1        position, rotation (a quaternion), scale
//       mesh "cube" 0                          mesh name, index of its material in this file
//       collider box 0.5 0.5 0.5  0 0 0  0
//       body dynamic 1 0.1 0.6 0.05 1
//
// Meshes and textures are stored by name; the file never contains their data. Lines a
// reader does not know are skipped, so files from a newer version still load.

import Foundation
import simd

/// A material with the name it has in the editor and in scene files.
public struct NamedMaterial {
    public var name: String
    public var material: Material

    public init(name: String, material: Material) {
        self.name = name
        self.material = material
    }
}

/// Marks an entity that belongs to a tool and not to the scene (an editor's own camera):
/// it is never written to a file.
public struct EditorOnly {
    public init() {}
}

/// How the names in a file become assets. Usually both lead to Assets (see
/// Assets.sceneAssets); either may be nil, and then meshes or textures are simply left out.
public struct SceneAssets {
    public var mesh: ((String) -> Mesh?)?
    public var texture: ((String, TextureFormat) -> Texture?)?

    public init(mesh: ((String) -> Mesh?)? = nil, texture: ((String, TextureFormat) -> Texture?)? = nil) {
        self.mesh = mesh
        self.texture = texture
    }
}

// MARK: - Writing

/// Builds one line: a keyword followed by values separated by spaces.
private struct Line {
    var text: String

    init(_ keyword: String, indent: Int = 1) {
        text = String(repeating: "  ", count: indent) + keyword
    }

    func number(_ value: Float) -> Line {
        // Swift prints the shortest text that reads back as exactly the same float: 0.05,
        // not 0.0500000007. Whole numbers come out as "2.0"; the file says "2".
        var written = "\(value)"
        if written.hasSuffix(".0") { written.removeLast(2) }
        return Line(text + " " + written, indent: 0)
    }
    func integer(_ value: Int) -> Line { Line(text + " \(value)", indent: 0) }
    func flag(_ value: Bool) -> Line { integer(value ? 1 : 0) }
    func vec(_ v: Vec2) -> Line { number(v.x).number(v.y) }
    func vec(_ v: Vec3) -> Line { number(v.x).number(v.y).number(v.z) }
    func vec(_ v: Vec4) -> Line { number(v.x).number(v.y).number(v.z).number(v.w) }
    func word(_ value: String) -> Line { Line(text + " " + value, indent: 0) }
    /// A string in quotes, so that it may contain spaces.
    func string(_ value: String) -> Line {
        var quoted = " \""
        for character in value where character != "\n" && character != "\r" {
            if character == "\"" || character == "\\" { quoted.append("\\") }
            quoted.append(character)
        }
        return Line(text + quoted + "\"", indent: 0)
    }
    func to(_ out: inout String) { out += text + "\n" }
}

private let lightTypes = ["directional", "point", "spot"]
private let bodyTypes = ["static", "kinematic", "dynamic"]
private let shapes = ["sphere", "box", "capsule"]
private let alphaModes = ["opaque", "mask", "blend"]

private func position(of type: LightType) -> Int { type == .directional ? 0 : type == .point ? 1 : 2 }
private func position(of type: BodyType) -> Int { type == .static ? 0 : type == .kinematic ? 1 : 2 }
private func position(of shape: ColliderShape) -> Int { shape == .sphere ? 0 : shape == .box ? 1 : 2 }
private func position(of mode: AlphaMode) -> Int { mode == .opaque ? 0 : mode == .mask ? 1 : 2 }

private func writeTexture(_ out: inout String, _ keyword: String, _ texture: Texture?) {
    if let texture = texture, !texture.name.isEmpty { Line(keyword).string(texture.name).to(&out) }
}

/// The whole scene as text. Materials that are used by an entity but missing from
/// `materials` are written too, under a made-up name.
public func writeScene(_ scene: Scene, materials: [NamedMaterial], settings: RenderSettings) -> String {
    var out = "learnmetal-scene 1\n"

    // ---- settings: the look of the scene
    out += "settings\n"
    Line("skyZenith").vec(settings.sky.zenithColor).to(&out)
    Line("skyHorizon").vec(settings.sky.horizonColor).to(&out)
    Line("skyGround").vec(settings.sky.groundColor).to(&out)
    Line("skyIntensity").number(settings.sky.intensity).to(&out)
    Line("environmentIntensity").number(settings.environmentIntensity).to(&out)
    Line("fog").vec(settings.fogColor).number(settings.fogDensity).to(&out)
    Line("shadows").flag(settings.shadowsEnabled).number(settings.cascades.shadowDistance).to(&out)
    Line("ambientOcclusion").flag(settings.ambientOcclusionEnabled).number(settings.ambientOcclusionRadius)
        .number(settings.ambientOcclusionIntensity).to(&out)
    Line("bloom").flag(settings.bloomEnabled).number(settings.bloomIntensity).number(settings.bloomThreshold).to(&out)
    Line("exposure").number(settings.exposure).to(&out)
    Line("toneMapper").integer(settings.toneMapper).to(&out)
    Line("vignette").number(settings.vignette).to(&out)

    // ---- materials: the named ones, then any other that an entity uses
    var all = materials
    var materialIndex: [ObjectIdentifier: Int] = [:]
    for (i, named) in all.enumerated() { materialIndex[ObjectIdentifier(named.material)] = i }
    scene.each(MeshRenderer.self, Transform.self) { entity, renderer, _ in
        guard let material = renderer.material, !scene.has(EditorOnly.self, entity),
              materialIndex[ObjectIdentifier(material)] == nil else { return }
        materialIndex[ObjectIdentifier(material)] = all.count
        all.append(NamedMaterial(name: "Material \(all.count + 1)", material: material))
    }
    for named in all {
        let m = named.material
        Line("material", indent: 0).string(named.name).to(&out)
        Line("baseColor").vec(m.baseColor).to(&out)
        Line("metallic").number(m.metallic).to(&out)
        Line("roughness").number(m.roughness).to(&out)
        Line("emissive").vec(m.emissive).to(&out)
        Line("normalScale").number(m.normalScale).to(&out)
        Line("occlusionStrength").number(m.occlusionStrength).to(&out)
        Line("alpha").word(alphaModes[position(of: m.alphaMode)]).number(m.alphaCutoff).to(&out)
        Line("uvScale").vec(m.uvScale).to(&out)
        Line("doubleSided").flag(m.isDoubleSided).to(&out)
        Line("unlit").flag(m.isUnlit).to(&out)
        writeTexture(&out, "baseColorTexture", m.baseColorTexture)
        writeTexture(&out, "normalTexture", m.normalTexture)
        writeTexture(&out, "metallicRoughnessTexture", m.metallicRoughnessTexture)
        writeTexture(&out, "occlusionTexture", m.occlusionTexture)
        writeTexture(&out, "emissiveTexture", m.emissiveTexture)
    }

    // ---- entities, in the order the scene stores their transforms. A parent is written
    // as its position in this list.
    var entities: [Entity] = []
    var fileIndex: [UInt32: Int] = [:]
    scene.each(Transform.self) { entity, _ in
        if scene.has(EditorOnly.self, entity) { return }
        fileIndex[entity.index] = entities.count
        entities.append(entity)
    }
    for entity in entities {
        guard let t = scene[entity, Transform.self] else { continue }
        Line("entity", indent: 0).string(scene[entity, Name.self]?.value ?? "").to(&out)
        Line("transform").vec(t.position).vec(t.rotation.vector).vec(t.scale).to(&out)
        if scene.isAlive(t.parent), let parent = fileIndex[t.parent.index] { Line("parent").integer(parent).to(&out) }

        if let c = scene[entity, Camera.self] {
            Line("camera").number(c.fovY).number(c.nearPlane).number(c.farPlane).flag(c.isOrthographic)
                .number(c.orthographicHeight).flag(c.isActive).to(&out)
        }
        if let l = scene[entity, Light.self] {
            Line("light").word(lightTypes[position(of: l.type)]).vec(l.color).number(l.intensity).number(l.range)
                .number(l.innerConeAngle).number(l.outerConeAngle).flag(l.castsShadows).to(&out)
        }
        if let r = scene[entity, MeshRenderer.self] {
            let material = r.material.flatMap { materialIndex[ObjectIdentifier($0)] } ?? -1
            Line("mesh").string(r.mesh?.name ?? "").integer(material).vec(r.tint).flag(r.castsShadows).flag(r.isVisible).to(&out)
        }
        if let c = scene[entity, Collider.self] {
            var line = Line("collider").word(shapes[position(of: c.shape)])
            switch c.shape {
            case .box: line = line.vec(c.halfExtents)
            case .sphere: line = line.number(c.radius)
            case .capsule: line = line.number(c.radius).number(c.halfHeight)
            }
            line.vec(c.offset).flag(c.isTrigger).to(&out)
        }
        if let b = scene[entity, RigidBody.self] {
            Line("body").word(bodyTypes[position(of: b.type)]).number(b.mass).number(b.restitution).number(b.friction)
                .number(b.linearDamping).number(b.gravityScale).to(&out)
        }
        if let e = scene[entity, ParticleEmitter.self] {
            Line("particles").number(e.rate).number(e.lifetimeMin).number(e.lifetimeMax).number(e.speedMin).number(e.speedMax)
                .vec(e.direction).number(e.spread).number(e.spawnRadius).vec(e.gravity).number(e.drag).to(&out)
            Line("particleLook").number(e.sizeStart).number(e.sizeEnd).vec(e.colorStart).vec(e.colorEnd)
                .flag(e.isAdditive).flag(e.isEmitting).integer(e.maxParticles).to(&out)
        }
    }
    return out
}

// MARK: - Reading

/// One line split into words. Quoted strings count as one word.
private struct Words {
    var items: [String] = []
    var next = 1                        // items[0] is the keyword

    init(_ line: Substring) {
        var word = ""
        var isInside = false, isQuoted = false, isEscaped = false
        for character in line {
            if isQuoted {
                if isEscaped {
                    word.append(character)
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    items.append(word)
                    word = ""
                    isQuoted = false
                } else {
                    word.append(character)
                }
            } else if character == " " || character == "\t" || character == "\r" {
                if isInside { items.append(word) }
                word = ""
                isInside = false
            } else if character == "\"" && !isInside {
                isQuoted = true
            } else {
                word.append(character)
                isInside = true
            }
        }
        if isInside || isQuoted { items.append(word) }
    }

    var keyword: String { items.first ?? "" }
    var hasMore: Bool { next < items.count }

    mutating func string() -> String {
        guard hasMore else { return "" }
        next += 1
        return items[next - 1]
    }
    mutating func number(_ fallback: Float = 0) -> Float {
        guard hasMore else { return fallback }
        next += 1
        return Float(items[next - 1]) ?? fallback
    }
    mutating func integer(_ fallback: Int = 0) -> Int {
        guard hasMore else { return fallback }
        next += 1
        return Int(items[next - 1]) ?? fallback
    }
    mutating func flag(_ fallback: Bool = false) -> Bool { integer(fallback ? 1 : 0) != 0 }
    mutating func vec2(_ d: Vec2 = Vec2(0, 0)) -> Vec2 {
        let x = number(d.x), y = number(d.y)
        return Vec2(x, y)
    }
    mutating func vec3(_ d: Vec3 = Vec3(0, 0, 0)) -> Vec3 {
        let x = number(d.x), y = number(d.y), z = number(d.z)
        return Vec3(x, y, z)
    }
    mutating func vec4(_ d: Vec4 = Vec4(0, 0, 0, 0)) -> Vec4 {
        let x = number(d.x), y = number(d.y), z = number(d.z), w = number(d.w)
        return Vec4(x, y, z, w)
    }
    /// The position of the next word in a list of names, or `fallback`.
    mutating func choice(_ names: [String], _ fallback: Int) -> Int {
        names.firstIndex(of: string()) ?? fallback
    }
}

private enum Block {
    case none, settings, material, entity
}

/// Adds what the text describes to `scene` (clear it first to replace it) and replaces
/// `materials`. Returns false, and logs why, if the text is not a scene file at all.
@discardableResult
public func readScene(_ text: String, into scene: Scene, materials: inout [NamedMaterial], settings: inout RenderSettings,
                      assets: SceneAssets) -> Bool {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
    guard let first = lines.popFirst(), Words(first).keyword == "learnmetal-scene" else {
        logError("not a scene file: the first line must be \"learnmetal-scene 1\"")
        return false
    }

    var block = Block.none
    materials.removeAll()
    var entities: [Entity] = []
    var parents: [(Entity, Int)] = []       // resolved at the end: a parent may come later in the file
    var entity = Entity.invalid
    var material: Material?

    func loadTexture(_ words: inout Words, _ format: TextureFormat) -> Texture? {
        let name = words.string()
        return name.isEmpty ? nil : assets.texture?(name, format)
    }

    for line in lines {
        var words = Words(line)
        let key = words.keyword
        if key.isEmpty || key.hasPrefix("#") { continue }

        // ---- the lines that start a block
        if key == "settings" {
            block = .settings
        } else if key == "material" {
            block = .material
            let created = Material()
            materials.append(NamedMaterial(name: words.string(), material: created))
            material = created
        } else if key == "entity" {
            block = .entity
            entity = scene.create(words.string())
            scene.add(entity, Transform())
            entities.append(entity)

        // ---- settings
        } else if block == .settings {
            switch key {
            case "skyZenith": settings.sky.zenithColor = words.vec3()
            case "skyHorizon": settings.sky.horizonColor = words.vec3()
            case "skyGround": settings.sky.groundColor = words.vec3()
            case "skyIntensity": settings.sky.intensity = words.number(1)
            case "environmentIntensity": settings.environmentIntensity = words.number(1)
            case "fog":
                settings.fogColor = words.vec3()
                settings.fogDensity = words.number()
            case "shadows":
                settings.shadowsEnabled = words.flag(true)
                settings.cascades.shadowDistance = words.number(60)
            case "ambientOcclusion":
                settings.ambientOcclusionEnabled = words.flag(true)
                settings.ambientOcclusionRadius = words.number(0.6)
                settings.ambientOcclusionIntensity = words.number(1)
            case "bloom":
                settings.bloomEnabled = words.flag(true)
                settings.bloomIntensity = words.number(0.06)
                settings.bloomThreshold = words.number(1)
            case "exposure": settings.exposure = words.number(1)
            case "toneMapper": settings.toneMapper = words.integer()
            case "vignette": settings.vignette = words.number()
            default: break
            }

        // ---- a material
        } else if block == .material, let material = material {
            switch key {
            case "baseColor": material.baseColor = words.vec4(Vec4(1, 1, 1, 1))
            case "metallic": material.metallic = words.number()
            case "roughness": material.roughness = words.number(0.6)
            case "emissive": material.emissive = words.vec3()
            case "normalScale": material.normalScale = words.number(1)
            case "occlusionStrength": material.occlusionStrength = words.number(1)
            case "alpha":
                material.alphaMode = [AlphaMode.opaque, .mask, .blend][words.choice(alphaModes, 0)]
                material.alphaCutoff = words.number(0.5)
            case "uvScale": material.uvScale = words.vec2(Vec2(1, 1))
            case "doubleSided": material.isDoubleSided = words.flag()
            case "unlit": material.isUnlit = words.flag()
            // Colors are stored sRGB-encoded; everything else is data and must not be converted.
            case "baseColorTexture": material.baseColorTexture = loadTexture(&words, .rgba8sRGB)
            case "emissiveTexture": material.emissiveTexture = loadTexture(&words, .rgba8sRGB)
            case "normalTexture": material.normalTexture = loadTexture(&words, .rgba8)
            case "metallicRoughnessTexture": material.metallicRoughnessTexture = loadTexture(&words, .rgba8)
            case "occlusionTexture": material.occlusionTexture = loadTexture(&words, .rgba8)
            default: break
            }

        // ---- an entity's components
        } else if block == .entity {
            switch key {
            case "transform":
                var t = Transform()
                t.position = words.vec3()
                let q = words.vec4(Vec4(0, 0, 0, 1))
                // A hand-edited rotation may not have length 1; one we wrote does, and must
                // come back bit for bit.
                let lengthSquared = simd_dot(q, q)
                t.rotation = abs(lengthSquared - 1) < 1e-4 ? Quat(vector: q)
                    : lengthSquared > 1e-8 ? simd_normalize(Quat(vector: q)) : .identity
                t.scale = words.vec3(Vec3(1, 1, 1))
                scene[entity, Transform.self] = t
            case "parent":
                parents.append((entity, words.integer(-1)))
            case "camera":
                var c = Camera()
                c.fovY = words.number(c.fovY)
                c.nearPlane = words.number(c.nearPlane)
                c.farPlane = words.number(c.farPlane)
                c.isOrthographic = words.flag()
                c.orthographicHeight = words.number(c.orthographicHeight)
                c.isActive = words.flag(true)
                scene.add(entity, c)
            case "light":
                var l = Light()
                l.type = [LightType.directional, .point, .spot][words.choice(lightTypes, 1)]
                l.color = words.vec3(Vec3(1, 1, 1))
                l.intensity = words.number(1)
                l.range = words.number(l.range)
                l.innerConeAngle = words.number(l.innerConeAngle)
                l.outerConeAngle = words.number(l.outerConeAngle)
                l.castsShadows = words.flag()
                scene.add(entity, l)
            case "mesh":
                let name = words.string()
                let index = words.integer(-1)
                var r = MeshRenderer(mesh: name.isEmpty ? nil : assets.mesh?(name),
                                     material: index >= 0 && index < materials.count ? materials[index].material : nil)
                r.tint = words.vec4(Vec4(1, 1, 1, 1))
                r.castsShadows = words.flag(true)
                r.isVisible = words.flag(true)
                scene.add(entity, r)
            case "collider":
                var c = Collider()
                c.shape = [ColliderShape.sphere, .box, .capsule][words.choice(shapes, 1)]
                switch c.shape {
                case .box:
                    c.halfExtents = words.vec3(c.halfExtents)
                case .sphere:
                    c.radius = words.number(c.radius)
                case .capsule:
                    c.radius = words.number(c.radius)
                    c.halfHeight = words.number(c.halfHeight)
                }
                c.offset = words.vec3()
                c.isTrigger = words.flag()
                scene.add(entity, c)
            case "body":
                var b = RigidBody()
                b.type = [BodyType.static, .kinematic, .dynamic][words.choice(bodyTypes, 2)]
                b.mass = words.number(b.mass)
                b.restitution = words.number(b.restitution)
                b.friction = words.number(b.friction)
                b.linearDamping = words.number(b.linearDamping)
                b.gravityScale = words.number(b.gravityScale)
                scene.add(entity, b)
            case "particles":
                var e = ParticleEmitter()
                e.rate = words.number(e.rate)
                e.lifetimeMin = words.number(e.lifetimeMin)
                e.lifetimeMax = words.number(e.lifetimeMax)
                e.speedMin = words.number(e.speedMin)
                e.speedMax = words.number(e.speedMax)
                e.direction = words.vec3(e.direction)
                e.spread = words.number(e.spread)
                e.spawnRadius = words.number(e.spawnRadius)
                e.gravity = words.vec3(e.gravity)
                e.drag = words.number(e.drag)
                scene.add(entity, e)
            case "particleLook":
                if var e = scene[entity, ParticleEmitter.self] {
                    e.sizeStart = words.number(e.sizeStart)
                    e.sizeEnd = words.number(e.sizeEnd)
                    e.colorStart = words.vec4(e.colorStart)
                    e.colorEnd = words.vec4(e.colorEnd)
                    e.isAdditive = words.flag(true)
                    e.isEmitting = words.flag(true)
                    e.maxParticles = words.integer(e.maxParticles)
                    scene[entity, ParticleEmitter.self] = e
                }
            default: break
            }
        }
    }

    for (child, index) in parents where index >= 0 && index < entities.count && entities[index] != child {
        scene[child, Transform.self]?.parent = entities[index]
    }
    return true
}

@discardableResult
public func saveSceneFile(_ path: String, _ scene: Scene, materials: [NamedMaterial], settings: RenderSettings) -> Bool {
    do {
        try writeScene(scene, materials: materials, settings: settings).write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        logError("cannot write scene \(path)")
        return false
    }
    logInfo("saved \(path)")
    return true
}

@discardableResult
public func loadSceneFile(_ path: String, into scene: Scene, materials: inout [NamedMaterial], settings: inout RenderSettings,
                          assets: SceneAssets) -> Bool {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        logError("cannot read scene \(path)")
        return false
    }
    return readScene(text, into: scene, materials: &materials, settings: &settings, assets: assets)
}
