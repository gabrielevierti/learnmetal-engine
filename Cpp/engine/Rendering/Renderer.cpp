#include "Rendering/Renderer.hpp"

#include "Core/Log.hpp"
#include "Scene/Components.hpp"

#include <algorithm>
#include <functional>

namespace lm {

Renderer::Renderer(GraphicsDevice& device, const std::string& shaderDirectory)
    : device_(device), shaders_(device.device(), shaderDirectory), environment_(device, shaders_) {
    frameSemaphore_ = dispatch_semaphore_create(kFramesInFlight);
    for (FrameAllocator& allocator : allocators_) allocator.initialize(device.device(), 1 << 20);
    white_ = Texture::solidColor(device, Vec4{1, 1, 1, 1});
    flatNormal_ = Texture::solidColor(device, Vec4{0.5f, 0.5f, 1.0f, 1.0f});
}

Renderer::~Renderer() {
    // Take every frame slot: once we hold them all, the GPU has finished every frame.
    // Then give them back, because a semaphore must not be destroyed below its initial count.
    for (int i = 0; i < kFramesInFlight; i++) dispatch_semaphore_wait(frameSemaphore_, DISPATCH_TIME_FOREVER);
    for (int i = 0; i < kFramesInFlight; i++) dispatch_semaphore_signal(frameSemaphore_);
    dispatch_release(frameSemaphore_);
}

void Renderer::waitUntilIdle() {
    // Command buffers of one queue run in order: when this empty one is done, so is everything before it.
    MTL::CommandBuffer* commandBuffer = device_.queue()->commandBuffer();
    commandBuffer->commit();
    commandBuffer->waitUntilCompleted();
}

std::vector<uint8_t> Renderer::renderToImage(Scene& scene, const Canvas& canvas, int width, int height, double time) {
    width = std::max(width, 1);
    height = std::max(height, 1);
    if (!imageTarget_ || int(imageTarget_->width()) != width || int(imageTarget_->height()) != height) {
        imageTarget_ = device_.makeRenderTarget(MTL::PixelFormatBGRA8Unorm_sRGB, width, height);
    }
    RenderTarget target;
    target.texture = imageTarget_.get();
    render(scene, canvas, target, time);

    // The texture lives in GPU memory. A blit pass copies it into a buffer the CPU can
    // read, and then we wait: the copy has only happened once the GPU says so.
    size_t bytesPerRow = size_t(width) * 4;
    auto buffer = NS::TransferPtr(device_.device()->newBuffer(bytesPerRow * size_t(height), MTL::ResourceStorageModeShared));
    MTL::CommandBuffer* commandBuffer = device_.queue()->commandBuffer();
    MTL::BlitCommandEncoder* blit = commandBuffer->blitCommandEncoder();
    blit->copyFromTexture(imageTarget_.get(), 0, 0, MTL::Origin(0, 0, 0), MTL::Size(NS::UInteger(width), NS::UInteger(height), 1),
                          buffer.get(), 0, bytesPerRow, bytesPerRow * size_t(height));
    blit->endEncoding();
    commandBuffer->commit();
    commandBuffer->waitUntilCompleted();

    // The texture stores blue first; image files want red first.
    std::vector<uint8_t> pixels(bytesPerRow * size_t(height));
    const uint8_t* source = static_cast<const uint8_t*>(buffer->contents());
    for (size_t i = 0; i < pixels.size(); i += 4) {
        pixels[i] = source[i + 2];
        pixels[i + 1] = source[i + 1];
        pixels[i + 2] = source[i];
        pixels[i + 3] = 255;
    }
    return pixels;
}

// ---------------------------------------------------------------- render targets

void Renderer::ensureTargets(int width, int height) {
    int samples = std::clamp(settings.sampleCount, 1, 4);
    if (samples == 3) samples = 2;
    if (!device_.device()->supportsTextureSampleCount(NS::UInteger(samples))) samples = 1;
    bool wantOcclusion = settings.ambientOcclusionEnabled;
    if (width == targetWidth_ && height == targetHeight_ && samples == targetSamples_ && wantOcclusion == targetHasOcclusion_) return;
    targetWidth_ = width;
    targetHeight_ = height;
    targetSamples_ = samples;
    targetHasOcclusion_ = wantOcclusion;

    // The scene is drawn in HDR. With multisampling, the multisampled color and the depth
    // are only needed while the pass runs, so on Apple GPUs they take no memory at all.
    sceneColor_ = device_.makeRenderTarget(kSceneFormat, width, height);
    sceneColorMultisample_ = samples > 1 ? device_.makeRenderTarget(kSceneFormat, width, height, samples, true)
                                         : NS::SharedPtr<MTL::Texture>();
    sceneDepth_ = device_.makeRenderTarget(kDepthFormat, width, height, samples, true);

    if (wantOcclusion) {
        prepassDepth_ = device_.makeRenderTarget(kDepthFormat, width, height);
        prepassNormal_ = device_.makeRenderTarget(MTL::PixelFormatRGBA8Unorm, width, height);
        occlusionRaw_ = device_.makeRenderTarget(MTL::PixelFormatR8Unorm, width, height);
        occlusion_ = device_.makeRenderTarget(MTL::PixelFormatR8Unorm, width, height);
    } else {
        prepassDepth_ = prepassNormal_ = occlusionRaw_ = occlusion_ = NS::SharedPtr<MTL::Texture>();
    }

    // The bloom chain: half size, quarter size, and so on.
    bloom_.clear();
    int w = width / 2, h = height / 2;
    while (bloom_.size() < 6 && w >= 8 && h >= 8) {
        bloom_.push_back(device_.makeRenderTarget(kSceneFormat, w, h));
        w /= 2;
        h /= 2;
    }
}

void Renderer::ensureShadowMap() {
    // With shadows off, a single texel keeps the shader's texture argument bound.
    int size = settings.shadowsEnabled ? std::max(settings.cascades.resolution, 16) : 1;
    int slices = settings.shadowsEnabled ? std::clamp(settings.cascades.count, 1, kMaxCascades) : 1;
    if (size == shadowMapSize_ && slices == shadowMapSlices_) return;
    shadowMapSize_ = size;
    shadowMapSlices_ = slices;

    auto descriptor = NS::TransferPtr(MTL::TextureDescriptor::alloc()->init());
    descriptor->setTextureType(MTL::TextureType2DArray);
    descriptor->setPixelFormat(kDepthFormat);
    descriptor->setWidth(NS::UInteger(size));
    descriptor->setHeight(NS::UInteger(size));
    descriptor->setArrayLength(NS::UInteger(slices));
    descriptor->setUsage(MTL::TextureUsageRenderTarget | MTL::TextureUsageShaderRead);
    descriptor->setStorageMode(MTL::StorageModePrivate);
    shadowMap_ = NS::TransferPtr(device_.device()->newTexture(descriptor.get()));
}

// ---------------------------------------------------------------- extraction

Renderer::View Renderer::findView(Scene& scene, float aspect) const {
    View view;
    view.aspect = aspect;
    bool found = false;
    bool hasOverride = scene.has<Camera>(cameraOverride) && scene.has<Transform>(cameraOverride);
    scene.each<Camera, Transform>([&](Entity entity, Camera& camera, Transform& transform) {
        if (found || (hasOverride ? entity != cameraOverride : !camera.isActive)) return;
        found = true;
        view.world = transform.world;
        view.fovY = camera.fovY;
        view.nearPlane = camera.nearPlane;
        view.farPlane = camera.farPlane;
        view.projection = camera.projection(aspect);
    });
    if (!found) {
        // No camera in the scene: look at the origin from a little above.
        view.world = simd::inverse(lookAt(Vec3{0, 2, 6}, Vec3{0, 0, 0}));
        view.projection = perspective(view.fovY, aspect, view.nearPlane, view.farPlane);
    }
    view.view = simd::inverse(view.world);
    view.viewProjection = view.projection * view.view;
    view.position = xyz(view.world.columns[3]);
    return view;
}

void Renderer::collectItems(Scene& scene, const View& view, std::vector<DrawItem>& items) const {
    scene.each<MeshRenderer, Transform>([&](Entity, MeshRenderer& renderer, Transform& transform) {
        if (!renderer.isVisible || !renderer.mesh) return;
        DrawItem item;
        item.mesh = renderer.mesh.get();
        item.material = renderer.material ? renderer.material.get() : &defaultMaterial_;
        item.world = transform.world;
        item.tint = renderer.tint;
        item.bounds = renderer.mesh->bounds().transformed(transform.world);
        item.distanceSquared = simd::length_squared(item.bounds.center() - view.position);
        item.castsShadows = renderer.castsShadows;
        items.push_back(item);
    });
}

int Renderer::collectLights(Scene& scene, gpu::LightData* lights, gpu::FrameUniforms& frame, bool& sunCastsShadows) const {
    bool hasSun = false;
    gpu::LightData sun{};
    std::vector<gpu::LightData> others;
    sunCastsShadows = false;

    scene.each<Light, Transform>([&](Entity, Light& light, Transform& transform) {
        gpu::LightData data{};
        data.position = transform.worldPosition();
        data.range = std::max(light.range, 0.001f);
        data.direction = safeNormalize(-xyz(transform.world.columns[2]), Vec3{0, -1, 0});     // the entity's -Z axis
        data.type = uint32_t(light.type);
        data.color = light.color * light.intensity;
        float cosInner = std::cos(light.innerConeAngle);
        float cosOuter = std::cos(std::max(light.outerConeAngle, light.innerConeAngle + 0.001f));
        data.spotScale = 1.0f / (cosInner - cosOuter);
        data.spotOffset = -cosOuter * data.spotScale;

        // The first directional light is the sun: it lights the sky and may cast shadows.
        if (light.type == LightType::Directional && !hasSun) {
            hasSun = true;
            sun = data;
            sunCastsShadows = light.castsShadows;
        } else {
            others.push_back(data);
        }
    });

    int count = 0;
    if (hasSun) {
        lights[count++] = sun;                  // the shaders expect the sun first
        frame.sunDirection = sun.direction;
        frame.sunColor = sun.color;
    } else {
        frame.sunDirection = Vec3{0, -1, 0};
        frame.sunColor = Vec3{0, 0, 0};
    }
    for (const gpu::LightData& light : others) {
        if (count >= gpu::LMMaxLights) {
            logWarning("more than %d lights in the scene; the rest are ignored", int(gpu::LMMaxLights));
            break;
        }
        lights[count++] = light;
    }
    return count;
}

std::vector<Renderer::Batch> Renderer::makeBatches(std::vector<const DrawItem*>& items, bool sortByState) {
    if (sortByState) {
        // Objects that share a material and a mesh end up next to each other.
        std::sort(items.begin(), items.end(), [](const DrawItem* a, const DrawItem* b) {
            if (a->material != b->material) return std::less<const Material*>()(a->material, b->material);
            return std::less<const Mesh*>()(a->mesh, b->mesh);
        });
    }
    std::vector<Batch> batches;
    std::vector<gpu::InstanceData> instances;
    size_t first = 0;
    while (first < items.size()) {
        // Every run of the same mesh and material becomes one instanced draw.
        instances.clear();
        size_t next = first;
        while (next < items.size() && items[next]->mesh == items[first]->mesh && items[next]->material == items[first]->material) {
            instances.push_back(gpu::InstanceData{items[next]->world, normalMatrix(items[next]->world), items[next]->tint});
            next++;
        }
        Batch batch;
        batch.mesh = items[first]->mesh;
        batch.material = items[first]->material;
        batch.instances = allocator().copyArray(instances.data(), instances.size());
        batch.count = uint32_t(instances.size());
        batches.push_back(batch);
        first = next;
    }
    return batches;
}

gpu::PassUniforms Renderer::makePassUniforms(const Mat4& view, const Mat4& projection, Vec3 position, int width, int height,
                                             float nearPlane, float farPlane, double time) const {
    gpu::PassUniforms uniforms{};
    uniforms.view = view;
    uniforms.projection = projection;
    uniforms.viewProjection = projection * view;
    uniforms.inverseViewProjection = simd::inverse(uniforms.viewProjection);
    uniforms.inverseProjection = simd::inverse(projection);
    uniforms.cameraPosition = position;
    uniforms.time = float(time);
    uniforms.viewportSize = Vec2{float(width), float(height)};
    uniforms.nearPlane = nearPlane;
    uniforms.farPlane = farPlane;
    return uniforms;
}

// ---------------------------------------------------------------- the frame

void Renderer::render(Scene& scene, const Canvas& canvas, const RenderTarget& target, double time) {
    if (!target.texture) return;

    // At most three frames may be waiting for the GPU. If it is behind, wait here.
    dispatch_semaphore_wait(frameSemaphore_, DISPATCH_TIME_FOREVER);
    frameIndex_ = (frameIndex_ + 1) % kFramesInFlight;
    allocator().reset();
    frameNumber_++;
    stats = RenderStats{};

    if (frameNumber_ % 30 == 0 && shaders_.reloadIfChanged()) environment_.invalidate();

    int width = std::max(1, int(float(target.texture->width()) * settings.renderScale));
    int height = std::max(1, int(float(target.texture->height()) * settings.renderScale));
    ensureTargets(width, height);
    ensureShadowMap();

    // ---- what is in the scene
    View view = findView(scene, float(width) / float(height));
    std::vector<DrawItem> items;
    collectItems(scene, view, items);

    gpu::FrameUniforms frame{};
    gpu::LightData lights[gpu::LMMaxLights];
    bool sunCastsShadows = false;
    int lightCount = collectLights(scene, lights, frame, sunCastsShadows);
    frame.lightCount = uint32_t(lightCount);
    stats.lights = lightCount;

    Cascades cascades;
    if (settings.shadowsEnabled && sunCastsShadows) {
        cascades = computeCascades(view.world, view.fovY, view.aspect, view.nearPlane, frame.sunDirection, settings.cascades);
        frame.cascadeCount = uint32_t(cascades.count);
        for (int i = 0; i < cascades.count; i++) {
            frame.cascadeViewProjection[i] = cascades.viewProjection[i];
            frame.cascadeSplits[i] = cascades.splitFar[i];
            frame.cascadeTexelSize[i] = 2.0f * cascades.radius[i] / float(settings.cascades.resolution);
        }
    }
    frame.shadowBias = settings.shadowBias;
    frame.shadowNormalOffset = settings.shadowNormalOffset;
    frame.shadowMapSize = float(shadowMapSize_);
    frame.shadowDistance = settings.cascades.shadowDistance;
    frame.environmentIntensity = settings.environmentIntensity;
    frame.prefilteredMipCount = environment_.prefilteredMipCount();
    frame.ambientOcclusionStrength = settings.ambientOcclusionEnabled ? 1.0f : 0.0f;
    frame.skyZenithColor = settings.sky.zenithColor;
    frame.skyHorizonColor = settings.sky.horizonColor;
    frame.skyGroundColor = settings.sky.groundColor;
    frame.skyIntensity = settings.sky.intensity;
    frame.sunDiskIntensity = settings.sky.sunDiskIntensity;
    frame.sunDiskSize = std::cos(settings.sky.sunAngularRadius);
    frame.fogColor = settings.fogColor;
    frame.fogDensity = settings.fogDensity;
    frame.cloudCoverage = settings.sky.cloudCoverage;
    frame.cloudScale = settings.sky.cloudScale;
    frame.cloudOffset = settings.sky.cloudSpeed * float(time);
    time_ = time;

    // ---- what the camera can see, in the order it will be drawn
    Frustum frustum(view.viewProjection);
    std::vector<const DrawItem*> opaqueItems, transparentItems;
    for (const DrawItem& item : items) {
        if (!frustum.intersects(item.bounds)) {
            stats.culledObjects++;
            continue;
        }
        stats.visibleObjects++;
        (item.material->alphaMode == AlphaMode::Blend ? transparentItems : opaqueItems).push_back(&item);
    }
    // Transparent surfaces must be blended from the farthest to the nearest.
    std::sort(transparentItems.begin(), transparentItems.end(),
              [](const DrawItem* a, const DrawItem* b) { return a->distanceSquared > b->distanceSquared; });
    std::vector<Batch> opaque = makeBatches(opaqueItems, true);
    std::vector<Batch> transparent = makeBatches(transparentItems, false);

    FrameAllocator::Allocation passUniforms = allocator().copy(
        makePassUniforms(view.view, view.projection, view.position, width, height, view.nearPlane, view.farPlane, time));
    FrameAllocator::Allocation frameUniforms = allocator().copy(frame);
    FrameAllocator::Allocation lightBuffer = allocator().copyArray(lights, size_t(lightCount));

    // ---- the passes
    MTL::CommandBuffer* commandBuffer = device_.queue()->commandBuffer();
    environment_.updateIfNeeded(commandBuffer, frame);
    if (frame.cascadeCount > 0) renderShadows(commandBuffer, items, cascades);
    if (settings.ambientOcclusionEnabled) renderOcclusion(commandBuffer, opaque, view, passUniforms);
    renderScene(commandBuffer, scene, opaque, transparent, view, passUniforms, frameUniforms, lightBuffer);
    renderBloom(commandBuffer);
    renderFinal(commandBuffer, canvas, target);
    debug.clear();

    if (target.drawable) commandBuffer->presentDrawable(target.drawable);
    dispatch_semaphore_t semaphore = frameSemaphore_;
    commandBuffer->addCompletedHandler([semaphore](MTL::CommandBuffer*) { dispatch_semaphore_signal(semaphore); });
    commandBuffer->commit();
}

}  // namespace lm
