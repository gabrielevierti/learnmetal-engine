// Assets.swift
// Loads textures, meshes, fonts and sounds from the Assets folder, and remembers them:
// asking for the same file twice gives back the same object, already loaded.

import Foundation

/// A font ready to draw with: the glyph table and the atlas texture.
public struct Font {
    public var metrics: FontMetrics
    public var atlas: Texture
}

public final class Assets {
    private let device: GraphicsDevice
    private let directory: String
    // A failed load is remembered too (as nil), so it is reported once.
    private var textures: [String: Texture?] = [:]
    private var meshes: [String: Mesh?] = [:]
    private var fonts: [String: Font?] = [:]
    private var sounds: [String: AudioClip?] = [:]

    public init(device: GraphicsDevice, directory: String) {
        self.device = device
        self.directory = directory
    }

    /// The full path of a file in the Assets folder.
    public func path(_ name: String) -> String { directory + "/" + name }

    // MARK: From files, by name relative to the Assets folder

    /// An image. Use `.rgba8sRGB` for colors (the default) and `.rgba8` for data such as normal maps.
    public func texture(_ name: String, format: TextureFormat = .rgba8sRGB) -> Texture? {
        // The same image may be wanted both as color and as data: those are different textures.
        let key = "\(name)|\(format)"
        if let cached = textures[key] { return cached }
        let texture = Texture.load(device, path: path(name), format: format)
        texture?.name = name
        textures[key] = .some(texture)
        return texture
    }

    /// A Wavefront OBJ model, or one of the built-in shapes: "cube", "sphere", "plane", "cylinder".
    public func mesh(_ name: String) -> Mesh? {
        switch name {
        case "cube": return cube
        case "sphere": return sphere
        case "plane": return plane
        case "cylinder": return cylinder
        default: break
        }
        if let cached = meshes[name] { return cached }
        var mesh: Mesh?
        if let text = try? String(contentsOfFile: path(name), encoding: .utf8) {
            if let data = MeshData.parseOBJ(text) {
                mesh = Mesh(device, data)
                mesh?.name = name
            } else {
                logError("no triangles in model \(name)")
            }
        } else {
            logError("cannot read model \(path(name))")
        }
        meshes[name] = .some(mesh)
        return mesh
    }

    /// A font baked by Tools/bake_font.py: `name`.png and `name`.txt.
    public func font(_ name: String) -> Font? {
        if let cached = fonts[name] { return cached }
        var font: Font?
        // One channel is enough for a distance field, and it must not be mipmapped:
        // a blurred distance is no longer a distance.
        if let text = try? String(contentsOfFile: path(name + ".txt"), encoding: .utf8),
           let metrics = FontMetrics.parse(text),
           let atlas = Texture.load(device, path: path(name + ".png"), format: .r8, mipmaps: false) {
            font = Font(metrics: metrics, atlas: atlas)
        } else {
            logError("cannot load font \(name) (needs \(name).png and \(name).txt)")
        }
        fonts[name] = .some(font)
        return font
    }

    /// A WAV, AIFF, MP3 or AAC file.
    public func sound(_ name: String) -> AudioClip? {
        if let cached = sounds[name] { return cached }
        let clip = Audio.loadClip(path: path(name))
        sounds[name] = .some(clip)
        return clip
    }

    // MARK: Made in code

    public func makeMesh(_ data: MeshData) -> Mesh { Mesh(device, data) }

    public func makeMaterial(baseColor: Vec4, metallic: Float = 0, roughness: Float = 0.6) -> Material {
        let material = Material()
        material.baseColor = baseColor
        material.metallic = metallic
        material.roughness = roughness
        return material
    }

    /// Shared unit shapes: a cube with sides of 1, a sphere and a cylinder of diameter 1,
    /// a 1 x 1 plane facing up. Scale them with the entity's Transform.
    public private(set) lazy var cube: Mesh = named("cube", MeshData.cube())
    public private(set) lazy var sphere: Mesh = named("sphere", MeshData.sphere(radius: 0.5, segments: 48, rings: 24))
    public private(set) lazy var plane: Mesh = named("plane", MeshData.plane())
    public private(set) lazy var cylinder: Mesh = named("cylinder", MeshData.cylinder())

    private func named(_ name: String, _ data: MeshData) -> Mesh {
        let mesh = makeMesh(data)
        mesh.name = name
        return mesh
    }

    /// The files in a folder of Assets whose names end with `suffix`, sorted, as names
    /// that texture() and mesh() accept: listFiles("Textures", ".png").
    public func listFiles(_ folder: String, _ suffix: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path(folder))) ?? []
        return files.filter { $0.hasSuffix(suffix) }.sorted().map { folder + "/" + $0 }
    }

    /// How the names in a scene file become assets: through this cache.
    public var sceneAssets: SceneAssets {
        SceneAssets(mesh: { [unowned self] name in self.mesh(name) },
                    texture: { [unowned self] name, format in self.texture(name, format: format) })
    }
}
