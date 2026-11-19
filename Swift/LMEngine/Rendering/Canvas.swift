// Canvas.swift
// Immediate-mode 2D drawing for HUDs, menus and 2D games.
//
// "Immediate mode" means there are no 2D objects to keep around: every frame the game
// says what to draw, in order, and the canvas turns the calls into triangles. The
// renderer draws them in as few draw calls as possible (one per change of texture).
//
// Coordinates are in points with the origin at the top left, like the window system's.
// Colors are sRGB with straight alpha, the values a color picker shows.
//
// Edges are smoothed without multisampling: every shape that is not an upright rectangle
// gets a border one pixel wide that fades from its color to transparent. The same
// triangles and the same shader do everything; only the vertices know about it.

import Foundation
import ShaderTypes
import simd

public enum TextAlign {
    case left, center, right
}

/// A color from the usual hexadecimal notation: rgb(0xfe8b3c) is the LearnMetal orange.
public func rgb(_ hex: UInt32, alpha: Float = 1) -> Vec4 {
    Vec4(Float((hex >> 16) & 0xFF) / 255, Float((hex >> 8) & 0xFF) / 255, Float(hex & 0xFF) / 255, alpha)
}

public final class Canvas {
    public struct Batch {
        public var texture: Texture?        // nil draws with solid color
        public var isText: Bool             // text samples a distance field instead of colors
        public var firstVertex: Int
        public var vertexCount: Int
        public var isClipped = false        // draw only inside clipMin ... clipMax (in points)
        public var clipMin = Vec2(0, 0)
        public var clipMax = Vec2(0, 0)
    }

    /// The drawable area, in points.
    public private(set) var size = Vec2(0, 0)
    /// One screen pixel, in points: 1 on a plain screen, 0.5 on a Retina display.
    public private(set) var pixelSize: Float = 1
    public private(set) var vertices: [CanvasVertex] = []
    public private(set) var batches: [Batch] = []

    private var font: FontMetrics?
    private var fontAtlas: Texture?
    private var clips: [(min: Vec2, max: Vec2)] = []
    private var isClipEmpty = false         // the current clip has no area: nothing can be drawn
    private var path: [Vec2] = []           // scratch space, kept to avoid allocating per shape
    private var inner: [Vec2] = []
    private var outer: [Vec2] = []

    /// The distance-field spread of the current font, which the text shader needs.
    public var fontDistanceRange: Float { font?.distanceRange ?? 1 }

    public init() {}

    // MARK: Used by the engine

    /// `pixelsPerPoint` is 2 on a Retina display: the canvas needs it to make edges one pixel soft.
    public func begin(size sizeInPoints: Vec2, pixelsPerPoint: Float = 1) {
        size = sizeInPoints
        pixelSize = 1 / max(pixelsPerPoint, 0.25)
        vertices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
        clips.removeAll(keepingCapacity: true)
        isClipEmpty = false
    }

    public func setFont(_ metrics: FontMetrics?, atlas: Texture?) {
        font = metrics
        fontAtlas = atlas
    }

    // MARK: Clipping

    /// Until popClip, nothing is drawn outside the rectangle. Clips nest: a clip inside
    /// another one is cut to it.
    public func pushClip(_ position: Vec2, _ size: Vec2) {
        // A clip can only make the area smaller.
        let outerMin = clips.last?.min ?? Vec2(0, 0), outerMax = clips.last?.max ?? self.size
        let clipMin = simd_max(position, outerMin), clipMax = simd_min(position + size, outerMax)
        clips.append((clipMin, clipMax))
        isClipEmpty = clipMax.x <= clipMin.x || clipMax.y <= clipMin.y
    }

    public func popClip() {
        if !clips.isEmpty { clips.removeLast() }
        if let clip = clips.last {
            isClipEmpty = clip.max.x <= clip.min.x || clip.max.y <= clip.min.y
        } else {
            isClipEmpty = false
        }
    }

    // MARK: Shapes

    public func rect(_ position: Vec2, _ size: Vec2, _ color: Vec4) {
        image(nil, position, size, tint: color)
    }

    public func rectOutline(_ position: Vec2, _ size: Vec2, thickness: Float, _ color: Vec4) {
        rect(position, Vec2(size.x, thickness), color)
        rect(Vec2(position.x, position.y + size.y - thickness), Vec2(size.x, thickness), color)
        rect(Vec2(position.x, position.y + thickness), Vec2(thickness, size.y - 2 * thickness), color)
        rect(Vec2(position.x + size.x - thickness, position.y + thickness), Vec2(thickness, size.y - 2 * thickness), color)
    }

