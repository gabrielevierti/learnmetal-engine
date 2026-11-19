// RenderPasses.swift
// The passes of a frame, in the order they run. Renderer.swift decides what is drawn;
// this file is where the draw calls are.

import Metal
import ShaderTypes
import simd

private func texelSize(_ texture: MTLTexture) -> Vec2 {
    Vec2(1 / Float(texture.width), 1 / Float(texture.height))
}

extension Renderer {
    // MARK: - Meshes

    func bindMaterial(_ encoder: MTLRenderCommandEncoder, _ material: Material) {
        var uniforms = MaterialUniforms()
        uniforms.baseColor = material.baseColor
        uniforms.emissive = material.emissive
        uniforms.metallic = material.metallic
        uniforms.roughness = material.roughness
        uniforms.normalScale = material.normalScale
        uniforms.occlusionStrength = material.occlusionStrength
        uniforms.alphaCutoff = material.alphaCutoff
        uniforms.uvScale = material.uvScale
        // A few dozen bytes: Metal copies them into the command buffer, no buffer of our own needed.
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MaterialUniforms>.stride, index: BufferIndex.material)

        // A material without a map gets a one-pixel stand-in, so the shader needs no branches.
        encoder.setFragmentTexture((material.baseColorTexture ?? white).handle, index: TextureIndex.baseColor)
        encoder.setFragmentTexture((material.normalTexture ?? flatNormal).handle, index: TextureIndex.normal)
        encoder.setFragmentTexture((material.metallicRoughnessTexture ?? white).handle, index: TextureIndex.metallicRoughness)
        encoder.setFragmentTexture((material.occlusionTexture ?? white).handle, index: TextureIndex.occlusion)
        encoder.setFragmentTexture((material.emissiveTexture ?? white).handle, index: TextureIndex.emissive)
    }

    func drawBatches(_ encoder: MTLRenderCommandEncoder, _ batches: [Batch], pass: MeshPass,
                     colorFormat: MTLPixelFormat, sampleCount: Int) {
        var boundMaterial: Material?
        for batch in batches {
            let material = batch.material
            let isMasked = material.alphaMode == .mask

            var description = PipelineDescription()
            description.usesMeshVertices = true
            description.colorFormat = colorFormat
            description.depthFormat = Renderer.depthFormat
            description.sampleCount = sampleCount
            switch pass {
            case .shadow:
                // Depth only. Cut-out materials still need a fragment function, to make their holes.
                description.vertexFunction = isMasked ? "vertex_mesh" : "vertex_mesh_depth"
                description.fragmentFunction = isMasked ? "fragment_depth_masked" : ""
            case .prepass:
                description.vertexFunction = "vertex_mesh"
                description.fragmentFunction = isMasked ? "fragment_prepass_masked" : "fragment_prepass"
            case .forward:
                description.vertexFunction = "vertex_mesh"
                description.fragmentFunction = material.isUnlit ? "fragment_unlit" : isMasked ? "fragment_pbr_masked" : "fragment_pbr"
                if material.alphaMode == .blend { description.blend = .alphaBlend }
            }
            guard let pipeline = shaders.pipeline(description) else { continue }

            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(material.isDoubleSided ? .none : .back)
            if material !== boundMaterial && (pass == .forward || isMasked) {
                bindMaterial(encoder, material)
                boundMaterial = material
            }
            encoder.setVertexBuffer(batch.mesh.vertexBuffer, offset: 0, index: BufferIndex.vertices)
            encoder.setVertexBuffer(batch.instances.buffer, offset: batch.instances.offset, index: BufferIndex.instances)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.mesh.indexCount, indexType: .uint32,
                                          indexBuffer: batch.mesh.indexBuffer, indexBufferOffset: 0, instanceCount: batch.count)

            stats.drawCalls += 1
            if pass == .forward {
                stats.instances += batch.count
                stats.triangles += batch.mesh.indexCount / 3 * batch.count
            }
        }
    }

    // MARK: - 1. Shadow maps

    func renderShadows(_ commandBuffer: MTLCommandBuffer, items: [DrawItem], cascades: Cascades) {
        guard let shadowMap = shadowMap else { return }
        for cascade in 0..<cascades.count {
            // Whatever touches this cascade's box, or stands between it and the sun.
            let frustum = Frustum(viewProjection: cascades.viewProjection[cascade])
            let casters = items.filter { item in
                item.castsShadows && item.material.alphaMode != .blend && frustum.intersects(item.bounds, testNearPlane: false)
            }
            let batches = makeBatches(casters, sortByState: true)

            var uniforms = PassUniforms()
            uniforms.viewProjection = cascades.viewProjection[cascade]
            uniforms.view = matrix_identity_float4x4
            uniforms.projection = cascades.viewProjection[cascade]
            let passUniforms = allocator.copy(uniforms)

            // No color attachment: a shadow map is only a depth texture, one array slice per cascade.
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = shadowMap
            pass.depthAttachment.slice = cascade
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.label = "Shadow cascade"
            encoder.setDepthStencilState(device.depthWrite)
            encoder.setFrontFacing(.counterClockwise)
            // Casters in front of the box are flattened onto its near plane instead of being clipped away.
            encoder.setDepthClipMode(.clamp)
            // Push depths back in proportion to the surface's slope as the light sees it.
            encoder.setDepthBias(0, slopeScale: 1.5, clamp: 0)
            encoder.setVertexBuffer(passUniforms.buffer, offset: passUniforms.offset, index: BufferIndex.pass)
            encoder.setFragmentSamplerState(device.materialSampler, index: SamplerIndex.material)
            drawBatches(encoder, batches, pass: .shadow, colorFormat: .invalid, sampleCount: 1)
            encoder.endEncoding()
        }
    }

    // MARK: - 2 and 3. Ambient occlusion

    func renderOcclusion(_ commandBuffer: MTLCommandBuffer, opaque: [Batch], view: View, passUniforms: FrameAllocator.Allocation) {
        guard let prepassDepth = prepassDepth, let prepassNormal = prepassNormal,
              let occlusionRaw = occlusionRaw, let occlusion = occlusion else { return }

        // Depth and view-space normals of everything opaque, without multisampling.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = prepassNormal
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 1, alpha: 1)    // a normal facing the camera
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = prepassDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.label = "Depth and normals"
            encoder.setDepthStencilState(device.depthWrite)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setVertexBuffer(passUniforms.buffer, offset: passUniforms.offset, index: BufferIndex.pass)
            encoder.setFragmentBuffer(passUniforms.buffer, offset: passUniforms.offset, index: BufferIndex.pass)
            encoder.setFragmentSamplerState(device.materialSampler, index: SamplerIndex.material)
            drawBatches(encoder, opaque, pass: .prepass, colorFormat: .rgba8Unorm, sampleCount: 1)
            encoder.endEncoding()
        }

        var uniforms = AmbientOcclusionUniforms()
        uniforms.projection = view.projection
        uniforms.inverseProjection = view.projection.inverse
        uniforms.texelSize = texelSize(occlusionRaw)
        uniforms.radius = settings.ambientOcclusionRadius
        uniforms.bias = 0.03
        uniforms.intensity = settings.ambientOcclusionIntensity
        uniforms.power = settings.ambientOcclusionPower
        drawFullscreen(commandBuffer, target: occlusionRaw, fragmentFunction: "fragment_ssao", blend: .opaque, keepContents: false,
                       uniforms: uniforms, source0: prepassDepth, source1: prepassNormal, sampler0: device.pointClampSampler)
        drawFullscreen(commandBuffer, target: occlusion, fragmentFunction: "fragment_ssao_blur", blend: .opaque, keepContents: false,
                       uniforms: uniforms, source0: occlusionRaw, source1: nil, sampler0: nil)
    }

    // MARK: - 4. The main pass

    func renderScene(_ commandBuffer: MTLCommandBuffer, scene: Scene, opaque: [Batch], transparent: [Batch], view: View,
                     passUniforms: FrameAllocator.Allocation, frameUniforms: FrameAllocator.Allocation,
                     lights: FrameAllocator.Allocation) {
        guard let sceneColor = sceneColor, let sceneDepth = sceneDepth, let shadowMap = shadowMap else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if targetSamples > 1, let multisample = sceneColorMultisample {
            // Draw into the multisampled texture; at the end of the pass the GPU averages
            // the samples of each pixel into the plain texture ("resolve"). Only that is kept.
            pass.colorAttachments[0].texture = multisample
            pass.colorAttachments[0].resolveTexture = sceneColor
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = sceneColor
            pass.colorAttachments[0].storeAction = .store
        }
        pass.depthAttachment.texture = sceneDepth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare               // nobody reads it after this pass

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Scene"
        encoder.setFrontFacing(.counterClockwise)

        // What every draw of this pass shares is bound once.
        encoder.setVertexBuffer(passUniforms.buffer, offset: passUniforms.offset, index: BufferIndex.pass)
        encoder.setFragmentBuffer(passUniforms.buffer, offset: passUniforms.offset, index: BufferIndex.pass)
        encoder.setFragmentBuffer(frameUniforms.buffer, offset: frameUniforms.offset, index: BufferIndex.frame)
        encoder.setFragmentBuffer(lights.buffer, offset: lights.offset, index: BufferIndex.lights)
        encoder.setFragmentTexture(shadowMap, index: TextureIndex.shadowMap)
        encoder.setFragmentTexture(environment.irradianceMap, index: TextureIndex.irradiance)
        encoder.setFragmentTexture(environment.prefilteredMap, index: TextureIndex.prefiltered)
        encoder.setFragmentTexture(environment.brdfLUT, index: TextureIndex.brdf)
        encoder.setFragmentTexture(settings.ambientOcclusionEnabled ? (occlusion ?? white.handle) : white.handle,
                                   index: TextureIndex.ambientOcclusion)
        encoder.setFragmentSamplerState(device.materialSampler, index: SamplerIndex.material)
        encoder.setFragmentSamplerState(device.shadowSampler, index: SamplerIndex.shadow)
        encoder.setFragmentSamplerState(device.linearClampSampler, index: SamplerIndex.linearClamp)

        // Opaque objects, writing depth.
        encoder.pushDebugGroup("Opaque")
        encoder.setDepthStencilState(device.depthWrite)
        drawBatches(encoder, opaque, pass: .forward, colorFormat: Renderer.sceneFormat, sampleCount: targetSamples)
        encoder.popDebugGroup()

        // The sky, only where nothing was drawn. From here on nothing writes depth.
        encoder.setDepthStencilState(device.depthReadOnly)
        var sky = PipelineDescription()
        sky.vertexFunction = "vertex_sky"
        sky.fragmentFunction = "fragment_sky"
        sky.colorFormat = Renderer.sceneFormat
        sky.depthFormat = Renderer.depthFormat
        sky.sampleCount = targetSamples
        if let pipeline = shaders.pipeline(sky) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            stats.drawCalls += 1
        }

        // Transparent objects, already sorted from far to near.
        encoder.pushDebugGroup("Transparent")
        drawBatches(encoder, transparent, pass: .forward, colorFormat: Renderer.sceneFormat, sampleCount: targetSamples)
        encoder.popDebugGroup()

        drawParticles(encoder, scene: scene, view: view)
        drawDebugLines(encoder)
        encoder.endEncoding()
    }

    func drawParticles(_ encoder: MTLRenderCommandEncoder, scene: Scene, view: View) {
        var instances: [ParticleInstance] = []
        scene.each(ParticleEmitter.self) { _, emitter in
            if emitter.particles.isEmpty { return }
            instances.removeAll(keepingCapacity: true)
            for particle in emitter.particles {
                let t = saturate(particle.age / particle.lifetime)
                let size = lerp(emitter.sizeStart, emitter.sizeEnd, t)
                let color = emitter.colorStart + (emitter.colorEnd - emitter.colorStart) * t
                instances.append(ParticleInstance(positionAndSize: Vec4(particle.position, size), color: color))
            }
            if !emitter.isAdditive {
                // Ordinary blending depends on the order: far particles first.
                instances.sort { a, b in
                    simd_distance_squared(xyz(a.positionAndSize), view.position) > simd_distance_squared(xyz(b.positionAndSize), view.position)
                }
            }

            var description = PipelineDescription()
            description.vertexFunction = "vertex_particle"
            description.fragmentFunction = "fragment_particle"
            description.colorFormat = Renderer.sceneFormat
            description.depthFormat = Renderer.depthFormat
            description.sampleCount = targetSamples
            description.blend = emitter.isAdditive ? .additive : .alphaBlend
            guard let pipeline = shaders.pipeline(description) else { return }

            let buffer = allocator.copyArray(instances)
            encoder.setRenderPipelineState(pipeline)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: BufferIndex.instances)
            // One instance per particle; the four vertices of the square come from the vertex index.
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
            stats.drawCalls += 1
        }
    }

    func drawDebugLines(_ encoder: MTLRenderCommandEncoder) {
        let vertices = debug.vertices
        if vertices.isEmpty { return }

        var description = PipelineDescription()
        description.vertexFunction = "vertex_line"
        description.fragmentFunction = "fragment_line"
        description.colorFormat = Renderer.sceneFormat
        description.depthFormat = Renderer.depthFormat
        description.sampleCount = targetSamples
        description.blend = .alphaBlend
        guard let pipeline = shaders.pipeline(description) else { return }

        let buffer = allocator.copyArray(vertices)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: BufferIndex.vertices)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
        stats.drawCalls += 1
    }

    // MARK: - 5. Bloom

    func renderBloom(_ commandBuffer: MTLCommandBuffer) {
        guard settings.bloomEnabled, !bloom.isEmpty, let sceneColor = sceneColor else { return }

        var uniforms = PostUniforms()
        uniforms.bloomThreshold = settings.bloomThreshold
        uniforms.bloomKnee = settings.bloomKnee
        uniforms.filterRadius = 1

        // The bright parts of the scene, at half size.
        uniforms.sourceTexelSize = texelSize(sceneColor)
        drawFullscreen(commandBuffer, target: bloom[0], fragmentFunction: "fragment_bloom_prefilter", blend: .opaque, keepContents: false,
                       uniforms: uniforms, source0: sceneColor, source1: nil, sampler0: nil)

        // Down the chain: each level is a blurred, half-size copy of the one before.
        for i in 1..<bloom.count {
            uniforms.sourceTexelSize = texelSize(bloom[i - 1])
            drawFullscreen(commandBuffer, target: bloom[i], fragmentFunction: "fragment_bloom_downsample", blend: .opaque,
                           keepContents: false, uniforms: uniforms, source0: bloom[i - 1], source1: nil, sampler0: nil)
        }
        // And back up: each level is added onto the larger one. Level 0 ends up holding the sum.
        for i in stride(from: bloom.count - 1, to: 0, by: -1) {
            uniforms.sourceTexelSize = texelSize(bloom[i])
            drawFullscreen(commandBuffer, target: bloom[i - 1], fragmentFunction: "fragment_bloom_upsample", blend: .additive,
                           keepContents: true, uniforms: uniforms, source0: bloom[i], source1: nil, sampler0: nil)
        }
    }

    // MARK: - 6. The final pass

    func renderFinal(_ commandBuffer: MTLCommandBuffer, canvas: Canvas, target: RenderTarget) {
        guard let sceneColor = sceneColor else { return }
        let hasBloom = settings.bloomEnabled && !bloom.isEmpty
        var uniforms = PostUniforms()
        uniforms.exposure = settings.exposure
        uniforms.bloomIntensity = hasBloom ? settings.bloomIntensity : 0
        uniforms.vignette = settings.vignette
        uniforms.toneMapper = UInt32(settings.toneMapper)
        uniforms.lensDistortion = settings.lensDistortion
        uniforms.chromaticAberration = settings.chromaticAberration
        uniforms.grain = settings.filmGrain
        uniforms.interference = settings.interference
        uniforms.time = Float(frameTime)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        pass.colorAttachments[0].loadAction = .dontCare            // the first draw covers every pixel
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Tone mapping and canvas"

        // From HDR to what a screen can show. The scene texture may be smaller or larger
        // than the target (renderScale); the sampler stretches it.
        var description = PipelineDescription()
        description.vertexFunction = "vertex_fullscreen"
        description.fragmentFunction = "fragment_tonemap"
        description.colorFormat = target.texture.pixelFormat
        if let pipeline = shaders.pipeline(description) {
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PostUniforms>.stride, index: BufferIndex.pass)
            encoder.setFragmentTexture(sceneColor, index: 0)
            encoder.setFragmentTexture(hasBloom ? bloom[0] : white.handle, index: 1)
            encoder.setFragmentSamplerState(device.linearClampSampler, index: SamplerIndex.linearClamp)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            stats.drawCalls += 1
        }

        // The 2D canvas goes on top, after tone mapping: interface colors must not be tone mapped.
        drawCanvas(encoder, canvas: canvas, target: target.texture)
        encoder.endEncoding()
    }

    func drawCanvas(_ encoder: MTLRenderCommandEncoder, canvas: Canvas, target: MTLTexture) {
        let vertices = canvas.vertices
        let size = canvas.size
        if vertices.isEmpty || size.x <= 0 || size.y <= 0 { return }

        var uniforms = CanvasUniforms()
        uniforms.projection = Mat4.orthographic(left: 0, right: size.x, bottom: size.y, top: 0, near: -1, far: 1)   // points, y down
        uniforms.distanceRange = canvas.fontDistanceRange

        let buffer = allocator.copyArray(vertices)
        encoder.setVertexBuffer(buffer.buffer, offset: buffer.offset, index: BufferIndex.vertices)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: BufferIndex.pass)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: BufferIndex.pass)
        encoder.setFragmentSamplerState(device.linearClampSampler, index: 0)

        // Clips are given in points; the scissor rectangle that enforces them is in pixels and
        // must stay inside the target, or Metal stops the program.
        let width = target.width, height = target.height
        let pixelsPerPoint = Vec2(Float(width) / size.x, Float(height) / size.y)

        for batch in canvas.batches where batch.vertexCount > 0 {
            var scissor = MTLScissorRect(x: 0, y: 0, width: width, height: height)
            if batch.isClipped {
                let x0 = min(max(Int((batch.clipMin.x * pixelsPerPoint.x).rounded()), 0), width)
                let y0 = min(max(Int((batch.clipMin.y * pixelsPerPoint.y).rounded()), 0), height)
                let x1 = min(max(Int((batch.clipMax.x * pixelsPerPoint.x).rounded()), 0), width)
                let y1 = min(max(Int((batch.clipMax.y * pixelsPerPoint.y).rounded()), 0), height)
                if x1 <= x0 || y1 <= y0 { continue }
                scissor = MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            }
            encoder.setScissorRect(scissor)
            var description = PipelineDescription()
            description.vertexFunction = "vertex_canvas"
            description.fragmentFunction = batch.isText ? "fragment_canvas_text" : "fragment_canvas"
            description.colorFormat = target.pixelFormat
            description.blend = .alphaBlend
            guard let pipeline = shaders.pipeline(description) else { continue }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture((batch.texture ?? white).handle, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: batch.firstVertex, vertexCount: batch.vertexCount)
            stats.drawCalls += 1
        }
    }

    // MARK: - Helper

    /// One full-screen triangle into `target`, running `fragmentFunction` for every pixel.
    func drawFullscreen<Uniforms>(_ commandBuffer: MTLCommandBuffer, target: MTLTexture, fragmentFunction: String, blend: BlendMode,
                                  keepContents: Bool, uniforms: Uniforms, source0: MTLTexture?, source1: MTLTexture?,
                                  sampler0: MTLSamplerState?) {
        var description = PipelineDescription()
        description.vertexFunction = "vertex_fullscreen"
        description.fragmentFunction = fragmentFunction
        description.colorFormat = target.pixelFormat
        description.blend = blend
        guard let pipeline = shaders.pipeline(description) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = keepContents ? .load : .dontCare
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = fragmentFunction
        encoder.setRenderPipelineState(pipeline)
        var uniformsCopy = uniforms
        encoder.setFragmentBytes(&uniformsCopy, length: MemoryLayout<Uniforms>.stride, index: BufferIndex.pass)
        if let source0 = source0 { encoder.setFragmentTexture(source0, index: 0) }
        if let source1 = source1 { encoder.setFragmentTexture(source1, index: 1) }
        if let sampler0 = sampler0 { encoder.setFragmentSamplerState(sampler0, index: 0) }
        encoder.setFragmentSamplerState(device.linearClampSampler, index: SamplerIndex.linearClamp)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        stats.drawCalls += 1
    }
}
