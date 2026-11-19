// Environment.swift
// The sky as a light source.
//
// The procedural sky is rendered into a cubemap, and from that cubemap come the three
// textures of image-based lighting: the irradiance map for diffuse light, the
// prefiltered map for reflections of every roughness, and the BRDF lookup table.
// Everything happens on the GPU with small render passes, one per cube face and mip
// level. It runs when the engine starts and again whenever the sky changes.

import Metal
import ShaderTypes

final class Environment {
    private static let skySize = 256
    private static let irradianceSize = 32
    private static let prefilteredSize = 128
    private static let prefilteredMips = 6
    private static let lutSize = 256

    private let device: GraphicsDevice
    private let shaders: ShaderLibrary
    private let sky: MTLTexture
    let irradianceMap: MTLTexture
    let prefilteredMap: MTLTexture
    let brdfLUT: MTLTexture
    var prefilteredMipCount: Float { Float(Environment.prefilteredMips) }

    private var hasCapture = false
    private var hasLUT = false
    private var captured = FrameUniforms()

    init(device: GraphicsDevice, shaders: ShaderLibrary) {
        self.device = device
        self.shaders = shaders
        sky = Environment.makeCube(device, size: Environment.skySize, mipLevels: 9)        // 256 down to 1
        irradianceMap = Environment.makeCube(device, size: Environment.irradianceSize, mipLevels: 1)
        prefilteredMap = Environment.makeCube(device, size: Environment.prefilteredSize, mipLevels: Environment.prefilteredMips)
        brdfLUT = device.makeRenderTarget(format: .rg16Float, width: Environment.lutSize, height: Environment.lutSize)
    }

    private static func makeCube(_ device: GraphicsDevice, size: Int, mipLevels: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .typeCube
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = size
        descriptor.height = size
        descriptor.mipmapLevelCount = mipLevels
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.device.makeTexture(descriptor: descriptor) else { fatalError("cannot create a cube texture") }
        return texture
    }

    /// Forces the next updateIfNeeded() to run, for example after a shader reload.
    func invalidate() {
        hasCapture = false
        hasLUT = false
    }

    /// Draws the full-screen triangle into one face and mip level of a cubemap (or a 2D texture).
    private func renderFace(_ commandBuffer: MTLCommandBuffer, target: MTLTexture, face: Int, mip: Int, fragmentFunction: String,
                            capture: CaptureUniforms, frame: FrameUniforms, source: MTLTexture?) {
        var description = PipelineDescription()
        description.vertexFunction = "vertex_fullscreen"
        description.fragmentFunction = fragmentFunction
        description.colorFormat = target.pixelFormat
        guard let pipeline = shaders.pipeline(description) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].slice = face
        pass.colorAttachments[0].level = mip
        pass.colorAttachments[0].loadAction = .dontCare         // every pixel is written
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = fragmentFunction                         // shows up in Xcode's GPU debugger
        encoder.setRenderPipelineState(pipeline)
        var captureCopy = capture, frameCopy = frame
        encoder.setFragmentBytes(&captureCopy, length: MemoryLayout<CaptureUniforms>.stride, index: BufferIndex.pass)
        encoder.setFragmentBytes(&frameCopy, length: MemoryLayout<FrameUniforms>.stride, index: BufferIndex.frame)
        if let source = source { encoder.setFragmentTexture(source, index: 0) }
        encoder.setFragmentSamplerState(device.linearClampSampler, index: SamplerIndex.linearClamp)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Re-renders the sky and its filtered maps if the sky described by `frame` differs
    /// from the one captured last. Returns true if it encoded any work.
    @discardableResult
    func updateIfNeeded(_ commandBuffer: MTLCommandBuffer, frame: FrameUniforms) -> Bool {
        // Only the fields the sky shader reads matter here.
        let isSame = hasCapture
            && frame.sunDirection == captured.sunDirection && frame.sunColor == captured.sunColor
            && frame.skyZenithColor == captured.skyZenithColor && frame.skyHorizonColor == captured.skyHorizonColor
            && frame.skyGroundColor == captured.skyGroundColor && frame.skyIntensity == captured.skyIntensity
        if isSame || !shaders.isValid { return false }

        var capture = CaptureUniforms()
        capture.sourceSize = Float(Environment.skySize)

        // 1. The sky itself, then its mip chain: the filters below read blurry levels of it.
        for face in 0..<6 {
            capture.face = UInt32(face)
            renderFace(commandBuffer, target: sky, face: face, mip: 0, fragmentFunction: "fragment_sky_capture",
                       capture: capture, frame: frame, source: nil)
        }
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: sky)
            blit.endEncoding()
        }

        // 2. Diffuse irradiance.
        for face in 0..<6 {
            capture.face = UInt32(face)
            renderFace(commandBuffer, target: irradianceMap, face: face, mip: 0, fragmentFunction: "fragment_irradiance",
                       capture: capture, frame: frame, source: sky)
        }

        // 3. Reflections: mip 0 is a mirror, the last mip is fully rough.
        for mip in 0..<Environment.prefilteredMips {
            capture.roughness = Float(mip) / Float(Environment.prefilteredMips - 1)
            for face in 0..<6 {
                capture.face = UInt32(face)
                renderFace(commandBuffer, target: prefilteredMap, face: face, mip: mip, fragmentFunction: "fragment_prefilter",
                           capture: capture, frame: frame, source: sky)
            }
        }

        // 4. The lookup table does not depend on the sky: once is enough.
        if !hasLUT {
            renderFace(commandBuffer, target: brdfLUT, face: 0, mip: 0, fragmentFunction: "fragment_brdf_lut",
                       capture: capture, frame: frame, source: nil)
            hasLUT = true
        }

        captured = frame
        hasCapture = true
        return true
    }
}
