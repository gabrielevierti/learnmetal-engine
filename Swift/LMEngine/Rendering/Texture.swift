// Texture.swift
// An image on the GPU.

import Metal
import simd

public enum TextureFormat {
    case rgba8sRGB      // colors: base color and emissive maps. The GPU converts to linear when sampling
    case rgba8          // data: normal, roughness, metalness and occlusion maps
    case r8             // one channel: font atlases, masks
}

public final class Texture {
    public let handle: MTLTexture
    public var width: Int { handle.width }
    public var height: Int { handle.height }
    /// The file name in the Assets folder, if the texture was loaded from one. Scene files store it.
    public var name = ""

    public init(_ texture: MTLTexture) {
        handle = texture
    }

    /// From pixels in memory, row by row from the top. `mipmaps` builds the whole chain.
    public static func fromPixels(_ device: GraphicsDevice, pixels: [UInt8], width: Int, height: Int,
                                  format: TextureFormat, mipmaps: Bool) -> Texture {
        let pixelFormat: MTLPixelFormat = format == .rgba8sRGB ? .rgba8Unorm_srgb : format == .rgba8 ? .rgba8Unorm : .r8Unorm
        let bytesPerPixel = format == .r8 ? 1 : 4

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height,
                                                                  mipmapped: mipmaps && (width > 1 || height > 1))
        descriptor.usage = .shaderRead
        guard let texture = device.device.makeTexture(descriptor: descriptor) else { fatalError("cannot create a texture") }
        pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes.baseAddress!,
                            bytesPerRow: width * bytesPerPixel)
        }

        if texture.mipmapLevelCount > 1, let commandBuffer = device.queue.makeCommandBuffer(),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            // The GPU builds the smaller levels: a blit pass, submitted right away.
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commandBuffer.commit()
        }
        return Texture(texture)
    }

    /// A one-pixel texture: the stand-in for a map a material does not have.
    public static func solidColor(_ device: GraphicsDevice, _ color: Vec4, format: TextureFormat = .rgba8) -> Texture {
        let scaled = simd_clamp(color, Vec4(0, 0, 0, 0), Vec4(1, 1, 1, 1)) * 255 + 0.5
        let pixel = [UInt8(scaled.x), UInt8(scaled.y), UInt8(scaled.z), UInt8(scaled.w)]
        return fromPixels(device, pixels: pixel, width: 1, height: 1, format: format, mipmaps: false)
    }

    /// From a PNG or JPEG file. Returns nil and logs if the file cannot be read.
    public static func load(_ device: GraphicsDevice, path: String, format: TextureFormat, mipmaps: Bool = true) -> Texture? {
        guard let image = decodeImage(path: path, channels: format == .r8 ? 1 : 4) else {
            logError("cannot load texture \(path)")
            return nil
        }
        return fromPixels(device, pixels: image.pixels, width: image.width, height: image.height, format: format, mipmaps: mipmaps)
    }
}
