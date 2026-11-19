// GraphicsDevice.swift
// The Metal device, its command queue, and the small state objects everything shares:
// samplers and depth-stencil states. They are created once, here, because creating
// state objects is not something to do while drawing.

import Metal

public final class GraphicsDevice {
    public let device: MTLDevice
    public let queue: MTLCommandQueue

    /// True on Apple GPUs. Their render targets can live in tile memory only, without
    /// any allocation behind them (see the "Tile-Based GPUs" chapter).
    public let supportsMemorylessTargets: Bool

    public let materialSampler: MTLSamplerState         // trilinear, anisotropic, repeat
    public let linearClampSampler: MTLSamplerState
    public let pointClampSampler: MTLSamplerState
    public let shadowSampler: MTLSamplerState           // compares, then filters

    public let depthWrite: MTLDepthStencilState         // test "less", write
    public let depthReadOnly: MTLDepthStencilState      // test "less or equal", no write
    public let depthOff: MTLDepthStencilState           // no test, no write

    /// Uses the system's default GPU.
    public init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is not available on this machine")
        }
        self.device = device
        self.queue = queue
        supportsMemorylessTargets = device.supportsFamily(.apple2)
        logInfo("GPU: \(device.name)")

        materialSampler = GraphicsDevice.makeSampler(device, filter: .linear, mipFilter: .linear, addressMode: .repeat, anisotropy: 8, compares: false)
        linearClampSampler = GraphicsDevice.makeSampler(device, filter: .linear, mipFilter: .linear, addressMode: .clampToEdge, anisotropy: 1, compares: false)
        pointClampSampler = GraphicsDevice.makeSampler(device, filter: .nearest, mipFilter: .notMipmapped, addressMode: .clampToEdge, anisotropy: 1, compares: false)
        shadowSampler = GraphicsDevice.makeSampler(device, filter: .linear, mipFilter: .notMipmapped, addressMode: .clampToEdge, anisotropy: 1, compares: true)

        depthWrite = GraphicsDevice.makeDepthState(device, compare: .less, write: true)
        depthReadOnly = GraphicsDevice.makeDepthState(device, compare: .lessEqual, write: false)
        depthOff = GraphicsDevice.makeDepthState(device, compare: .always, write: false)
    }

    private static func makeSampler(_ device: MTLDevice, filter: MTLSamplerMinMagFilter, mipFilter: MTLSamplerMipFilter,
                                    addressMode: MTLSamplerAddressMode, anisotropy: Int, compares: Bool) -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.mipFilter = mipFilter
        descriptor.sAddressMode = addressMode
        descriptor.tAddressMode = addressMode
        descriptor.rAddressMode = addressMode
        descriptor.maxAnisotropy = anisotropy
        if compares { descriptor.compareFunction = .lessEqual }
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { fatalError("cannot create a sampler state") }
        return sampler
    }

    private static func makeDepthState(_ device: MTLDevice, compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = compare
        descriptor.isDepthWriteEnabled = write
        guard let state = device.makeDepthStencilState(descriptor: descriptor) else { fatalError("cannot create a depth-stencil state") }
        return state
    }

    /// A texture a pass can render into. `sampleCount` above 1 makes it multisampled;
    /// `memoryless` is honored only where supported.
    public func makeRenderTarget(format: MTLPixelFormat, width: Int, height: Int, sampleCount: Int = 1,
                                 memoryless: Bool = false, mipLevels: Int = 1) -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
        descriptor.pixelFormat = format
        descriptor.width = max(width, 1)
        descriptor.height = max(height, 1)
        descriptor.sampleCount = sampleCount
        descriptor.mipmapLevelCount = mipLevels
        if memoryless && supportsMemorylessTargets {
            descriptor.usage = .renderTarget
            descriptor.storageMode = .memoryless
        } else {
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else { fatalError("cannot create a render target") }
        return texture
    }
}
