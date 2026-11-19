// Time.swift
// Frame timing and the fixed-step clock.
//
// Rendering runs as fast as the display allows, with a different duration every frame.
// Physics is only stable and repeatable with a constant step. The classic answer is an
// accumulator: real time is poured in each frame and consumed in fixed-size steps.
// Whatever is left over, as a fraction of a step, is `alpha`: how far the renderer
// should blend from the previous physics state to the current one.

import Foundation

public struct Time {
    public var elapsed: Double = 0                  // seconds of game time since the start
    public var delta: Float = 0                     // duration of this frame, scaled by timeScale
    public var unscaledDelta: Float = 0
    public var fixedDelta: Float = 1.0 / 60.0       // duration of one physics step
    public var alpha: Float = 0                     // 0..1: position of this frame between two physics steps
    public var timeScale: Float = 1                 // 0 pauses, 0.5 is slow motion
    public var framesPerSecond: Float = 0           // smoothed
    public var frameCount: UInt64 = 0
    public var maxStepsPerFrame = 5                 // after a long hitch, drop time instead of spiralling

    private var accumulator: Double = 0

    public init() {}

    /// Starts a frame that lasted `realDelta` seconds. Returns how many fixed steps to run now.
    public mutating func beginFrame(_ realDelta: Double) -> Int {
        let clamped = min(max(realDelta, 0), 0.25)
        unscaledDelta = Float(clamped)
        delta = unscaledDelta * timeScale
        elapsed += Double(delta)
        frameCount += 1
        if clamped > 0 {
            let instant = Float(1 / clamped)
            framesPerSecond = framesPerSecond <= 0 ? instant : framesPerSecond + (instant - framesPerSecond) * 0.05
        }

        accumulator += Double(delta)
        var steps = 0
        while accumulator >= Double(fixedDelta) && steps < maxStepsPerFrame {
            accumulator -= Double(fixedDelta)
            steps += 1
        }
        if steps == maxStepsPerFrame { accumulator = min(accumulator, Double(fixedDelta)) }
        alpha = Float(accumulator / Double(fixedDelta))
        return steps
    }
}
