import XCTest
import ShaderTypes
import simd
@testable import LMEngine

private let testFont = """
info 40 50 8 256 256
65 0 0 30 40 -2 4 24
66 32 0 28 40 0 4 22
32 0 0 0 0 0 0 10
63 64 0 20 40 0 4 18
232 96 0 22 40 0 4 20
"""

final class RenderingMathTests: XCTestCase {
    // MARK: Shared GPU layouts

    func testGPUStructsHaveTheSizesTheShadersExpect() {
        // Sizes and offsets under the C layout rules, which the Metal Shading Language shares
        // for these types (a float3 is 16 bytes, aligned to 16). The C++ tests check the
        // same numbers. If a field is added to ShaderTypes.h, update them on purpose.
        XCTAssertEqual(MemoryLayout<PassUniforms>.stride, 368)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.stride, 512)
        XCTAssertEqual(MemoryLayout<InstanceData>.stride, 144)
        XCTAssertEqual(MemoryLayout<LightData>.stride, 96)
        XCTAssertEqual(MemoryLayout<MaterialUniforms>.stride, 64)
        XCTAssertEqual(MemoryLayout<CanvasVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<LineVertex>.stride, 32)
        XCTAssertEqual(MemoryLayout<ParticleInstance>.stride, 32)
        XCTAssertEqual(MemoryLayout<PassUniforms>.offset(of: \.cameraPosition), 320)
        XCTAssertEqual(MemoryLayout<PassUniforms>.offset(of: \.time), 336)
        XCTAssertEqual(MemoryLayout<LightData>.offset(of: \.type), 48)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \.cascadeSplits), 256)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \.lightCount), 352)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \.fogDensity), 480)
    }

    // MARK: Cascaded shadows

    func testEachCascadeContainsItsSliceOfTheView() {
        let cameraWorld = Mat4.lookAt(eye: Vec3(3, 5, 8), target: Vec3(0, 0, 0)).inverse
        let fovY = radians(60), aspect: Float = 16.0 / 9.0, nearPlane: Float = 0.1
        let settings = CascadeSettings()
        let lightDirection = simd_normalize(Vec3(-0.4, -1.0, -0.3))
        let cascades = computeCascades(cameraWorld: cameraWorld, fovY: fovY, aspect: aspect, nearPlane: nearPlane,
                                       lightDirection: lightDirection, settings: settings)
        XCTAssertEqual(cascades.count, 4)
        XCTAssertEqual(cascades.splitFar[3], settings.shadowDistance, accuracy: 1e-3)
        var previousFar = nearPlane
        for i in 0..<cascades.count {
            XCTAssertGreaterThan(cascades.splitFar[i], previousFar)
            // Every corner of the slice must land inside the cascade's clip volume.
            for distance in [previousFar, cascades.splitFar[i]] {
                for sx in [Float(-1), Float(1)] {
                    for sy in [Float(-1), Float(1)] {
                        let corner = cameraWorld.transformPoint(Vec3(sx * tan(fovY / 2) * aspect * distance, sy * tan(fovY / 2) * distance, -distance))
                        let clip = cascades.viewProjection[i].transformPoint(corner)
                        XCTAssertTrue(abs(clip.x) <= 1.001 && abs(clip.y) <= 1.001)
                        XCTAssertTrue(clip.z >= 0 && clip.z <= 1)
                    }
                }
            }
            previousFar = cascades.splitFar[i]
        }
        // An object above the view, toward the light, is still inside the depth range.
        let above = cascades.viewProjection[0].transformPoint(-lightDirection * 40)
        XCTAssertTrue(above.z >= 0 && above.z <= 1)
    }

    func testCascadesMoveInWholeTexels() {
        // Shadows shimmer if the shadow map slides by a fraction of a texel as the camera moves.
        let settings = CascadeSettings()
        let lightDirection = simd_normalize(Vec3(0.3, -1.0, 0.2))
        let worldPoint = Vec3(1.234, 0, -2.345)
        func cascades(at offset: Vec3) -> Cascades {
            computeCascades(cameraWorld: Mat4.lookAt(eye: Vec3(0, 2, 5) + offset, target: offset).inverse, fovY: radians(60),
                            aspect: 1.5, nearPlane: 0.1, lightDirection: lightDirection, settings: settings)
        }
        let base = cascades(at: Vec3(0, 0, 0))
        for shift in [Float(0.013), Float(0.11), Float(0.37)] {
            let moved = cascades(at: Vec3(shift, 0, shift * 0.5))
            for i in 0..<base.count {
                XCTAssertEqual(base.radius[i], moved.radius[i], accuracy: 1e-5)
                let a = base.viewProjection[i].transformPoint(worldPoint), b = moved.viewProjection[i].transformPoint(worldPoint)
                let texelsX = (a.x - b.x) * 0.5 * Float(settings.resolution)
                let texelsY = (a.y - b.y) * 0.5 * Float(settings.resolution)
                XCTAssertEqual(texelsX, texelsX.rounded(), accuracy: 0.02)
                XCTAssertEqual(texelsY, texelsY.rounded(), accuracy: 0.02)
            }
        }
    }

    // MARK: Particles

    func testParticlesReachASteadyCountAndRespectTheCap() {
        let scene = Scene()
        let e = scene.create()
        scene.add(e, Transform(position: Vec3(1, 2, 3)))
        var emitter = ParticleEmitter()
        emitter.rate = 100
        emitter.lifetimeMin = 0.5
        emitter.lifetimeMax = 0.5
        scene.add(e, emitter)
        scene.updateTransforms()
        for _ in 0..<240 { updateParticles(scene, dt: 1.0 / 120.0) }
        let alive = scene[e, ParticleEmitter.self]!.particles.count
        XCTAssertTrue(alive >= 48 && alive <= 52)            // rate times lifetime

        scene[e, ParticleEmitter.self]?.maxParticles = 20
        scene[e, ParticleEmitter.self]?.burst(1000)
        updateParticles(scene, dt: 1.0 / 120.0)
        XCTAssertLessThanOrEqual(scene[e, ParticleEmitter.self]!.particles.count, 52)
        scene[e, ParticleEmitter.self]?.isEmitting = false
        for _ in 0..<120 { updateParticles(scene, dt: 1.0 / 120.0) }
        XCTAssertTrue(scene[e, ParticleEmitter.self]!.particles.isEmpty)
    }

    func testABurstStartsAtTheEmitterAndFliesAlongItsDirection() {
        let scene = Scene()
        let e = scene.create()
        // Local +Y becomes world +X.
        scene.add(e, Transform(position: Vec3(5, 0, 0), rotation: Quat(angle: radians(-90), axis: Vec3(0, 0, 1))))
        var emitter = ParticleEmitter()
        emitter.rate = 0
        emitter.spread = radians(10)
        emitter.gravity = Vec3(0, 0, 0)
        emitter.burst(50)
        scene.add(e, emitter)
        scene.updateTransforms()
        updateParticles(scene, dt: 0)
        let particles = scene[e, ParticleEmitter.self]!.particles
        XCTAssertEqual(particles.count, 50)
        for particle in particles {
            XCTAssertEqual(simd_distance(particle.position, Vec3(5, 0, 0)), 0, accuracy: 1e-4)
            XCTAssertGreaterThan(simd_normalize(particle.velocity).x, cos(radians(10.5)))
        }
    }

    // MARK: Sound synthesis

    func testSynthesizedClipsHaveTheRightLengthLevelAndPitch() {
        let clip = synthesize(SynthParams(frequency: 441, duration: 0.5, volume: 0.4), sampleRate: 44100)
        XCTAssertEqual(clip.samples.count, 22050)
        XCTAssertEqual(clip.duration, 0.5, accuracy: 1e-4)
        var peak: Float = 0
        var risingZeroCrossings = 0
        for i in 1..<clip.samples.count {
            peak = max(peak, abs(clip.samples[i]))
            if clip.samples[i - 1] < 0 && clip.samples[i] >= 0 { risingZeroCrossings += 1 }
        }
        XCTAssertTrue(peak <= 0.4 + 1e-4 && peak > 0.38)
        XCTAssertLessThanOrEqual(abs(risingZeroCrossings - 220), 2)     // 441 Hz for half a second
        XCTAssertEqual(clip.samples.first ?? 1, 0, accuracy: 1e-3)      // the envelope removes clicks at both ends
        XCTAssertEqual(clip.samples.last ?? 1, 0, accuracy: 1e-2)
    }

    func testNoiseIsRepeatableAndSequencesConcatenate() {
        let noise = SynthParams(waveform: .noise, seed: 9)
        XCTAssertEqual(synthesize(noise).samples, synthesize(noise).samples)
        let note = SynthParams(duration: 0.1)
        XCTAssertEqual(synthesizeSequence([note, note, note]).samples.count, 3 * synthesize(note).samples.count)
    }

    // MARK: Shader source

    func testShaderSourceResolvesIncludesOnceAndKeepsLineNumbers() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("lm_shader_test_\(UUID().uuidString)")
        try manager.createDirectory(at: root.appendingPathComponent("Shared"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("Shared/Types.h", "struct Shared { float x; };\n")
        try write("Common.metal", "#include \"Shared/Types.h\"\nfloat one() { return 1.0; }\n")
        try write("A.metal", "#include \"Common.metal\"\nfloat a() { return one(); }\n")
        try write("B.metal", "#include \"Common.metal\"\n#include \"Missing.metal\"\nfloat b() { return one(); }\n")
        try write("notes.txt", "not a shader\n")

        let source = ShaderSource.load(directory: root.path)
        func count(_ needle: String) -> Int { source.text.components(separatedBy: needle).count - 1 }
        XCTAssertEqual(count("struct Shared"), 1)                // included by two files, present once
        XCTAssertEqual(count("float one()"), 1)
        XCTAssertTrue(count("float a()") == 1 && count("float b()") == 1)
        XCTAssertEqual(count("not a shader"), 0)
        XCTAssertEqual(count("#line 2 \"A.metal\""), 1)          // after the include, line numbers continue
        XCTAssertEqual(source.files.count, 4)
        XCTAssertTrue(source.error.contains("B.metal:2"))
        XCTAssertFalse(ShaderSource.load(directory: root.appendingPathComponent("does-not-exist").path).error.isEmpty)
    }

    // MARK: Text and 2D

    func testFontMetricsParseAndMeasure() {
        guard let font = FontMetrics.parse(testFont) else { return XCTFail("the metrics are valid") }
        XCTAssertEqual(font.glyphs.count, 5)
        XCTAssertEqual(font.glyph(66)?.advance ?? 0, 22, accuracy: 1e-6)
        XCTAssertEqual(font.glyph(0x4E2D)?.advance, font.glyph(63)?.advance)     // unknown characters fall back to "?"
        let size = font.measure("AB A", size: 20)                // half the baked size
        XCTAssertEqual(size.x, (24 + 22 + 10 + 24) * 0.5, accuracy: 1e-4)
        XCTAssertEqual(size.y, 25, accuracy: 1e-4)
        XCTAssertEqual(font.measure("A\nAB", size: 40).x, 46, accuracy: 1e-4)
        XCTAssertEqual(font.measure("A\nAB", size: 40).y, 100, accuracy: 1e-4)
        XCTAssertEqual(font.measure("\u{E8}", size: 40).x, 20, accuracy: 1e-4)
        XCTAssertNil(FontMetrics.parse("garbage"))
    }

    func testCanvasBatchesAndLaysOutText() {
        let font = FontMetrics.parse(testFont)
        let canvas = Canvas()
        canvas.begin(size: Vec2(800, 600))
        canvas.rect(Vec2(10, 20), Vec2(100, 50), rgb(0xff0000))
        canvas.rect(Vec2(10, 80), Vec2(100, 50), rgb(0x00ff00))
        XCTAssertEqual(canvas.batches.count, 1)                  // two solid rectangles share a draw call
        XCTAssertEqual(canvas.vertices.count, 12)
        XCTAssertEqual(canvas.vertices[0].position.x, 10, accuracy: 1e-6)
        XCTAssertEqual(canvas.vertices[2].position.y, 70, accuracy: 1e-6)
        XCTAssertEqual(canvas.vertices[0].color.x, 1, accuracy: 1e-6)

        canvas.circle(center: Vec2(50, 50), radius: 10, rgb(0xffffff), segments: 8)
        XCTAssertEqual(canvas.batches.count, 1)
        XCTAssertEqual(canvas.vertices.count, 12 + 66)      // the circle: six triangles inside, and two per side for the soft edge
        XCTAssertEqual(canvas.measureText("AB", size: 40).x, 0, accuracy: 1e-6)      // no font set yet
        canvas.setFont(font, atlas: nil)
        XCTAssertEqual(canvas.measureText("AB", size: 40).x, 46, accuracy: 1e-4)

        canvas.begin(size: Vec2(800, 600))
        XCTAssertTrue(canvas.vertices.isEmpty && canvas.batches.isEmpty)
    }

    func testCanvasShapesFadeOutOverOnePixel() {
        let canvas = Canvas()
        canvas.begin(size: Vec2(800, 600), pixelsPerPoint: 2)       // a Retina display: one pixel is half a point
        XCTAssertEqual(canvas.pixelSize, 0.5, accuracy: 1e-6)
        canvas.roundedRect(Vec2(100, 100), Vec2(200, 80), radius: 12, Vec4(1, 0, 0, 0.8))
        XCTAssertEqual(canvas.batches.count, 1)
        XCTAssertEqual(canvas.vertices.count % 3, 0)
        var solid = 0, clear = 0
        for v in canvas.vertices {
            // Nothing is drawn more than half a pixel outside the rectangle asked for.
            XCTAssertTrue(v.position.x >= 100 - 0.26 && v.position.x <= 300 + 0.26)
            XCTAssertTrue(v.position.y >= 100 - 0.26 && v.position.y <= 180 + 0.26)
            if v.color.w == 0 {
                clear += 1
            } else {
                solid += 1
                XCTAssertEqual(v.color.w, 0.8, accuracy: 1e-6)
            }
        }
        XCTAssertTrue(solid > 0 && clear > 0)

        // A circle touches its radius on all four sides.
        canvas.begin(size: Vec2(800, 600))
        canvas.circle(center: Vec2(50, 50), radius: 20, Vec4(1, 1, 1, 1))
        let xs = canvas.vertices.map { $0.position.x }
        XCTAssertEqual(xs.min() ?? 0, 29.5, accuracy: 0.2)
        XCTAssertEqual(xs.max() ?? 0, 70.5, accuracy: 0.2)
    }

    func testALineThinnerThanAPixelIsDrawnFainter() {
        let canvas = Canvas()
        canvas.begin(size: Vec2(800, 600))
        canvas.line(from: Vec2(10, 10), to: Vec2(110, 10), thickness: 0.25, Vec4(1, 1, 1, 1))
        XCTAssertFalse(canvas.vertices.isEmpty)
        let strongest = canvas.vertices.map { $0.color.w }.max() ?? 0
        let ys = canvas.vertices.map { $0.position.y }
        XCTAssertEqual(strongest, 0.25, accuracy: 1e-5)
        XCTAssertEqual((ys.max() ?? 0) - (ys.min() ?? 0), 2, accuracy: 1e-4)       // one pixel, fading on both sides
    }

    func testCanvasClipsNestAndSplitDrawCalls() {
        let canvas = Canvas()
        let white = Vec4(1, 1, 1, 1)
        canvas.begin(size: Vec2(800, 600))
        canvas.rect(Vec2(0, 0), Vec2(10, 10), white)
        canvas.pushClip(Vec2(100, 100), Vec2(200, 200))
        canvas.rect(Vec2(0, 0), Vec2(10, 10), white)
        canvas.pushClip(Vec2(250, 50), Vec2(200, 100))          // sticks out of the first one
        canvas.rect(Vec2(0, 0), Vec2(10, 10), white)
        canvas.pushClip(Vec2(0, 0), Vec2(50, 50))               // entirely outside: nothing can be drawn
        canvas.rect(Vec2(0, 0), Vec2(10, 10), white)
        canvas.circle(center: Vec2(5, 5), radius: 4, white)
        canvas.popClip()
        canvas.popClip()
        canvas.popClip()
        canvas.rect(Vec2(0, 0), Vec2(10, 10), white)
        canvas.popClip()                                        // one too many: harmless

        XCTAssertEqual(canvas.batches.count, 4)
        XCTAssertTrue(!canvas.batches[0].isClipped && canvas.batches[1].isClipped && !canvas.batches[3].isClipped)
        XCTAssertEqual(canvas.batches[2].clipMin, Vec2(250, 100))
        XCTAssertEqual(canvas.batches[2].clipMax, Vec2(300, 150))
        XCTAssertEqual(canvas.vertices.count, 4 * 6)
    }

    func testDebugDrawBuildsLineLists() {
        let debug = DebugDraw()
        debug.box(AABB(min: Vec3(-1, -1, -1), max: Vec3(1, 1, 1)), Vec4(1, 1, 1, 1))
        XCTAssertEqual(debug.vertices.count, 24)                 // twelve edges
        debug.sphere(center: Vec3(0, 0, 0), radius: 1, Vec4(1, 1, 1, 1), segments: 16)
        XCTAssertEqual(debug.vertices.count, 24 + 3 * 16 * 2)
        debug.clear()
        XCTAssertTrue(debug.vertices.isEmpty)
    }
}
