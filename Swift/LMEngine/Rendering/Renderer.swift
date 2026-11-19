// Renderer.swift
// Draws a Scene.
//
// Every frame goes through the same sequence of passes:
//
//   1. shadow maps     the scene seen from the sun, once per cascade        (depth only)
//   2. depth pre-pass  depth and normals of what the camera sees            (only if SSAO is on)
//   3. SSAO            how hidden each pixel is from the sky, then a blur
//   4. main pass       opaque objects, sky, transparent objects, particles, debug lines
//                      into a multisampled, floating-point (HDR) target
//   5. bloom           bright areas blurred through a chain of smaller and smaller textures
//   6. final pass      tone mapping onto the screen, then the 2D canvas on top
//
// Before any of that, the renderer walks the scene once and builds plain lists of what
// to draw ("extraction"): it finds the camera and the lights, drops objects outside the
// view, sorts, and groups objects that share a mesh and a material into instanced draws.
//
// This file decides what is drawn. RenderPasses.swift is where the draw calls are.

import Foundation
import Metal
import ShaderTypes
import simd

/// The colors are radiance, in the same units as light intensities. A clear sky is several
/// times darker than a white wall in sunlight; keeping that ratio is what makes shadows read.
public struct SkySettings {
    public var zenithColor = Vec3(0.05, 0.15, 0.42)
    public var horizonColor = Vec3(0.38, 0.52, 0.72)
    public var groundColor = Vec3(0.11, 0.14, 0.19)     // what is seen, and reflected, below the horizon
    public var intensity: Float = 1
    public var sunDiskIntensity: Float = 30             // how much brighter than the sunlight the disk itself looks
    public var sunAngularRadius: Float = radians(1.2)
    public var cloudCoverage: Float = 0                 // 0 a clear sky, 1 overcast
    public var cloudScale: Float = 1                    // larger numbers make smaller clouds
    public var cloudSpeed = Vec2(0.012, 0.004)          // how fast the wind carries them

    public init() {}
}

public struct RenderSettings {
    public var sampleCount = 4                          // multisampling: 1 (off), 2 or 4
    public var renderScale: Float = 1                   // below 1 renders the scene smaller and stretches it

    public var shadowsEnabled = true
    public var cascades = CascadeSettings()
    public var shadowBias: Float = 0.0001               // in shadow-map depth, on top of the normal offset
    public var shadowNormalOffset: Float = 2            // in shadow-map texels; 2 covers the 3 x 3 filter

    public var sky = SkySettings()
    public var environmentIntensity: Float = 1          // strength of the image-based lighting

    public var fogColor = Vec3(0.38, 0.52, 0.72)
    public var fogDensity: Float = 0                    // 0 turns fog off

    public var ambientOcclusionEnabled = true
    public var ambientOcclusionRadius: Float = 0.6      // in world units
    public var ambientOcclusionIntensity: Float = 1
    public var ambientOcclusionPower: Float = 1.5

    public var bloomEnabled = true
    public var bloomIntensity: Float = 0.06
    public var bloomThreshold: Float = 1
    public var bloomKnee: Float = 0.5

    public var exposure: Float = 1
    public var toneMapper = 0                           // 0 ACES, 1 Reinhard, 2 none
    public var vignette: Float = 0.25

    // The camera's lens and video signal: what makes a picture look filmed, not computed.
    public var lensDistortion: Float = 0                // 0 none; 0.3 an action camera; 0.6 a fisheye
    public var chromaticAberration: Float = 0           // colors separate toward the corners; 0.01 is plenty
    public var filmGrain: Float = 0                     // fine noise; 0.03 is visible
    public var interference: Float = 0                  // 0 clean, 1 an analog video link about to drop

    public init() {}
}

public struct RenderStats {
    public var drawCalls = 0
    public var instances = 0
    public var triangles = 0
    public var visibleObjects = 0
    public var culledObjects = 0
    public var lights = 0
}

/// Where the finished frame goes: a drawable's texture, or any texture when rendering off screen.
public struct RenderTarget {
    public var texture: MTLTexture
    public var drawable: MTLDrawable?                   // presented after the frame, if set

    public init(texture: MTLTexture, drawable: MTLDrawable? = nil) {
        self.texture = texture
        self.drawable = drawable
    }
}

public final class Renderer {
    public var settings = RenderSettings()
    public internal(set) var stats = RenderStats()      // of the last frame
    public let debug = DebugDraw()                      // lines to draw with the next frame

