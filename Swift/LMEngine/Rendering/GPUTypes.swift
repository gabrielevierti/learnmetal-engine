// GPUTypes.swift
// The structs and binding slots shared with the shaders come from one C header,
// Shaders/Shared/ShaderTypes.h, which Swift imports as the module ShaderTypes. The
// same header is included by the Metal shaders and by the C++ engine, so a uniform
// struct can never have two different layouts.

import ShaderTypes

/// The C enums arrive as plain integer constants; these give them Swift-style names.
enum BufferIndex {
    static let vertices = Int(LMBufferVertices)
    static let pass = Int(LMBufferPass)
    static let instances = Int(LMBufferInstances)
    static let material = Int(LMBufferMaterial)
    static let frame = Int(LMBufferFrame)
    static let lights = Int(LMBufferLights)
}

enum TextureIndex {
    static let baseColor = Int(LMTextureBaseColor)
    static let normal = Int(LMTextureNormal)
    static let metallicRoughness = Int(LMTextureMetallicRoughness)
    static let occlusion = Int(LMTextureOcclusion)
    static let emissive = Int(LMTextureEmissive)
    static let shadowMap = Int(LMTextureShadowMap)
    static let irradiance = Int(LMTextureIrradiance)
    static let prefiltered = Int(LMTexturePrefiltered)
    static let brdf = Int(LMTextureBRDF)
    static let ambientOcclusion = Int(LMTextureAmbientOcclusion)
}

enum SamplerIndex {
    static let material = Int(LMSamplerMaterial)
    static let shadow = Int(LMSamplerShadow)
    static let linearClamp = Int(LMSamplerLinearClamp)
}

let maxLights = Int(LMMaxLights)