    public func line(from: Vec2, to: Vec2, thickness: Float, _ color: Vec4) {
        if simd_length(to - from) < 1e-5 { return }
        strokePath([from, to], thickness, color, isClosed: false)
    }

    /// A filled circle. With `segments` 0 the canvas chooses enough of them for the radius.
    public func circle(center: Vec2, radius: Float, _ color: Vec4, segments: Int = 0) {
        if radius <= 0 { return }
        path.removeAll(keepingCapacity: true)
        arcPath(center, radius, 0, 2 * Float.pi, segments >= 3 ? segments : segmentsFor(radius))
        path.removeLast()                           // the last point repeats the first
        fillConvex(path, color)
    }

    public func roundedRect(_ position: Vec2, _ size: Vec2, radius: Float, _ color: Vec4) {
        if size.x <= 0 || size.y <= 0 { return }
        roundedRectPath(position, size, radius)
        fillConvex(path, color)
    }

    public func roundedRectOutline(_ position: Vec2, _ size: Vec2, radius: Float, thickness: Float, _ color: Vec4) {
        if size.x <= thickness || size.y <= thickness { return }
        // The line is centered on its path: move the path in by half the thickness to stay inside.
        let inset = thickness * 0.5
        roundedRectPath(position + Vec2(inset, inset), size - Vec2(thickness, thickness), max(radius - inset, 0))
        strokePath(path, thickness, color, isClosed: true)
    }

    /// The outline of a circle, drawn inside `radius`.
    public func ring(center: Vec2, radius: Float, thickness: Float, _ color: Vec4) {
        if radius <= 0 { return }
        path.removeAll(keepingCapacity: true)
        arcPath(center, radius - thickness * 0.5, 0, 2 * Float.pi, segmentsFor(radius))
        path.removeLast()
        strokePath(path, thickness, color, isClosed: true)
    }

    /// Part of a ring. Angles are in radians, clockwise on screen, 0 pointing right.
    public func arc(center: Vec2, radius: Float, from fromAngle: Float, to toAngle: Float, thickness: Float, _ color: Vec4) {
        if radius <= 0 { return }
        let share = min(abs(toAngle - fromAngle) / (2 * Float.pi), 1)
        path.removeAll(keepingCapacity: true)
        arcPath(center, radius - thickness * 0.5, fromAngle, toAngle, max(Int(Float(segmentsFor(radius)) * share), 2))
        strokePath(path, thickness, color, isClosed: false)
    }

    public func triangle(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ color: Vec4) {
        fillConvex([a, b, c], color)
    }

    /// Any convex shape, from its corners in order (either direction).
    public func polygon(_ points: [Vec2], _ color: Vec4) {
        fillConvex(points, color)
    }

    /// A line through several points. `isClosed` joins the last point to the first.
    public func polyline(_ points: [Vec2], thickness: Float, _ color: Vec4, isClosed: Bool = false) {
        strokePath(points, thickness, color, isClosed: isClosed)
    }

    public func image(_ texture: Texture?, _ position: Vec2, _ size: Vec2, tint: Vec4 = Vec4(1, 1, 1, 1),
                      uvMin: Vec2 = Vec2(0, 0), uvMax: Vec2 = Vec2(1, 1)) {
        let a = position, c = position + size
        quad(a, Vec2(a.x, c.y), c, Vec2(c.x, a.y),
             uvMin, Vec2(uvMin.x, uvMax.y), uvMax, Vec2(uvMax.x, uvMin.y), tint, texture, false)
    }

    public func measureText(_ text: String, size: Float) -> Vec2 {
        font?.measure(text, size: size) ?? Vec2(0, 0)
    }