    /// If this entity has a Camera, the renderer looks through it whatever the scene's own
    /// cameras say. An editor uses it to look around without touching the scene.
    public var cameraOverride = Entity.invalid

    public let device: GraphicsDevice
    public let shaders: ShaderLibrary

    struct DrawItem {
        var mesh: Mesh
        var material: Material
        var world: Mat4
        var tint: Vec4
        var bounds: AABB                                // in world space
        var distanceSquared: Float                      // from the camera
        var castsShadows: Bool
    }

    /// One instanced draw call: `count` copies of a mesh with one material.
    struct Batch {
        var mesh: Mesh
        var material: Material
        var instances: FrameAllocator.Allocation
        var count: Int
    }

    struct View {
        var world = matrix_identity_float4x4
        var view = matrix_identity_float4x4
        var projection = matrix_identity_float4x4
        var viewProjection = matrix_identity_float4x4
        var position = Vec3(0, 0, 0)
        var fovY: Float = radians(60)
        var aspect: Float = 1
        var nearPlane: Float = 0.1
        var farPlane: Float = 500
    }

    enum MeshPass { case shadow, prepass, forward }

    static let framesInFlight = 3
    static let sceneFormat = MTLPixelFormat.rgba16Float
    static let depthFormat = MTLPixelFormat.depth32Float

    let environment: Environment
    private let allocators: [FrameAllocator]
    private var frameIndex = 0
    private var frameNumber: UInt64 = 0
    var frameTime: Double = 0                           // of the frame being drawn
    private let frameSemaphore = DispatchSemaphore(value: Renderer.framesInFlight)

    let white: Texture
    let flatNormal: Texture
    private let defaultMaterial = Material()

    private var targetWidth = 0, targetHeight = 0
    var targetSamples = 0
    private var targetHasOcclusion = false
    var sceneColorMultisample: MTLTexture?
    var sceneDepth: MTLTexture?
    var sceneColor: MTLTexture?
    var prepassDepth: MTLTexture?
    var prepassNormal: MTLTexture?
    var occlusionRaw: MTLTexture?
    var occlusion: MTLTexture?
    var bloom: [MTLTexture] = []
    var shadowMap: MTLTexture?
    private var shadowMapSize = 0, shadowMapSlices = 0
    private var imageTarget: MTLTexture?                // for renderToImage

    var allocator: FrameAllocator { allocators[frameIndex] }

    public init(device: GraphicsDevice, shaderDirectory: String) {
        self.device = device
        shaders = ShaderLibrary(device: device.device, directory: shaderDirectory)
        environment = Environment(device: device, shaders: shaders)
        allocators = (0..<Renderer.framesInFlight).map { _ in FrameAllocator(device: device.device, capacity: 1 << 20) }
        white = Texture.solidColor(device, Vec4(1, 1, 1, 1))
        flatNormal = Texture.solidColor(device, Vec4(0.5, 0.5, 1, 1))
    }

    deinit {
        // Take every frame slot: once we hold them all, the GPU has finished every frame.
        // Then give them back, because a semaphore must not be destroyed below its initial count.
        for _ in 0..<Renderer.framesInFlight { frameSemaphore.wait() }
        for _ in 0..<Renderer.framesInFlight { frameSemaphore.signal() }
    }

