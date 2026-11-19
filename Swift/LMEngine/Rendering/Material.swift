// Material.swift
// How a surface looks: the inputs of the physically based shader.
// The layout follows glTF's "metallic-roughness" model, the one most tools export.

public enum AlphaMode {
    case opaque     // alpha is ignored
    case mask       // pixels with alpha below alphaCutoff are cut out
    case blend      // drawn after everything opaque, sorted back to front, blended
}

/// Each factor multiplies the matching texture. A missing texture counts as white
/// (or as a flat surface, for the normal map), so factors alone describe a plain material.
///
/// A material is a class: many entities share one, and changing it changes them all.
public final class Material {
    public var baseColor = Vec4(1, 1, 1, 1)         // linear RGB and opacity
    public var metallic: Float = 0                  // 0 plastic, wood, stone; 1 metal
    public var roughness: Float = 0.6               // 0 mirror; 1 chalk
    public var emissive = Vec3(0, 0, 0)             // light the surface gives off; above 1 it blooms
    public var normalScale: Float = 1
    public var occlusionStrength: Float = 1
    public var alphaCutoff: Float = 0.5
    public var uvScale = Vec2(1, 1)

    public var alphaMode = AlphaMode.opaque
    public var isDoubleSided = false                // do not cull back faces
    public var isUnlit = false                      // base color and emissive only, no lighting

    public var baseColorTexture: Texture?           // sRGB
    public var normalTexture: Texture?              // tangent space, green up
    public var metallicRoughnessTexture: Texture?   // roughness in green, metalness in blue
    public var occlusionTexture: Texture?           // red
    public var emissiveTexture: Texture?            // sRGB

    public init() {}

    /// A second material that starts out equal to this one. (Material is a class, so that
    /// many entities can share one; assigning it to another variable does not copy it.)
    public func copy() -> Material {
        let other = Material()
        other.baseColor = baseColor
        other.metallic = metallic
        other.roughness = roughness
        other.emissive = emissive
        other.normalScale = normalScale
        other.occlusionStrength = occlusionStrength
        other.alphaCutoff = alphaCutoff
        other.uvScale = uvScale
        other.alphaMode = alphaMode
        other.isDoubleSided = isDoubleSided
        other.isUnlit = isUnlit
        other.baseColorTexture = baseColorTexture
        other.normalTexture = normalTexture
        other.metallicRoughnessTexture = metallicRoughnessTexture
        other.occlusionTexture = occlusionTexture
        other.emissiveTexture = emissiveTexture
        return other
    }
}

/// Component: draws a mesh with a material at the entity's Transform.
public struct MeshRenderer {
    public var mesh: Mesh?
    public var material: Material?
    public var tint = Vec4(1, 1, 1, 1)              // multiplies the material's base color for this entity only
    public var castsShadows = true
    public var isVisible = true

    public init(mesh: Mesh?, material: Material?) {
        self.mesh = mesh
        self.material = material
    }
}
