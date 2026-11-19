// Surface.swift
// What the engine needs from whatever shows its pictures: a size, and a texture to
// draw the next frame into. On a Mac that is the Window; on iOS, the EngineViewController.

import Metal
import QuartzCore

@MainActor
public protocol Surface: AnyObject {
    /// The drawable area in points: what canvas coordinates and the mouse position are measured in.
    var sizeInPoints: Vec2 { get }
    /// Pixels per point: 2 on a Retina display, 3 on most iPhones.
    var contentScale: Float { get }
    /// Space to leave free at the left, top, right and bottom edges, in points.
    var safeArea: Vec4 { get }
    /// The next texture to draw into, or nil if there is none right now: skip the frame.
    func nextDrawable() -> CAMetalDrawable?
}