    /// Blocks until the GPU has finished every frame submitted so far.
    public func waitUntilIdle() {
        // Command buffers of one queue run in order: when this empty one is done, so is everything before it.
        guard let commandBuffer = device.queue.makeCommandBuffer() else { return }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Draws a frame into memory instead of a window: `width` x `height` pixels, four bytes
    /// each (red, green, blue, alpha), rows from the top. For screenshots and for running
    /// without a window.
    public func renderToImage(scene: Scene, canvas: Canvas, width: Int, height: Int, time: Double) -> [UInt8] {
        let width = max(width, 1), height = max(height, 1)
        if imageTarget == nil || imageTarget?.width != width || imageTarget?.height != height {
            imageTarget = device.makeRenderTarget(format: .bgra8Unorm_srgb, width: width, height: height)
        }
        guard let texture = imageTarget else { return [] }
        render(scene: scene, canvas: canvas, target: RenderTarget(texture: texture), time: time)

        // The texture lives in GPU memory. A blit pass copies it into a buffer the CPU can
        // read, and then we wait: the copy has only happened once the GPU says so.
        let bytesPerRow = width * 4
        guard let buffer = device.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commandBuffer = device.queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // The texture stores blue first; image files want red first.
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        let source = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i < pixels.count {
            pixels[i] = source[i + 2]
            pixels[i + 1] = source[i + 1]
            pixels[i + 2] = source[i]
            i += 4
        }
        return pixels
    }

    // MARK: - Render targets

    private func ensureTargets(width: Int, height: Int) {
        var samples = min(max(settings.sampleCount, 1), 4)
        if samples == 3 { samples = 2 }
        if !device.device.supportsTextureSampleCount(samples) { samples = 1 }
        let wantOcclusion = settings.ambientOcclusionEnabled
        if width == targetWidth && height == targetHeight && samples == targetSamples && wantOcclusion == targetHasOcclusion { return }
        targetWidth = width
        targetHeight = height
        targetSamples = samples
        targetHasOcclusion = wantOcclusion

        // The scene is drawn in HDR. With multisampling, the multisampled color and the depth
        // are only needed while the pass runs, so on Apple GPUs they take no memory at all.
        sceneColor = device.makeRenderTarget(format: Renderer.sceneFormat, width: width, height: height)
        sceneColorMultisample = samples > 1
            ? device.makeRenderTarget(format: Renderer.sceneFormat, width: width, height: height, sampleCount: samples, memoryless: true)
            : nil
        sceneDepth = device.makeRenderTarget(format: Renderer.depthFormat, width: width, height: height, sampleCount: samples, memoryless: true)

        if wantOcclusion {
            prepassDepth = device.makeRenderTarget(format: Renderer.depthFormat, width: width, height: height)
            prepassNormal = device.makeRenderTarget(format: .rgba8Unorm, width: width, height: height)
            occlusionRaw = device.makeRenderTarget(format: .r8Unorm, width: width, height: height)
            occlusion = device.makeRenderTarget(format: .r8Unorm, width: width, height: height)
        } else {
            prepassDepth = nil
            prepassNormal = nil
            occlusionRaw = nil
            occlusion = nil
        }

        // The bloom chain: half size, quarter size, and so on.
        bloom.removeAll()
        var w = width / 2, h = height / 2
        while bloom.count < 6 && w >= 8 && h >= 8 {
            bloom.append(device.makeRenderTarget(format: Renderer.sceneFormat, width: w, height: h))
            w /= 2
            h /= 2
        }
    }

    private func ensureShadowMap() {
        // With shadows off, a single texel keeps the shader's texture argument bound.
        let size = settings.shadowsEnabled ? max(settings.cascades.resolution, 16) : 1
        let slices = settings.shadowsEnabled ? min(max(settings.cascades.count, 1), maxCascades) : 1
        if size == shadowMapSize && slices == shadowMapSlices { return }
        shadowMapSize = size
        shadowMapSlices = slices

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = Renderer.depthFormat
        descriptor.width = size
        descriptor.height = size
        descriptor.arrayLength = slices
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        shadowMap = device.device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Extraction

    private func findView(_ scene: Scene, aspect: Float) -> View {
        var view = View()
        view.aspect = aspect
        var found = false
        let chosen = cameraOverride
        let hasOverride = scene.has(Camera.self, chosen) && scene.has(Transform.self, chosen)
        scene.each(Camera.self, Transform.self) { entity, camera, transform in
            if found || (hasOverride ? entity != chosen : !camera.isActive) { return }
            found = true
            view.world = transform.world
            view.fovY = camera.fovY
            view.nearPlane = camera.nearPlane
            view.farPlane = camera.farPlane
            view.projection = camera.projection(aspect: aspect)
        }
        if !found {
            // No camera in the scene: look at the origin from a little above.
            view.world = Mat4.lookAt(eye: Vec3(0, 2, 6), target: Vec3(0, 0, 0)).inverse
            view.projection = Mat4.perspective(fovY: view.fovY, aspect: aspect, near: view.nearPlane, far: view.farPlane)
        }
        view.view = view.world.inverse
        view.viewProjection = view.projection * view.view
        view.position = xyz(view.world.columns.3)
        return view
    }

    private func collectItems(_ scene: Scene, view: View) -> [DrawItem] {
        var items: [DrawItem] = []
        scene.each(MeshRenderer.self, Transform.self) { _, renderer, transform in
            guard renderer.isVisible, let mesh = renderer.mesh else { return }
            let bounds = mesh.bounds.transformed(transform.world)
            items.append(DrawItem(mesh: mesh, material: renderer.material ?? defaultMaterial, world: transform.world,
                                  tint: renderer.tint, bounds: bounds,
                                  distanceSquared: simd_length_squared(bounds.center - view.position),
                                  castsShadows: renderer.castsShadows))
        }
        return items
    }

    /// Fills in the sun's fields of `frame` and returns the lights, the sun first.
    private func collectLights(_ scene: Scene, frame: inout FrameUniforms) -> (lights: [LightData], sunCastsShadows: Bool) {
        var sun: LightData?
        var sunCastsShadows = false
        var others: [LightData] = []

        scene.each(Light.self, Transform.self) { _, light, transform in
            var data = LightData()
            data.position = transform.worldPosition
            data.range = max(light.range, 0.001)
            data.direction = safeNormalize(-xyz(transform.world.columns.2), fallback: Vec3(0, -1, 0))   // the entity's -Z axis
            data.type = light.type.rawValue
            data.color = light.color * light.intensity
            let cosInner = cos(light.innerConeAngle)
            let cosOuter = cos(max(light.outerConeAngle, light.innerConeAngle + 0.001))
            data.spotScale = 1 / (cosInner - cosOuter)
            data.spotOffset = -cosOuter * data.spotScale

            // The first directional light is the sun: it lights the sky and may cast shadows.
            if light.type == .directional && sun == nil {
                sun = data
                sunCastsShadows = light.castsShadows
            } else {
                others.append(data)
            }
        }

        var lights: [LightData] = []
        if let sun = sun {
            lights.append(sun)                          // the shaders expect the sun first
            frame.sunDirection = sun.direction
            frame.sunColor = sun.color
        } else {
            frame.sunDirection = Vec3(0, -1, 0)
            frame.sunColor = Vec3(0, 0, 0)
        }
        for light in others {
            if lights.count >= maxLights {
                logWarning("more than \(maxLights) lights in the scene; the rest are ignored")
                break
            }
            lights.append(light)
        }
        return (lights, sunCastsShadows)
    }

    func makeBatches(_ items: [DrawItem], sortByState: Bool) -> [Batch] {
        var sorted = items
        if sortByState {
            // Objects that share a material and a mesh end up next to each other.
            sorted.sort { a, b in
                let materialA = ObjectIdentifier(a.material), materialB = ObjectIdentifier(b.material)
                if materialA != materialB { return materialA < materialB }
                return ObjectIdentifier(a.mesh) < ObjectIdentifier(b.mesh)
            }
        }
        var batches: [Batch] = []
        var instances: [InstanceData] = []
        var first = 0
        while first < sorted.count {
            // Every run of the same mesh and material becomes one instanced draw.
            instances.removeAll(keepingCapacity: true)
            var next = first
            while next < sorted.count && sorted[next].mesh === sorted[first].mesh && sorted[next].material === sorted[first].material {
                instances.append(InstanceData(model: sorted[next].world, normalMatrix: sorted[next].world.normalMatrix,
                                              tint: sorted[next].tint))
                next += 1
            }
            batches.append(Batch(mesh: sorted[first].mesh, material: sorted[first].material,
                                 instances: allocator.copyArray(instances), count: instances.count))
            first = next
        }
        return batches
    }

    private func makePassUniforms(view: Mat4, projection: Mat4, position: Vec3, width: Int, height: Int,
                                  nearPlane: Float, farPlane: Float, time: Double) -> PassUniforms {
        var uniforms = PassUniforms()
        uniforms.view = view
        uniforms.projection = projection
        uniforms.viewProjection = projection * view
        uniforms.inverseViewProjection = uniforms.viewProjection.inverse
        uniforms.inverseProjection = projection.inverse
        uniforms.cameraPosition = position
        uniforms.time = Float(time)
        uniforms.viewportSize = Vec2(Float(width), Float(height))
        uniforms.nearPlane = nearPlane
        uniforms.farPlane = farPlane
        return uniforms
    }

    // MARK: - The frame

    /// Draws the scene and the canvas into `target`. `time` is in seconds, for shaders.
    public func render(scene: Scene, canvas: Canvas, target: RenderTarget, time: Double) {
        // At most three frames may be waiting for the GPU. If it is behind, wait here.
        frameSemaphore.wait()
        frameIndex = (frameIndex + 1) % Renderer.framesInFlight
        allocator.reset()
        frameNumber += 1
        stats = RenderStats()

        if frameNumber % 30 == 0 && shaders.reloadIfChanged() { environment.invalidate() }

        let width = max(1, Int(Float(target.texture.width) * settings.renderScale))
        let height = max(1, Int(Float(target.texture.height) * settings.renderScale))
        ensureTargets(width: width, height: height)
        ensureShadowMap()

        // ---- what is in the scene
        let view = findView(scene, aspect: Float(width) / Float(height))
        let items = collectItems(scene, view: view)

        var frame = FrameUniforms()
        let (lights, sunCastsShadows) = collectLights(scene, frame: &frame)
        frame.lightCount = UInt32(lights.count)
        stats.lights = lights.count

        var cascades = Cascades()
        if settings.shadowsEnabled && sunCastsShadows {
            cascades = computeCascades(cameraWorld: view.world, fovY: view.fovY, aspect: view.aspect, nearPlane: view.nearPlane,
                                       lightDirection: frame.sunDirection, settings: settings.cascades)
            frame.cascadeCount = UInt32(cascades.count)
            // The C array of four matrices arrives in Swift as a tuple: write to it through its memory.
            withUnsafeMutableBytes(of: &frame.cascadeViewProjection) { bytes in
                let matrices = bytes.bindMemory(to: Mat4.self)
                for i in 0..<cascades.count { matrices[i] = cascades.viewProjection[i] }
            }
            for i in 0..<cascades.count {
                frame.cascadeSplits[i] = cascades.splitFar[i]
                frame.cascadeTexelSize[i] = 2 * cascades.radius[i] / Float(settings.cascades.resolution)
            }
        }
        frame.shadowBias = settings.shadowBias
        frame.shadowNormalOffset = settings.shadowNormalOffset
        frame.shadowMapSize = Float(shadowMapSize)
        frame.shadowDistance = settings.cascades.shadowDistance
        frame.environmentIntensity = settings.environmentIntensity
        frame.prefilteredMipCount = environment.prefilteredMipCount
        frame.ambientOcclusionStrength = settings.ambientOcclusionEnabled ? 1 : 0
        frame.skyZenithColor = settings.sky.zenithColor
        frame.skyHorizonColor = settings.sky.horizonColor
        frame.skyGroundColor = settings.sky.groundColor
        frame.skyIntensity = settings.sky.intensity
        frame.sunDiskIntensity = settings.sky.sunDiskIntensity
        frame.sunDiskSize = cos(settings.sky.sunAngularRadius)
        frame.fogColor = settings.fogColor
        frame.fogDensity = settings.fogDensity
        frame.cloudCoverage = settings.sky.cloudCoverage
        frame.cloudScale = settings.sky.cloudScale
        frame.cloudOffset = settings.sky.cloudSpeed * Float(time)
        frameTime = time

        // ---- what the camera can see, in the order it will be drawn
        let frustum = Frustum(viewProjection: view.viewProjection)
        var opaqueItems: [DrawItem] = [], transparentItems: [DrawItem] = []
        for item in items {
            if !frustum.intersects(item.bounds) {
                stats.culledObjects += 1
                continue
            }
            stats.visibleObjects += 1
            if item.material.alphaMode == .blend {
                transparentItems.append(item)
            } else {
                opaqueItems.append(item)
            }
        }
        // Transparent surfaces must be blended from the farthest to the nearest.
        transparentItems.sort { $0.distanceSquared > $1.distanceSquared }
        let opaque = makeBatches(opaqueItems, sortByState: true)
        let transparent = makeBatches(transparentItems, sortByState: false)

        let passUniforms = allocator.copy(makePassUniforms(view: view.view, projection: view.projection, position: view.position,
                                                           width: width, height: height, nearPlane: view.nearPlane,
                                                           farPlane: view.farPlane, time: time))
        let frameUniforms = allocator.copy(frame)
        let lightBuffer = allocator.copyArray(lights)

        // ---- the passes
        guard let commandBuffer = device.queue.makeCommandBuffer() else {
            frameSemaphore.signal()
            return
        }
        environment.updateIfNeeded(commandBuffer, frame: frame)
        if frame.cascadeCount > 0 { renderShadows(commandBuffer, items: items, cascades: cascades) }
        if settings.ambientOcclusionEnabled { renderOcclusion(commandBuffer, opaque: opaque, view: view, passUniforms: passUniforms) }
        renderScene(commandBuffer, scene: scene, opaque: opaque, transparent: transparent, view: view,
                    passUniforms: passUniforms, frameUniforms: frameUniforms, lights: lightBuffer)
        renderBloom(commandBuffer)
        renderFinal(commandBuffer, canvas: canvas, target: target)
        debug.clear()

        if let drawable = target.drawable { commandBuffer.present(drawable) }
        let semaphore = frameSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.commit()
    }
}
