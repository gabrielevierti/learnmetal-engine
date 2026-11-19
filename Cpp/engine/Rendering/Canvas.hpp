// Canvas.hpp
// Immediate-mode 2D drawing for HUDs, menus and 2D games.
//
// "Immediate mode" means there are no 2D objects to keep around: every frame the game
// says what to draw, in order, and the canvas turns the calls into triangles. The
// renderer draws them in as few draw calls as possible (one per change of texture).
//
// Coordinates are in points with the origin at the top left, like the window system's.
// Colors are sRGB with straight alpha, the values a color picker shows.
#pragma once

#include "Assets/Font.hpp"
#include "Rendering/GPUTypes.hpp"

#include <string_view>
#include <vector>

namespace lm {

class Texture;

enum class TextAlign : uint8_t { Left, Center, Right };

/// A color from the usual hexadecimal notation: rgb(0xfe8b3c) is the LearnMetal orange.
inline Vec4 rgb(uint32_t hex, float alpha = 1.0f) {
    return Vec4{float((hex >> 16) & 0xFF) / 255.0f, float((hex >> 8) & 0xFF) / 255.0f, float(hex & 0xFF) / 255.0f, alpha};
}

class Canvas {
public:
    /// The drawable area, in points.
    Vec2 size() const { return size_; }

    void rect(Vec2 position, Vec2 size, Vec4 color);
    void rectOutline(Vec2 position, Vec2 size, float thickness, Vec4 color);
    void line(Vec2 from, Vec2 to, float thickness, Vec4 color);
    void circle(Vec2 center, float radius, Vec4 color, int segments = 32);

    /// Draws a texture, or part of one: `uvMin` and `uvMax` select a region, which is
    /// how sprite sheets work.
    void image(const Texture* texture, Vec2 position, Vec2 size, Vec4 tint = Vec4{1, 1, 1, 1},
               Vec2 uvMin = Vec2{0, 0}, Vec2 uvMax = Vec2{1, 1});

    /// Draws UTF-8 text. `position` is the top left of the first line (or its top center,
    /// or top right, depending on `align`); `size` is the font size in points.
    void text(std::string_view text, Vec2 position, float size, Vec4 color, TextAlign align = TextAlign::Left);
    Vec2 measureText(std::string_view text, float size) const;

    // ---- used by the engine

    struct Batch {
        const Texture* texture = nullptr;   // nullptr draws with solid color
        bool isText = false;                // text samples a distance field instead of colors
        uint32_t firstVertex = 0;
        uint32_t vertexCount = 0;
    };

    void begin(Vec2 sizeInPoints);
    void setFont(const FontMetrics* metrics, const Texture* atlas);
    const std::vector<gpu::CanvasVertex>& vertices() const { return vertices_; }
    const std::vector<Batch>& batches() const { return batches_; }
    /// The distance-field spread of the current font, which the text shader needs.
    float fontDistanceRange() const { return font_ ? font_->distanceRange : 1.0f; }

private:
    void quad(Vec2 a, Vec2 b, Vec2 c, Vec2 d, Vec2 uvA, Vec2 uvB, Vec2 uvC, Vec2 uvD, Vec4 color,
              const Texture* texture, bool isText);
    void triangle(Vec2 a, Vec2 b, Vec2 c, Vec4 color);
    Batch& batchFor(const Texture* texture, bool isText);

    Vec2 size_{0, 0};
    const FontMetrics* font_ = nullptr;
    const Texture* fontAtlas_ = nullptr;
    std::vector<gpu::CanvasVertex> vertices_;
    std::vector<Batch> batches_;
};

}  // namespace lm
