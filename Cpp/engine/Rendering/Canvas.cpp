#include "Rendering/Canvas.hpp"

namespace lm {

void Canvas::begin(Vec2 sizeInPoints) {
    size_ = sizeInPoints;
    vertices_.clear();
    batches_.clear();
}

void Canvas::setFont(const FontMetrics* metrics, const Texture* atlas) {
    font_ = metrics;
    fontAtlas_ = atlas;
}

Canvas::Batch& Canvas::batchFor(const Texture* texture, bool isText) {
    // Consecutive shapes that use the same texture share a draw call.
    if (batches_.empty() || batches_.back().texture != texture || batches_.back().isText != isText) {
        batches_.push_back(Batch{texture, isText, uint32_t(vertices_.size()), 0});
    }
    return batches_.back();
}

void Canvas::quad(Vec2 a, Vec2 b, Vec2 c, Vec2 d, Vec2 uvA, Vec2 uvB, Vec2 uvC, Vec2 uvD, Vec4 color,
                  const Texture* texture, bool isText) {
    Batch& batch = batchFor(texture, isText);
    const gpu::CanvasVertex corners[6] = {{a, uvA, color}, {b, uvB, color}, {c, uvC, color},
                                          {a, uvA, color}, {c, uvC, color}, {d, uvD, color}};
    vertices_.insert(vertices_.end(), std::begin(corners), std::end(corners));
    batch.vertexCount += 6;
}

void Canvas::triangle(Vec2 a, Vec2 b, Vec2 c, Vec4 color) {
    Batch& batch = batchFor(nullptr, false);
    const Vec2 uv{0.5f, 0.5f};
    vertices_.push_back({a, uv, color});
    vertices_.push_back({b, uv, color});
    vertices_.push_back({c, uv, color});
    batch.vertexCount += 3;
}

void Canvas::rect(Vec2 position, Vec2 size, Vec4 color) {
    image(nullptr, position, size, color);
}

void Canvas::rectOutline(Vec2 position, Vec2 size, float thickness, Vec4 color) {
    rect(position, Vec2{size.x, thickness}, color);
    rect(Vec2{position.x, position.y + size.y - thickness}, Vec2{size.x, thickness}, color);
    rect(Vec2{position.x, position.y + thickness}, Vec2{thickness, size.y - 2 * thickness}, color);
    rect(Vec2{position.x + size.x - thickness, position.y + thickness}, Vec2{thickness, size.y - 2 * thickness}, color);
}

void Canvas::line(Vec2 from, Vec2 to, float thickness, Vec4 color) {
    Vec2 direction = to - from;
    float length = simd::length(direction);
    if (length < 1e-5f) return;
    Vec2 side = Vec2{-direction.y, direction.x} / length * (thickness * 0.5f);
    const Vec2 uv{0.5f, 0.5f};
    quad(from + side, from - side, to - side, to + side, uv, uv, uv, uv, color, nullptr, false);
}

void Canvas::circle(Vec2 center, float radius, Vec4 color, int segments) {
    segments = std::max(segments, 3);
    Vec2 previous = center + Vec2{radius, 0};
    for (int i = 1; i <= segments; i++) {
        float angle = float(i) / float(segments) * 2.0f * kPi;
        Vec2 current = center + Vec2{std::cos(angle), std::sin(angle)} * radius;
        triangle(center, previous, current, color);
        previous = current;
    }
}

void Canvas::image(const Texture* texture, Vec2 position, Vec2 size, Vec4 tint, Vec2 uvMin, Vec2 uvMax) {
    Vec2 a = position, c = position + size;
    quad(a, Vec2{a.x, c.y}, c, Vec2{c.x, a.y},
         uvMin, Vec2{uvMin.x, uvMax.y}, uvMax, Vec2{uvMax.x, uvMin.y}, tint, texture, false);
}

Vec2 Canvas::measureText(std::string_view text, float size) const {
    return font_ ? font_->measure(text, size) : Vec2{0, 0};
}

void Canvas::text(std::string_view text, Vec2 position, float size, Vec4 color, TextAlign align) {
    if (!font_ || !fontAtlas_) return;
    float scale = size / font_->bakedSize;
    Vec2 atlasSize{font_->atlasWidth, font_->atlasHeight};
    float penY = position.y;

    // Lay the text out one line at a time, because alignment needs each line's width.
    size_t lineStart = 0;
    while (lineStart <= text.size()) {
        size_t lineEnd = text.find('\n', lineStart);
        if (lineEnd == std::string_view::npos) lineEnd = text.size();
        std::string_view lineText = text.substr(lineStart, lineEnd - lineStart);

        float penX = position.x;
        if (align != TextAlign::Left) {
            float width = font_->measure(lineText, size).x;
            penX -= align == TextAlign::Center ? width * 0.5f : width;
        }
        for (size_t i = 0; i < lineText.size();) {
            const Glyph* glyph = font_->glyph(decodeUTF8(lineText, i));
            if (!glyph) continue;
            if (glyph->width > 0 && glyph->height > 0) {
                Vec2 a{penX + glyph->offsetX * scale, penY + glyph->offsetY * scale};
                Vec2 c = a + Vec2{glyph->width, glyph->height} * scale;
                Vec2 uvA = Vec2{glyph->x, glyph->y} / atlasSize;
                Vec2 uvC = Vec2{glyph->x + glyph->width, glyph->y + glyph->height} / atlasSize;
                quad(a, Vec2{a.x, c.y}, c, Vec2{c.x, a.y},
                     uvA, Vec2{uvA.x, uvC.y}, uvC, Vec2{uvC.x, uvA.y}, color, fontAtlas_, true);
            }
            penX += glyph->advance * scale;
        }
        penY += font_->lineHeight * scale;
        lineStart = lineEnd + 1;
    }
}

}  // namespace lm
