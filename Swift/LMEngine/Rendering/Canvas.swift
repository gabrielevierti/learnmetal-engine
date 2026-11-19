// Canvas.swift
// Immediate-mode 2D drawing for HUDs, menus and 2D games.
//
// "Immediate mode" means there are no 2D objects to keep around: every frame the game
// says what to draw, in order, and the canvas turns the calls into triangles. The
// renderer draws them in as few draw calls as possible (one per change of texture).
//
// Coordinates are in points with the origin at the top left, like the window system's.
// Colors are sRGB with straight alpha, the values a color picker shows.

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
    }

    /// The drawable area, in points.
    public private(set) var size = Vec2(0, 0)
    public private(set) var vertices: [CanvasVertex] = []
    public private(set) var batches: [Batch] = []

    private var font: FontMetrics?
    private var fontAtlas: Texture?

    /// The distance-field spread of the current font, which the text shader needs.
    public var fontDistanceRange: Float { font?.distanceRange ?? 1 }

    public init() {}

    // MARK: Used by the engine

    public func begin(size sizeInPoints: Vec2) {
        size = sizeInPoints
        vertices.removeAll(keepingCapacity: true)
        batches.removeAll(keepingCapacity: true)
    }

    public func setFont(_ metrics: FontMetrics?, atlas: Texture?) {
        font = metrics
        fontAtlas = atlas
    }

    // MARK: Drawing

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
        let direction = to - from
        let length = simd_length(direction)
        if length < 1e-5 { return }
        let side = Vec2(-direction.y, direction.x) / length * (thickness * 0.5)
        let uv = Vec2(0.5, 0.5)
        quad(from + side, from - side, to - side, to + side, uv, uv, uv, uv, color, nil, false)
    }

    public func circle(center: Vec2, radius: Float, _ color: Vec4, segments: Int = 32) {
        let count = max(segments, 3)
        var previous = center + Vec2(radius, 0)
        for i in 1...count {
            let angle = Float(i) / Float(count) * 2 * Float.pi
            let current = center + Vec2(cos(angle), sin(angle)) * radius
            triangle(center, previous, current, color)
            previous = current
        }
    }

    /// Draws a texture, or part of one: `uvMin` and `uvMax` select a region, which is
    /// how sprite sheets work.
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

    /// Makes sure the last batch can take shapes with this texture. Consecutive shapes
    /// that use the same texture share a draw call.
    private func ensureBatch(_ texture: Texture?, _ isText: Bool) {
        if let last = batches.last, last.texture === texture, last.isText == isText { return }
        batches.append(Batch(texture: texture, isText: isText, firstVertex: vertices.count, vertexCount: 0))
    }

    private func quad(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2, _ uvA: Vec2, _ uvB: Vec2, _ uvC: Vec2, _ uvD: Vec2,
                      _ color: Vec4, _ texture: Texture?, _ isText: Bool) {
        ensureBatch(texture, isText)
        vertices.append(CanvasVertex(position: a, uv: uvA, color: color))
        vertices.append(CanvasVertex(position: b, uv: uvB, color: color))
        vertices.append(CanvasVertex(position: c, uv: uvC, color: color))
        vertices.append(CanvasVertex(position: a, uv: uvA, color: color))
        vertices.append(CanvasVertex(position: c, uv: uvC, color: color))
        vertices.append(CanvasVertex(position: d, uv: uvD, color: color))
        batches[batches.count - 1].vertexCount += 6
    }

    private func triangle(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ color: Vec4) {
        ensureBatch(nil, false)
        let uv = Vec2(0.5, 0.5)
        vertices.append(CanvasVertex(position: a, uv: uv, color: color))
        vertices.append(CanvasVertex(position: b, uv: uv, color: color))
        vertices.append(CanvasVertex(position: c, uv: uv, color: color))
        batches[batches.count - 1].vertexCount += 3
    }
}
