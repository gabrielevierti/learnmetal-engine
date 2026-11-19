// Font.swift
// A font as a game sees it: one texture with every glyph in it (an atlas) and a table
// that says where each glyph is and how to place it.
//
// The atlas stores a signed distance field: each texel holds the distance to the
// glyph's outline instead of plain coverage. The fragment shader turns that back into
// a sharp edge at any size, so one small texture serves both tiny labels and huge
// titles. Tools/bake_font.py produces the atlas and the metrics file.

import Foundation
import simd

/// One glyph. All values are in atlas texels, at the size the font was baked at.
public struct Glyph {
    public var x: Float = 0, y: Float = 0, width: Float = 0, height: Float = 0   // rectangle in the atlas
    public var offsetX: Float = 0, offsetY: Float = 0   // from the pen position (top of the line) to the rectangle's top left
    public var advance: Float = 0                       // how far the pen moves after this glyph
}

public struct FontMetrics {
    public var bakedSize: Float = 48            // the font size, in texels, the atlas was rendered at
    public var lineHeight: Float = 58
    public var distanceRange: Float = 8         // how many texels the distance field extends around an outline
    public var atlasWidth: Float = 512
    public var atlasHeight: Float = 512
    public var glyphs: [UInt32: Glyph] = [:]

    public init() {}

    /// Parses the text format written by Tools/bake_font.py.
    public static func parse(_ text: String) -> FontMetrics? {
        // The file is lines of numbers separated by spaces:
        //   info <bakedSize> <lineHeight> <distanceRange> <atlasWidth> <atlasHeight>
        //   <codepoint> <x> <y> <width> <height> <offsetX> <offsetY> <advance>
        var metrics = FontMetrics()
        var hasInfo = false
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.isEmpty { continue }
            func number(_ i: Int) -> Float { i < fields.count ? (Float(fields[i]) ?? 0) : 0 }
            if fields[0] == "info" && fields.count >= 6 {
                metrics.bakedSize = number(1)
                metrics.lineHeight = number(2)
                metrics.distanceRange = number(3)
                metrics.atlasWidth = number(4)
                metrics.atlasHeight = number(5)
                hasInfo = true
            } else if fields.count >= 8, let codepoint = UInt32(fields[0]) {
                metrics.glyphs[codepoint] = Glyph(x: number(1), y: number(2), width: number(3), height: number(4),
                                                  offsetX: number(5), offsetY: number(6), advance: number(7))
            }
        }
        return hasInfo && !metrics.glyphs.isEmpty ? metrics : nil
    }

    /// The glyph for a Unicode code point, falling back to "?" and then to nil.
    public func glyph(_ codepoint: UInt32) -> Glyph? {
        glyphs[codepoint] ?? glyphs[63]
    }

    /// Width and height of `text` when drawn at `size`. Handles newlines.
    public func measure(_ text: String, size: Float) -> Vec2 {
        let scale = size / bakedSize
        var width: Float = 0, lineWidth: Float = 0
        var lines = 1
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                width = max(width, lineWidth)
                lineWidth = 0
                lines += 1
                continue
            }
            if let g = glyph(scalar.value) { lineWidth += g.advance * scale }
        }
        return Vec2(max(width, lineWidth), Float(lines) * lineHeight * scale)
    }
}
