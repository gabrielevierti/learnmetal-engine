// ImageDecoder.swift
// Reads PNG and JPEG files into plain bytes, using the system's Image I/O framework.
//
// Core Graphics can draw any image into a bitmap, but drawing does two things a game
// does not want: it multiplies colors by alpha, and it color-matches. A normal map or
// a distance field is data, not a picture, and must arrive bit for bit. So the usual
// layouts are copied straight from the decoded image, and drawing is only the
// fallback for unusual files.

import CoreGraphics
import Foundation
import ImageIO

struct DecodedImage {
    var pixels: [UInt8]         // rows from the top; 1 or 4 bytes per pixel
    var width: Int
    var height: Int
}

/// `channels` is 4 (red, green, blue, alpha) or 1 (the red channel only).
func decodeImage(path: String, channels: Int) -> DecodedImage? {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    guard let pixels = copiedPixels(image, channels: channels) ?? drawnPixels(image, channels: channels) else { return nil }
    return DecodedImage(pixels: pixels, width: image.width, height: image.height)
}

/// The decoded bytes as they are, for 8-bit gray, gray + alpha, RGB and RGBA images.
private func copiedPixels(_ image: CGImage, channels: Int) -> [UInt8]? {
    let model = image.colorSpace?.model
    let samples = image.bitsPerPixel / 8                // bytes per pixel in the file's own layout
    let isGray = model == .monochrome && (samples == 1 || samples == 2)
    let isColor = model == .rgb && (samples == 3 || samples == 4)
    guard image.bitsPerComponent == 8, isGray || isColor else { return nil }

    // Only layouts with the color first and the alpha last.
    let alpha = image.alphaInfo
    if alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst || alpha == .alphaOnly { return nil }
    let order = image.bitmapInfo.intersection(.byteOrderMask)
    if order == .byteOrder32Little || order == .byteOrder16Little { return nil }
    let hasAlpha = alpha == .last || alpha == .premultipliedLast
    let isPremultiplied = alpha == .premultipliedLast

    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
    let width = image.width, height = image.height, rowBytes = image.bytesPerRow
    guard CFDataGetLength(data) >= rowBytes * (height - 1) + width * samples else { return nil }

    var pixels = [UInt8](repeating: 255, count: width * height * channels)
    for y in 0..<height {
        for x in 0..<width {
            let p = bytes + y * rowBytes + x * samples
            var r = p[0]
            var g = isGray ? p[0] : p[1]
            var b = isGray ? p[0] : p[2]
            let a: UInt8 = hasAlpha ? p[samples - 1] : 255
            if isPremultiplied && a > 0 && a < 255 {
                // Undo the multiplication by alpha, to get the color the artist painted.
                r = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                g = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                b = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
            }
            let o = (y * width + x) * channels
            pixels[o] = r
            if channels == 4 {
                pixels[o + 1] = g
                pixels[o + 2] = b
                pixels[o + 3] = a
            }
        }
    }
    return pixels
}

/// Any other image: let Core Graphics draw it into a bitmap we own.
private func drawnPixels(_ image: CGImage, channels: Int) -> [UInt8]? {
    let width = image.width, height = image.height
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    var pixels = [UInt8](repeating: 0, count: width * height * channels)
    let succeeded = pixels.withUnsafeMutableBytes { buffer -> Bool in
        let space = channels == 1 ? CGColorSpaceCreateDeviceGray() : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let info = channels == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * channels, space: space, bitmapInfo: info) else { return false }
        context.draw(image, in: rect)
        return true
    }
    if !succeeded { return nil }
    if channels == 4 {
        // A bitmap context stores colors multiplied by alpha: divide them back.
        var i = 0
        while i < pixels.count {
            let a = Int(pixels[i + 3])
            if a > 0 && a < 255 {
                for k in 0..<3 { pixels[i + k] = UInt8(min(255, (Int(pixels[i + k]) * 255 + a / 2) / a)) }
            }
            i += 4
        }
    }
    return pixels
}
