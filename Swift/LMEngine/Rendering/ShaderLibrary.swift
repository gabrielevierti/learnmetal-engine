// ShaderLibrary.swift
// Compiles the shaders and hands out render pipeline states.
//
// The shaders are compiled from source when the engine starts. That costs a fraction
// of a second, and buys two things while developing: no build step for shaders, and
// hot reloading. Save a .metal file while the game runs and the engine recompiles it;
// if the new version has an error, the message is logged and the old shaders stay.
//
// A pipeline state fixes the vertex and fragment functions, the formats of the
// textures drawn into, the sample count and the blending. Creating one is slow, so
// each combination is created the first time it is asked for and kept.

import Foundation
import Metal

public enum BlendMode {
    case opaque         // the new color replaces the old one
    case alphaBlend     // new * alpha + old * (1 - alpha)
    case additive       // new * alpha + old
}

public struct PipelineDescription {
    public var vertexFunction = ""
    public var fragmentFunction = ""                    // empty for depth-only passes
    public var colorFormat = MTLPixelFormat.invalid     // .invalid: no color attachment
    public var depthFormat = MTLPixelFormat.invalid     // .invalid: no depth attachment
    public var sampleCount = 1
    public var blend = BlendMode.opaque
    public var usesMeshVertices = false                 // reads vertices through the mesh vertex descriptor

    public init() {}
}

public final class ShaderLibrary {
    private let device: MTLDevice
    private let directory: String
    private var library: MTLLibrary?
    private let meshVertexDescriptor: MTLVertexDescriptor
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var files: [String] = []
    private var loadedTime = Date.distantPast

    /// The compiler's message from the last failed compilation; empty after a success.
    public private(set) var lastError = ""
    public var isValid: Bool { library != nil }

    public init(device: MTLDevice, directory: String) {
        self.device = device
        self.directory = directory
        meshVertexDescriptor = ShaderLibrary.makeMeshVertexDescriptor()
        compile()
    }

    /// Describes MeshData.interleaved(): position, normal, tangent, uv, 12 floats in all.
    private static func makeMeshVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let formats: [MTLVertexFormat] = [.float3, .float3, .float4, .float2]
        let offsets = [0, 12, 24, 40]
        for i in 0..<4 {
            descriptor.attributes[i].format = formats[i]
            descriptor.attributes[i].offset = offsets[i]
            descriptor.attributes[i].bufferIndex = BufferIndex.vertices
        }
        descriptor.layouts[BufferIndex.vertices].stride = MeshData.floatsPerVertex * MemoryLayout<Float>.stride
        return descriptor
    }

    @discardableResult
    private func compile() -> Bool {
        let source = ShaderSource.load(directory: directory)
        files = source.files
        loadedTime = newestFileTime()
        if !source.error.isEmpty {
            lastError = source.error
            logError("shaders: \(lastError)")
            return false
        }
        do {
            library = try device.makeLibrary(source: source.text, options: nil)
        } catch {
            lastError = error.localizedDescription
            logError("shaders did not compile:\n\(lastError)")
            return false
        }
        pipelines.removeAll()           // they were built from the old functions
        lastError = ""
        logInfo("compiled \(files.count) shader files from \(directory)")
        return true
    }

    private func newestFileTime() -> Date {
        var newest = Date.distantPast
        for file in files {
            let attributes = try? FileManager.default.attributesOfItem(atPath: file)
            if let time = attributes?[.modificationDate] as? Date, time > newest { newest = time }
        }
        return newest
    }

    /// Recompiles if any shader file changed on disk. Returns true if new shaders are in use.
    public func reloadIfChanged() -> Bool {
        if newestFileTime() <= loadedTime { return false }
        logInfo("shader files changed, recompiling")
        return compile()
    }

    /// The pipeline for this description, or nil if the shaders failed to compile.
    public func pipeline(_ description: PipelineDescription) -> MTLRenderPipelineState? {
        guard let library = library else { return nil }
        let key = "\(description.vertexFunction)|\(description.fragmentFunction)|\(description.colorFormat.rawValue)|"
            + "\(description.depthFormat.rawValue)|\(description.sampleCount)|\(description.blend)|"
            + (description.usesMeshVertices ? "mesh" : "none")
        if let found = pipelines[key] { return found }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = key
        guard let vertexFunction = library.makeFunction(name: description.vertexFunction) else {
            logError("shader function not found: \(description.vertexFunction)")
            return nil
        }
        descriptor.vertexFunction = vertexFunction
        if !description.fragmentFunction.isEmpty {
            guard let fragmentFunction = library.makeFunction(name: description.fragmentFunction) else {
                logError("shader function not found: \(description.fragmentFunction)")
                return nil
            }
            descriptor.fragmentFunction = fragmentFunction
        }
        if description.usesMeshVertices { descriptor.vertexDescriptor = meshVertexDescriptor }

        if description.colorFormat != .invalid, let color = descriptor.colorAttachments[0] {
            color.pixelFormat = description.colorFormat
            if description.blend != .opaque {
                let isAdditive = description.blend == .additive
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add
                color.alphaBlendOperation = .add
                color.sourceRGBBlendFactor = .sourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationRGBBlendFactor = isAdditive ? .one : .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = isAdditive ? .one : .oneMinusSourceAlpha
            }
        }
        descriptor.depthAttachmentPixelFormat = description.depthFormat
        descriptor.rasterSampleCount = description.sampleCount

        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = state
            return state
        } catch {
            logError("pipeline \(key): \(error.localizedDescription)")
            return nil
        }
    }
}
