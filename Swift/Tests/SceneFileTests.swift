import XCTest
import simd
@testable import LMEngine

// Builds a scene that uses every kind of line the format has (except meshes and
// textures, which need a GPU).
private func buildScene(_ scene: Scene) -> [NamedMaterial] {
    let stone = Material()
    stone.baseColor = Vec4(0.8, 0.7, 0.6, 1)
    stone.roughness = 0.85
    stone.uvScale = Vec2(2, 3)
    let glass = Material()
    glass.baseColor = Vec4(0.2, 0.5, 1.0, 0.4)
    glass.alphaMode = .blend
    glass.emissive = Vec3(0, 0.5, 2.5)
    glass.isDoubleSided = true

    let sun = scene.create("Sun")
    scene.add(sun, Transform(rotation: .lookRotation(forward: Vec3(0.3, -1, -0.2))))
    scene.add(sun, Light(type: .directional, color: Vec3(1, 0.95, 0.8), intensity: 3.5, castsShadows: true))

    let cart = scene.create("Cart")
    scene.add(cart, Transform(position: Vec3(1.5, 0.25, -3), scale: Vec3(2, 0.5, 1)))
    var renderer = MeshRenderer(mesh: nil, material: glass)
    renderer.tint = Vec4(1, 0.5, 0.5, 1)
    renderer.castsShadows = false
    scene.add(cart, renderer)
    scene.add(cart, Collider.box(halfExtents: Vec3(1, 0.25, 0.5)))
    scene.add(cart, RigidBody(type: .kinematic, friction: 0.9))

    let wheel = scene.create("Front wheel")
    scene.add(wheel, Transform(position: Vec3(0.4, -0.5, 0), parent: cart))
    var capsule = Collider.capsule(radius: 0.2, halfHeight: 0.4)
    capsule.isTrigger = true
    capsule.offset = Vec3(0, 0.1, 0)
    scene.add(wheel, capsule)

    let camera = scene.create("Camera")
    scene.add(camera, Transform(position: Vec3(0, 2, 8)))
    scene.add(camera, Camera(fovY: radians(45), farPlane: 250))

    let fountain = scene.create("Fountain")
    scene.add(fountain, Transform())
    var emitter = ParticleEmitter()
    emitter.rate = 60
    emitter.colorStart = Vec4(2, 1, 0.5, 1)
    emitter.isAdditive = false
    emitter.maxParticles = 128
    scene.add(fountain, emitter)

    let tool = scene.create("Editor camera")        // belongs to a tool: must not be saved
    scene.add(tool, Transform())
    scene.add(tool, Camera())
    scene.add(tool, EditorOnly())
    return [NamedMaterial(name: "Stone", material: stone), NamedMaterial(name: "Blue \"glass\"", material: glass)]
}

final class SceneFileTests: XCTestCase {
    func testRoundTripKeepsEverything() {
        let scene = Scene()
        let materials = buildScene(scene)
        var settings = RenderSettings()
        settings.exposure = 1.4
        settings.fogDensity = 0.01
        settings.sky.zenithColor = Vec3(0.1, 0.2, 0.6)
        settings.bloomEnabled = false
        let text = writeScene(scene, materials: materials, settings: settings)
        XCTAssertFalse(text.contains("Editor camera"))

        let loaded = Scene()
        var loadedMaterials: [NamedMaterial] = []
        var loadedSettings = RenderSettings()
        XCTAssertTrue(readScene(text, into: loaded, materials: &loadedMaterials, settings: &loadedSettings, assets: SceneAssets()))
        XCTAssertEqual(loaded.entityCount, 5)
        XCTAssertEqual(loadedMaterials.count, 2)
        XCTAssertEqual(loadedMaterials[1].name, "Blue \"glass\"")
        XCTAssertEqual(loadedMaterials[1].material.alphaMode, .blend)
        XCTAssertEqual(loadedMaterials[1].material.emissive.z, 2.5, accuracy: 1e-6)
        XCTAssertEqual(loadedSettings.exposure, 1.4, accuracy: 1e-6)
        XCTAssertFalse(loadedSettings.bloomEnabled)

        guard let cart = loaded.find("Cart"), let wheel = loaded.find("Front wheel"), let sun = loaded.find("Sun"),
              let camera = loaded.find("Camera"), let fountain = loaded.find("Fountain") else {
            return XCTFail("an entity is missing")
        }
        XCTAssertEqual(loaded[wheel, Transform.self]?.parent, cart)
        XCTAssertTrue(loaded[cart, MeshRenderer.self]?.material === loadedMaterials[1].material)
        XCTAssertEqual(loaded[cart, RigidBody.self]?.type, .kinematic)
        XCTAssertEqual(loaded[wheel, Collider.self]?.shape, .capsule)
        XCTAssertEqual(loaded[wheel, Collider.self]?.isTrigger, true)
        XCTAssertEqual(loaded[sun, Light.self]?.castsShadows, true)
        XCTAssertEqual(loaded[camera, Camera.self]?.farPlane ?? 0, 250, accuracy: 1e-6)
        XCTAssertEqual(loaded[fountain, ParticleEmitter.self]?.maxParticles, 128)

        // Writing what was read gives the same text, to the last digit.
        XCTAssertEqual(writeScene(loaded, materials: loadedMaterials, settings: loadedSettings), text)
    }

    func testSkipsWhatItDoesNotKnowAndRejectsOtherFiles() {
        let scene = Scene()
        var materials: [NamedMaterial] = []
        var settings = RenderSettings()
        let text = """
            learnmetal-scene 1
            # a comment
            settings
              exposure 2
              somethingFromTheFuture 1 2 3
            material "Paint"
              roughness 0.25
            entity "Lamp post"
              transform 1 2 3
              hologram 7
              light spot 1 0 0 4
              parent 5
            """
        XCTAssertTrue(readScene(text, into: scene, materials: &materials, settings: &settings, assets: SceneAssets()))
        XCTAssertEqual(settings.exposure, 2, accuracy: 1e-6)
        XCTAssertEqual(materials.count, 1)
        XCTAssertEqual(materials.first?.material.roughness ?? 0, 0.25, accuracy: 1e-6)
        guard let lamp = scene.find("Lamp post"), let transform = scene[lamp, Transform.self] else { return XCTFail("no lamp") }
        XCTAssertEqual(transform.position.y, 2, accuracy: 1e-6)
        XCTAssertEqual(transform.scale.x, 1, accuracy: 1e-6)        // rotation and scale left out: defaults
        XCTAssertFalse(transform.parent.isValid)                    // no such entity: ignored
        XCTAssertEqual(scene[lamp, Light.self]?.type, .spot)
        XCTAssertEqual(scene[lamp, Light.self]?.intensity ?? 0, 4, accuracy: 1e-6)

        let other = Scene()
        XCTAssertFalse(readScene("{ \"json\": true }", into: other, materials: &materials, settings: &settings, assets: SceneAssets()))
        XCTAssertEqual(other.entityCount, 0)
    }
}
