// Scene.swift
// A small entity-component system.
//
// An Entity is only an id. Data lives in components, plain structs that are stored
// packed together by type (a "sparse set" per component type), so that a system which
// walks every Transform or every RigidBody reads memory in order.
//
//     let crate = scene.create("Crate")
//     scene.add(crate, Transform(position: Vec3(0, 2, 0)))
//     scene.add(crate, RigidBody())
//
//     scene.each(Transform.self, RigidBody.self) { entity, transform, body in ... }

import Foundation
import simd

/// A handle to an entity. The generation makes stale handles detectable: when an entity
/// is destroyed its index is reused, but with a higher generation.
public struct Entity: Hashable {
    public var index: UInt32 = .max
    public var generation: UInt32 = 0

    /// A handle that refers to nothing, for "no parent" and "not found".
    public static let invalid = Entity()

    public init() {}
    public init(index: UInt32, generation: UInt32) {
        self.index = index
        self.generation = generation
    }

    public var isValid: Bool { index != .max }
}

/// Where an entity is. Positions, rotations and scales are relative to `parent`
/// when there is one. `world` is filled in by Scene.updateTransforms().
public struct Transform {
    public var position = Vec3(0, 0, 0)
    public var rotation = Quat.identity
    public var scale = Vec3(1, 1, 1)
    public var parent = Entity.invalid
    public var world = matrix_identity_float4x4
    var stamp: UInt32 = 0               // internal: the update that last computed `world`

    public init(position: Vec3 = Vec3(0, 0, 0), rotation: Quat = .identity, scale: Vec3 = Vec3(1, 1, 1),
                parent: Entity = .invalid) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.parent = parent
    }

    public var localMatrix: Mat4 { Mat4.compose(position: position, rotation: rotation, scale: scale) }
    public var forward: Vec3 { rotation.act(Vec3(0, 0, -1)) }
    public var right: Vec3 { rotation.act(Vec3(1, 0, 0)) }
    public var up: Vec3 { rotation.act(Vec3(0, 1, 0)) }
    public var worldPosition: Vec3 { xyz(world.columns.3) }
}

public struct Name {
    public var value: String
    public init(_ value: String) { self.value = value }
}

// MARK: - Storage

protocol AnyStorage: AnyObject {
    func remove(_ entityIndex: UInt32)
    func clear()
}

/// Sparse set: `dense` holds the components back to back, `owners[i]` is the entity that
/// owns `dense[i]`, and `sparse[entityIndex]` is the position in `dense`, or -1.
final class Storage<T>: AnyStorage {
    var dense: [T] = []
    var owners: [UInt32] = []
    var sparse: [Int32] = []

    func denseIndex(_ entityIndex: UInt32) -> Int? {
        let i = Int(entityIndex)
        guard i < sparse.count, sparse[i] >= 0 else { return nil }
        return Int(sparse[i])
    }

    func set(_ entityIndex: UInt32, _ value: T) {
        if let existing = denseIndex(entityIndex) {
            dense[existing] = value
            return
        }
        let i = Int(entityIndex)
        if i >= sparse.count {
            sparse.append(contentsOf: repeatElement(Int32(-1), count: i + 1 - sparse.count))
        }
        sparse[i] = Int32(dense.count)
        dense.append(value)
        owners.append(entityIndex)
    }

    /// Removes by moving the last component into the hole, so `dense` stays packed.
    func remove(_ entityIndex: UInt32) {
        guard let hole = denseIndex(entityIndex) else { return }
        let last = dense.count - 1
        if hole != last {
            dense[hole] = dense[last]
            owners[hole] = owners[last]
            sparse[Int(owners[hole])] = Int32(hole)
        }
        dense.removeLast()
        owners.removeLast()
        sparse[Int(entityIndex)] = -1
    }

    func clear() {
        dense.removeAll()
        owners.removeAll()
        sparse.removeAll()
    }
}

// MARK: - Scene

public final class Scene {
    private var generations: [UInt32] = []
    private var alive: [Bool] = []
    private var doomed: [Bool] = []
    private var freeIndices: [UInt32] = []
    private var pendingDestroy: [Entity] = []
    private var storages: [ObjectIdentifier: AnyStorage] = [:]
    private var transformStamp: UInt32 = 0

