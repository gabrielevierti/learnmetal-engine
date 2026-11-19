// Particles.swift
// Particle emitters simulated on the CPU and drawn as camera-facing quads with one
// instanced draw call per emitter.
//
// CPU particles are the right default for gameplay effects: a few hundred sparks, puffs
// of dust, a burst when something is collected. They can collide with game logic and
// cost almost nothing at these counts. (For hundreds of thousands of particles, move the
// simulation into a compute shader, as the Compute Shaders chapter of the site does.)

import Foundation
import simd

public struct Particle {
    public var position = Vec3(0, 0, 0)
    public var velocity = Vec3(0, 0, 0)
    public var age: Float = 0
    public var lifetime: Float = 1
}

/// Component. The emitter sits at its entity's position and emits along `direction`
/// in the entity's local space. Particles then live in world space.
public struct ParticleEmitter {
    // What to emit.
    public var rate: Float = 20                     // particles per second while isEmitting
    public var lifetimeMin: Float = 0.6
    public var lifetimeMax: Float = 1.2
    public var speedMin: Float = 1
    public var speedMax: Float = 2
    public var direction = Vec3(0, 1, 0)
    public var spread: Float = radians(25)          // half-angle of the emission cone; pi emits in every direction
    public var spawnRadius: Float = 0               // particles start inside a sphere of this radius
    public var gravity = Vec3(0, -2, 0)
    public var drag: Float = 0.5

    // How a particle looks over its life.
    public var sizeStart: Float = 0.15
    public var sizeEnd: Float = 0
    public var colorStart = Vec4(1, 1, 1, 1)        // linear RGB; values above 1 feed the bloom
    public var colorEnd = Vec4(1, 1, 1, 0)
    public var isAdditive = true

    public var isEmitting = true
    public var maxParticles = 512

    // State.
    public var particles: [Particle] = []
    var spawnAccumulator: Float = 0
    var pendingBurst = 0
    var random = Random(seed: 0)
    var isSeeded = false

    public init() {}

    /// Emits `count` particles at once on the next update.
    public mutating func burst(_ count: Int) { pendingBurst += count }
}

/// Advances every emitter in the scene. Needs up-to-date Transform.world matrices.
public func updateParticles(_ scene: Scene, dt: Float) {
    scene.each(ParticleEmitter.self, Transform.self) { entity, emitter, transform in
        if !emitter.isSeeded {
            emitter.random = Random(seed: UInt64(entity.index) &* 7919 &+ 17)      // a different pattern per emitter
            emitter.isSeeded = true
        }

        // Age and move the living particles; drop the dead ones by swapping with the last.
        var i = 0
        while i < emitter.particles.count {
            emitter.particles[i].age += dt
            if emitter.particles[i].age >= emitter.particles[i].lifetime {
                emitter.particles[i] = emitter.particles[emitter.particles.count - 1]
                emitter.particles.removeLast()
                continue
            }
            emitter.particles[i].velocity += emitter.gravity * dt
            emitter.particles[i].velocity *= 1 / (1 + emitter.drag * dt)
            emitter.particles[i].position += emitter.particles[i].velocity * dt
            i += 1
        }

        // Spawn. The accumulator carries fractions of a particle from frame to frame.
        var toSpawn = emitter.pendingBurst
        emitter.pendingBurst = 0
        if emitter.isEmitting && emitter.rate > 0 {
            emitter.spawnAccumulator += emitter.rate * dt
            let whole = Int(emitter.spawnAccumulator)
            emitter.spawnAccumulator -= Float(whole)
            toSpawn += whole
        }

        let origin = transform.worldPosition
        let axis = safeNormalize(transform.world.transformDirection(emitter.direction))
        var spawned = 0
        while spawned < toSpawn && emitter.particles.count < emitter.maxParticles {
            var particle = Particle()
            particle.position = origin + emitter.random.insideUnitSphere() * emitter.spawnRadius
            let direction = emitter.random.inCone(axis, halfAngle: emitter.spread)
            particle.velocity = direction * emitter.random.range(emitter.speedMin, emitter.speedMax)
            particle.lifetime = emitter.random.range(emitter.lifetimeMin, emitter.lifetimeMax)
            emitter.particles.append(particle)
            spawned += 1
        }
    }
}