    /// Draws text. `position` is the top left of the first line (or its top center, or
    /// top right, depending on `align`); `size` is the font size in points.
    public func text(_ text: String, _ position: Vec2, size: Float, _ color: Vec4, align: TextAlign = .left) {
        guard let font = font, let atlas = fontAtlas else { return }
        let scale = size / font.bakedSize
        let atlasSize = Vec2(font.atlasWidth, font.atlasHeight)
        var penY = position.y

        // Lay the text out one line at a time, because alignment needs each line's width.
        for lineText in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var penX = position.x
            if align != .left {
                let width = font.measure(String(lineText), size: size).x
                penX -= align == .center ? width * 0.5 : width
            }
            for scalar in lineText.unicodeScalars {
                guard let glyph = font.glyph(scalar.value) else { continue }
                if glyph.width > 0 && glyph.height > 0 {
                    let a = Vec2(penX + glyph.offsetX * scale, penY + glyph.offsetY * scale)
                    let c = a + Vec2(glyph.width, glyph.height) * scale
                    let uvA = Vec2(glyph.x, glyph.y) / atlasSize
                    let uvC = Vec2(glyph.x + glyph.width, glyph.y + glyph.height) / atlasSize
                    quad(a, Vec2(a.x, c.y), c, Vec2(c.x, a.y),
                         uvA, Vec2(uvA.x, uvC.y), uvC, Vec2(uvC.x, uvA.y), color, atlas, true)
                }
                penX += glyph.advance * scale
            }
            penY += font.lineHeight * scale
        }
    }

    // MARK: Internals

    private func ensureBatch(_ texture: Texture?, _ isText: Bool) {
        // Consecutive shapes that use the same texture and the same clip share a draw call.
        let isClipped = !clips.isEmpty
        let clipMin = clips.last?.min ?? Vec2(0, 0), clipMax = clips.last?.max ?? Vec2(0, 0)
        if let last = batches.last, last.texture === texture, last.isText == isText, last.isClipped == isClipped,
           last.clipMin == clipMin, last.clipMax == clipMax {
            return
        }
        batches.append(Batch(texture: texture, isText: isText, firstVertex: vertices.count, vertexCount: 0,
                             isClipped: isClipped, clipMin: clipMin, clipMax: clipMax))
    }

    private func quad(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2, _ uvA: Vec2, _ uvB: Vec2, _ uvC: Vec2, _ uvD: Vec2,
                      _ color: Vec4, _ texture: Texture?, _ isText: Bool) {
        if isClipEmpty { return }
        ensureBatch(texture, isText)
        vertices.append(CanvasVertex(position: a, uv: uvA, color: color))
        vertices.append(CanvasVertex(position: b, uv: uvB, color: color))
        vertices.append(CanvasVertex(position: c, uv: uvC, color: color))
        vertices.append(CanvasVertex(position: a, uv: uvA, color: color))
        vertices.append(CanvasVertex(position: c, uv: uvC, color: color))
        vertices.append(CanvasVertex(position: d, uv: uvD, color: color))
        batches[batches.count - 1].vertexCount += 6
    }

    /// One corner of a solid-colored triangle. Callers add them three at a time.
    private func vertex(_ position: Vec2, _ color: Vec4) {
        vertices.append(CanvasVertex(position: position, uv: Vec2(0.5, 0.5), color: color))
    }

    /// Fills a convex shape. The shape is drawn half a pixel smaller than asked, and a strip
    /// one pixel wide around it fades to transparent: that strip is the anti-aliasing.
    private func fillConvex(_ points: [Vec2], _ color: Vec4) {
        let count = points.count
        if count < 3 || isClipEmpty { return }
        var area: Float = 0
        for i in 0..<count {
            let a = points[i], b = points[(i + 1) % count]
            area += a.x * b.y - b.x * a.y
        }
        if abs(area) < 1e-6 { return }
        let outward: Float = area > 0 ? 1 : -1      // which way "outside" is depends on the order of the corners
        let half = pixelSize * 0.5

        inner.removeAll(keepingCapacity: true)
        outer.removeAll(keepingCapacity: true)
        for i in 0..<count {
            let before = points[(i + count - 1) % count], here = points[i], after = points[(i + 1) % count]
            let e0 = safeNormalize(here - before, fallback: Vec2(1, 0)), e1 = safeNormalize(after - here, fallback: Vec2(1, 0))
            // The direction that moves this corner out by one unit along both of its edges.
            var miter = (Vec2(e0.y, -e0.x) + Vec2(e1.y, -e1.x)) * (0.5 * outward)
            miter = miter / max(simd_dot(miter, miter), 0.25)
            inner.append(here - miter * half)
            outer.append(here + miter * half)
        }

        ensureBatch(nil, false)
        let first = vertices.count
        let clear = Vec4(color.x, color.y, color.z, 0)
        if count > 2 {
            for i in 1..<(count - 1) {
                vertex(inner[0], color)
                vertex(inner[i], color)
                vertex(inner[i + 1], color)
            }
        }
        for i in 0..<count {
            let a = i, b = (i + 1) % count
            vertex(inner[a], color)
            vertex(inner[b], color)
            vertex(outer[b], clear)
            vertex(inner[a], color)
            vertex(outer[b], clear)
            vertex(outer[a], clear)
        }
        batches[batches.count - 1].vertexCount += vertices.count - first
    }

    /// Draws a line through the points: a solid core with a fading strip on each side.
    private func strokePath(_ points: [Vec2], _ thicknessAsked: Float, _ colorAsked: Vec4, isClosed: Bool) {
        let count = points.count
        if count < 2 || thicknessAsked <= 0 || isClipEmpty { return }
        var thickness = thicknessAsked, color = colorAsked
        let soft = pixelSize
        // Thinner than a pixel cannot be drawn; a fainter line one pixel wide looks the same.
        if thickness < soft {
            color.w *= thickness / soft
            thickness = soft
        }
        let core = (thickness - soft) * 0.5
        let edge = core + soft

        // The sideways direction at every point: across the line, averaged where two segments meet.
        inner.removeAll(keepingCapacity: true)
        for i in 0..<count {
            let hasBefore = isClosed || i > 0, hasAfter = isClosed || i + 1 < count
            let here = points[i]
            var d0 = hasBefore ? safeNormalize(here - points[(i + count - 1) % count], fallback: Vec2(1, 0)) : Vec2(0, 0)
            let d1 = hasAfter ? safeNormalize(points[(i + 1) % count] - here, fallback: Vec2(1, 0)) : d0
            if !hasBefore { d0 = d1 }
            let side = (Vec2(-d0.y, d0.x) + Vec2(-d1.y, d1.x)) * 0.5
            inner.append(side / max(simd_dot(side, side), 0.5))
        }

        ensureBatch(nil, false)
        let first = vertices.count
        let clear = Vec4(color.x, color.y, color.z, 0)
        // Across the line: transparent, solid, solid, transparent.
        let offsets: [Float] = [edge, core, -core, -edge]
        let colors = [clear, color, color, clear]
        let segments = isClosed ? count : count - 1
        for i in 0..<segments {
            let a = i, b = (i + 1) % count
            let pa = points[a], pb = points[b], na = inner[a], nb = inner[b]
            for strip in 0..<3 {
                if strip == 1 && core < 1e-4 { continue }
                let a0 = pa + na * offsets[strip], a1 = pa + na * offsets[strip + 1]
                let b0 = pb + nb * offsets[strip], b1 = pb + nb * offsets[strip + 1]
                vertex(a0, colors[strip])
                vertex(a1, colors[strip + 1])
                vertex(b1, colors[strip + 1])
                vertex(a0, colors[strip])
                vertex(b1, colors[strip + 1])
                vertex(b0, colors[strip])
            }
        }
        batches[batches.count - 1].vertexCount += vertices.count - first
    }

    /// Enough segments that a circle of this radius looks round, and no more.
    private func segmentsFor(_ radius: Float) -> Int {
        min(max(Int(8 + radius / pixelSize * 0.9), 12), 96)
    }

    private func arcPath(_ center: Vec2, _ radius: Float, _ fromAngle: Float, _ toAngle: Float, _ segments: Int) {
        for i in 0...segments {
            let angle = fromAngle + (toAngle - fromAngle) * Float(i) / Float(segments)
            path.append(center + Vec2(cos(angle), sin(angle)) * radius)
        }
    }

    private func roundedRectPath(_ position: Vec2, _ size: Vec2, _ radiusAsked: Float) {
        path.removeAll(keepingCapacity: true)
        let radius = min(max(radiusAsked, 0), min(size.x, size.y) * 0.5)
        let a = position, c = position + size
        if radius < 0.01 {
            path = [a, Vec2(c.x, a.y), c, Vec2(a.x, c.y)]
            return
        }
        let steps = min(max(Int((radius / pixelSize * 0.4).rounded(.up)) + 2, 3), 16)
        let quarter = Float.pi * 0.5
        arcPath(Vec2(a.x + radius, a.y + radius), radius, 2 * quarter, 3 * quarter, steps)      // top left
        arcPath(Vec2(c.x - radius, a.y + radius), radius, 3 * quarter, 4 * quarter, steps)      // top right
        arcPath(Vec2(c.x - radius, c.y - radius), radius, 0, quarter, steps)                    // bottom right
        arcPath(Vec2(a.x + radius, c.y - radius), radius, quarter, 2 * quarter, steps)          // bottom left
    }
}