    public private(set) var entityCount = 0

    public init() {}

    // MARK: Entities

    @discardableResult
    public func create(_ name: String = "") -> Entity {
        let index: UInt32
        if let reused = freeIndices.popLast() {
            index = reused
        } else {
            index = UInt32(generations.count)
            generations.append(0)
            alive.append(false)
            doomed.append(false)
        }
        alive[Int(index)] = true
        doomed[Int(index)] = false
        entityCount += 1
        let entity = Entity(index: index, generation: generations[Int(index)])
        if !name.isEmpty { add(entity, Name(name)) }
        return entity
    }

    /// Marks the entity, and every entity parented to it, for destruction. They disappear
    /// in flushDestroyed(), at the end of the frame, so it is always safe to call this
    /// from inside each() or from a collision callback.
    public func destroy(_ entity: Entity) {
        guard isAlive(entity), !doomed[Int(entity.index)] else { return }
        doomed[Int(entity.index)] = true
        pendingDestroy.append(entity)
    }

    public func isAlive(_ entity: Entity) -> Bool {
        let i = Int(entity.index)
        return i < generations.count && alive[i] && generations[i] == entity.generation
    }

    /// The first entity with this name, if any.
    public func find(_ name: String) -> Entity? {
        guard let names = existingStorage(Name.self) else { return nil }
        for (i, candidate) in names.dense.enumerated() where candidate.value == name {
            let index = names.owners[i]
            return Entity(index: index, generation: generations[Int(index)])
        }
        return nil
    }

    public func clear() {
        for storage in storages.values { storage.clear() }
        for index in 0..<generations.count {
            if alive[index] {
                alive[index] = false
                generations[index] &+= 1
                freeIndices.append(UInt32(index))
            }
            doomed[index] = false
        }
        pendingDestroy.removeAll()
        entityCount = 0
    }

    // MARK: Components

    /// Adds the component, or replaces the one the entity already has.
    public func add<T>(_ entity: Entity, _ component: T) {
        precondition(isAlive(entity), "adding a component to an entity that no longer exists")
        storage(T.self).set(entity.index, component)
    }

    /// The entity's component of the given type. Reading gives a copy; writing through
    /// the subscript changes the stored one:
    ///
    ///     scene[player, Transform.self]?.position.y += 1
    ///
    /// Assigning nil removes the component.
    public subscript<T>(entity: Entity, type: T.Type) -> T? {
        get {
            guard isAlive(entity), let found = existingStorage(T.self), let i = found.denseIndex(entity.index) else { return nil }
            return found.dense[i]
        }
        set {
            guard isAlive(entity) else { return }
            if let value = newValue {
                storage(T.self).set(entity.index, value)
            } else {
                existingStorage(T.self)?.remove(entity.index)
            }
        }
    }

    public func has<T>(_ type: T.Type, _ entity: Entity) -> Bool {
        guard isAlive(entity), let found = existingStorage(T.self) else { return false }
        return found.denseIndex(entity.index) != nil
    }

    public func remove<T>(_ type: T.Type, _ entity: Entity) {
        if isAlive(entity) { existingStorage(T.self)?.remove(entity.index) }
    }

    public func count<T>(_ type: T.Type) -> Int { existingStorage(T.self)?.dense.count ?? 0 }

    /// Calls `body` for every entity that has the listed components. The components are
    /// passed `inout`: changes made to them are stored when `body` returns.
    ///
    /// While `body` runs it may read or write any other entity through the scene, add
    /// components and call destroy(). It should not remove the listed components.
    public func each<A>(_ a: A.Type, _ body: (Entity, inout A) -> Void) {
        let sa = storage(A.self)
        var i = 0
        while i < sa.dense.count {
            let index = sa.owners[i]
            var ca = sa.dense[i]
            body(Entity(index: index, generation: generations[Int(index)]), &ca)
            if let j = sa.denseIndex(index) { sa.dense[j] = ca }
            i += 1
        }
    }

