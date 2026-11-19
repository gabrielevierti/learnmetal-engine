import XCTest
import simd
@testable import LMEngine

private struct Health { var value = 100 }
private struct Tag { var id = 0 }

final class SceneTests: XCTestCase {
    func testEntitiesAreCreatedDestroyedAndReused() {
        let scene = Scene()
        let a = scene.create("A"), b = scene.create()
        XCTAssertTrue(scene.isAlive(a) && scene.isAlive(b))
        XCTAssertEqual(scene.entityCount, 2)
        scene.destroy(a)
        XCTAssertTrue(scene.isAlive(a))                 // destruction is deferred
        scene.flushDestroyed()
        XCTAssertFalse(scene.isAlive(a))
        XCTAssertEqual(scene.entityCount, 1)

        let c = scene.create()                          // reuses the index with a new generation
        XCTAssertEqual(c.index, a.index)
        XCTAssertNotEqual(c.generation, a.generation)
        XCTAssertFalse(scene.isAlive(a))
        XCTAssertNil(scene[a, Name.self])
    }

    func testComponentsAddGetRemove() {
        let scene = Scene()
        let e = scene.create()
        XCTAssertNil(scene[e, Health.self])
        scene.add(e, Health(value: 50))
        XCTAssertTrue(scene.has(Health.self, e))
        XCTAssertEqual(scene[e, Health.self]?.value, 50)
        scene[e, Health.self]?.value -= 20
        XCTAssertEqual(scene[e, Health.self]?.value, 30)
        scene.add(e, Health(value: 7))                  // adding again replaces
        XCTAssertEqual(scene[e, Health.self]?.value, 7)
        XCTAssertEqual(scene.count(Health.self), 1)
        scene.remove(Health.self, e)
        XCTAssertFalse(scene.has(Health.self, e))
    }

    func testRemovingKeepsOtherComponentsIntact() {
        let scene = Scene()
        var entities: [Entity] = []
        for i in 0..<10 {
            entities.append(scene.create())
            scene.add(entities[i], Tag(id: i))
        }
        scene.remove(Tag.self, entities[3])
        scene.destroy(entities[0])
        scene.flushDestroyed()
        XCTAssertEqual(scene.count(Tag.self), 8)
        for i in 1..<10 where i != 3 {
            XCTAssertEqual(scene[entities[i], Tag.self]?.id, i)
        }
    }

    func testEachVisitsEntitiesWithAllComponents() {
        let scene = Scene()
        let both = scene.create(), onlyHealth = scene.create(), onlyTag = scene.create()
        scene.add(both, Health(value: 1))
        scene.add(both, Tag(id: 1))
        scene.add(onlyHealth, Health(value: 2))
        scene.add(onlyTag, Tag(id: 3))

        var visited = 0
        scene.each(Health.self, Tag.self) { entity, health, tag in
            visited += 1
            XCTAssertEqual(entity, both)
            health.value += tag.id
        }
        XCTAssertEqual(visited, 1)
        XCTAssertEqual(scene[both, Health.self]?.value, 2)

        var healthCount = 0
        scene.each(Health.self) { _, _ in healthCount += 1 }
        XCTAssertEqual(healthCount, 2)
    }

    func testOtherEntitiesCanBeReadAndWrittenInsideEach() {
        // The loop hands out copies and stores them back, so touching the same
        // component type of another entity from inside the closure is safe.
        let scene = Scene()
        let first = scene.create(), second = scene.create()
        scene.add(first, Health(value: 10))
        scene.add(second, Health(value: 20))
        scene.each(Health.self) { entity, health in
            if entity == first {
                health.value += scene[second, Health.self]?.value ?? 0
                scene[second, Health.self]?.value = 5
            }
        }
        XCTAssertEqual(scene[first, Health.self]?.value, 30)
        XCTAssertEqual(scene[second, Health.self]?.value, 5)
    }

    func testFindByName() {
        let scene = Scene()
        scene.create("Floor")
        let player = scene.create("Player")
        XCTAssertEqual(scene.find("Player"), player)
        XCTAssertNil(scene.find("Nobody"))
    }

    func testWorldMatricesFollowTheHierarchy() {
        let scene = Scene()
        // Created child first, on purpose: the update must not depend on storage order.
        let child = scene.create(), parent = scene.create(), grandchild = scene.create()
        scene.add(child, Transform(position: Vec3(0, 0, -2)))
        scene.add(parent, Transform(position: Vec3(10, 0, 0), rotation: Quat(angle: radians(90), axis: Vec3(0, 1, 0))))
        scene.add(grandchild, Transform(position: Vec3(0, 1, 0)))
        scene.setParent(child, parent)
        scene.setParent(grandchild, child)
        scene.updateTransforms()

        // Rotating 90 degrees around Y turns the child's -Z offset into -X.
        let childWorld = scene[child, Transform.self]!.worldPosition
        XCTAssertEqual(childWorld.x, 8, accuracy: 1e-4)
        XCTAssertEqual(childWorld.z, 0, accuracy: 1e-4)
        let grandchildWorld = scene[grandchild, Transform.self]!.worldPosition
        XCTAssertEqual(grandchildWorld.x, 8, accuracy: 1e-4)
        XCTAssertEqual(grandchildWorld.y, 1, accuracy: 1e-4)
    }

    func testDestroyingAParentDestroysItsDescendants() {
        let scene = Scene()
        let parent = scene.create(), child = scene.create(), grandchild = scene.create(), other = scene.create()
        for e in [parent, child, grandchild, other] { scene.add(e, Transform()) }
        scene.setParent(grandchild, child)
        scene.setParent(child, parent)
        scene.destroy(parent)
        scene.flushDestroyed()
        XCTAssertFalse(scene.isAlive(parent) || scene.isAlive(child) || scene.isAlive(grandchild))
        XCTAssertTrue(scene.isAlive(other))
        XCTAssertEqual(scene.count(Transform.self), 1)
    }

    func testCameraProjectionRespectsAspect() {
        let camera = Camera(fovY: radians(90))
        let edge = camera.projection(aspect: 2) * Vec4(2 * 10, 0, -10, 1)      // tan(45) * aspect * distance
        XCTAssertEqual(edge.x / edge.w, 1, accuracy: 1e-4)
    }
}