    public func each<A, B>(_ a: A.Type, _ b: B.Type, _ body: (Entity, inout A, inout B) -> Void) {
        let sa = storage(A.self), sb = storage(B.self)
        var i = 0
        while i < sa.dense.count {
            let index = sa.owners[i]
            if let jb = sb.denseIndex(index) {
                var ca = sa.dense[i], cb = sb.dense[jb]
                body(Entity(index: index, generation: generations[Int(index)]), &ca, &cb)
                if let j = sa.denseIndex(index) { sa.dense[j] = ca }
                if let j = sb.denseIndex(index) { sb.dense[j] = cb }
            }
            i += 1
        }
    }

    public func each<A, B, C>(_ a: A.Type, _ b: B.Type, _ c: C.Type, _ body: (Entity, inout A, inout B, inout C) -> Void) {
        let sa = storage(A.self), sb = storage(B.self), sc = storage(C.self)
        var i = 0
        while i < sa.dense.count {
            let index = sa.owners[i]
            if let jb = sb.denseIndex(index), let jc = sc.denseIndex(index) {
                var ca = sa.dense[i], cb = sb.dense[jb], cc = sc.dense[jc]
                body(Entity(index: index, generation: generations[Int(index)]), &ca, &cb, &cc)
                if let j = sa.denseIndex(index) { sa.dense[j] = ca }
                if let j = sb.denseIndex(index) { sb.dense[j] = cb }
                if let j = sc.denseIndex(index) { sc.dense[j] = cc }
            }
            i += 1
        }
    }

    // MARK: Hierarchy

    public func setParent(_ child: Entity, _ parent: Entity) {
        self[child, Transform.self]?.parent = parent
    }

    /// Recomputes Transform.world for every entity, parents before children.
    public func updateTransforms() {
        let transforms = storage(Transform.self)
        transformStamp &+= 1
        for i in 0..<transforms.dense.count {
            _ = resolveWorld(transforms, transforms.owners[i])
        }
    }

    private func resolveWorld(_ transforms: Storage<Transform>, _ index: UInt32) -> Mat4 {
        guard let i = transforms.denseIndex(index) else { return matrix_identity_float4x4 }
        if transforms.dense[i].stamp == transformStamp { return transforms.dense[i].world }
        transforms.dense[i].stamp = transformStamp          // set first, so a parent cycle cannot recurse forever
        let local = transforms.dense[i].localMatrix
        let parent = transforms.dense[i].parent
        var world = local
        if parent.isValid, isAlive(parent), transforms.denseIndex(parent.index) != nil {
            world = resolveWorld(transforms, parent.index) * local
        }
        transforms.dense[i].world = world
        return world
    }

    /// Actually removes the entities passed to destroy(). Called by the engine once per frame.
    public func flushDestroyed() {
        if pendingDestroy.isEmpty { return }

        // Children go with their parents. Repeat until no new entity is caught, so that
        // grandchildren are found whatever order the transforms are stored in.
        let transforms = storage(Transform.self)
        var foundMore = true
        while foundMore {
            foundMore = false
            for i in 0..<transforms.dense.count {
                let index = transforms.owners[i]
                let parent = transforms.dense[i].parent
                if !doomed[Int(index)], parent.isValid, isAlive(parent), doomed[Int(parent.index)] {
                    doomed[Int(index)] = true
                    pendingDestroy.append(Entity(index: index, generation: generations[Int(index)]))
                    foundMore = true
                }
            }
        }

        for entity in pendingDestroy {
            let i = Int(entity.index)
            for storage in storages.values { storage.remove(entity.index) }
            alive[i] = false
            doomed[i] = false
            generations[i] &+= 1
            freeIndices.append(entity.index)
            entityCount -= 1
        }
        pendingDestroy.removeAll()
    }

    // MARK: Internals

    func storage<T>(_ type: T.Type) -> Storage<T> {
        let key = ObjectIdentifier(type)
        if let existing = storages[key] as? Storage<T> { return existing }
        let created = Storage<T>()
        storages[key] = created
        return created
    }

    func existingStorage<T>(_ type: T.Type) -> Storage<T>? {
        storages[ObjectIdentifier(type)] as? Storage<T>
    }
}
