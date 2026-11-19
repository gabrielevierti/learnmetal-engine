#include "UI/Gui.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace lm {

namespace {

const float kPopupRows = 10.0f;

/// Removes the last character of UTF-8 text, however many bytes it takes.
void removeLastCharacter(std::string& text) {
    if (text.empty()) return;
    size_t i = text.size() - 1;
    while (i > 0 && (static_cast<unsigned char>(text[i]) & 0xC0) == 0x80) i--;     // skip continuation bytes
    text.erase(i);
}

std::string formatNumber(float value) {
    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "%.3f", double(value));
    std::string text = buffer;
    // 1.500 reads better as 1.5, and 2.000 as 2.
    while (text.back() == '0') text.pop_back();
    if (text.back() == '.') text.pop_back();
    if (text == "-0") text = "0";
    return text;
}

}  // namespace

void Gui::begin(Canvas& canvas, const Input& input) {
    canvas_ = &canvas;
    input_ = &input;
    mouse_ = input.mousePosition();
    changed_ = false;

    // Whether the pointer is over the interface is known from where the panels were in
    // the previous frame: this frame's panels have not been declared yet.
    previousPanels_ = panels_;
    panels_.clear();
    mouseOverGui_ = false;
    for (const Rect& rect : previousPanels_) mouseOverGui_ = mouseOverGui_ || rect.contains(mouse_);
    mouseFree_ = popup_.id == 0;

    if (active_ != 0) dragDistance_ += std::abs(input.mouseDelta().x) + std::abs(input.mouseDelta().y);

    // Typing goes to the focused field.
    if (focus_ != 0) {
        if (selectAll_ && (!input.textInput().empty() || input.wasPressed(Key::Backspace))) {
            editBuffer_.clear();
            selectAll_ = false;
        } else if (input.wasPressed(Key::Backspace)) {
            removeLastCharacter(editBuffer_);
        }
        editBuffer_ += input.textInput();
        if (input.wasPressed(Key::Enter) || input.wasPressed(Key::Tab)) commitFocus_ = true;
        if (input.wasPressed(Key::Escape)) focus_ = 0;                  // gives up the edit
        if (input.wasPressed(MouseButton::Left)) commitFocus_ = true;   // a click anywhere ends it
    }
}

void Gui::end() {
    // A control that was pressed stays active until the button comes up, wherever the pointer went.
    if (!input_->isDown(MouseButton::Left)) {
        active_ = 0;
        dragDistance_ = 0;
    }
    // An edit whose field did not come by to collect it (the field is gone) is dropped.
    if (commitFocus_ && committed_ == 0) focus_ = 0;
    commitFocus_ = false;
    committed_ = 0;

    // The pop-up is drawn last, so that it is on top of every panel.
    if (popup_.id != 0) {
        float rowHeight = style.rowHeight;
        float visible = std::min(float(popup_.items.size()), kPopupRows);
        Rect box{Vec2{popup_.anchor.position.x, popup_.anchor.position.y + popup_.anchor.size.y},
                 Vec2{popup_.anchor.size.x, visible * rowHeight}};
        // Open upward if there is no room below.
        if (box.position.y + box.size.y > canvas_->size().y) box.position.y = popup_.anchor.position.y - box.size.y;
        panels_.push_back(box);

        float maxScroll = std::max(0.0f, float(popup_.items.size()) - kPopupRows);
        if (box.contains(mouse_)) popup_.scroll = std::clamp(popup_.scroll - input_->scrollDelta(), 0.0f, maxScroll);
        int first = int(popup_.scroll);

        canvas_->rect(box.position, box.size, style.title);
        canvas_->rectOutline(box.position, box.size, 1, style.accent);
        bool clicked = input_->wasPressed(MouseButton::Left);
        for (int row = 0; row < int(visible); row++) {
            int item = first + row;
            Rect rect{Vec2{box.position.x, box.position.y + float(row) * rowHeight}, Vec2{box.size.x, rowHeight}};
            bool hot = rect.contains(mouse_);
            if (hot || item == popup_.current) canvas_->rect(rect.position, rect.size, hot ? style.fieldHot : style.field);
            drawText(popup_.items[size_t(item)], Rect{rect.position + Vec2{6, 0}, rect.size - Vec2{12, 0}},
                     item == popup_.current ? style.accent : style.text);
            if (hot && clicked) {
                popupResultId_ = popup_.id;
                popupResult_ = item;
            }
        }
        // Any click closes it: on an item (chosen above) or outside (nothing chosen).
        if (clicked && !popup_.anchor.contains(mouse_)) popup_ = Popup{};
    }
}

// ---------------------------------------------------------------- panels

void Gui::beginPanel(const std::string& title, Vec2 position, Vec2 size) {
    panelId_ = std::hash<std::string>()(title);
    counter_ = 0;
    Rect whole{position, size};
    panels_.push_back(whole);

    float titleHeight = style.rowHeight + 4;
    canvas_->rect(position, size, style.panel);
    canvas_->rect(position, Vec2{size.x, titleHeight}, style.title);
    canvas_->rectOutline(position, size, 1, style.outline);
    canvas_->text(title, position + Vec2{style.padding, (titleHeight - style.fontSize) * 0.5f - 1}, style.fontSize, style.textDim);

    content_ = Rect{position + Vec2{style.padding, titleHeight + style.padding},
                    size - Vec2{style.padding * 2, titleHeight + style.padding * 2}};
    float& scroll = scroll_[panelId_];
    if (whole.contains(mouse_) && mouseFree_) scroll -= input_->scrollDelta() * (style.rowHeight + style.spacing) * 2;    // two rows per notch
    scroll = std::max(scroll, 0.0f);
    contentTop_ = content_.position.y - scroll;
    cursorY_ = contentTop_;
}

void Gui::endPanel() {
    // Now the height of the content is known: do not let the panel scroll past its end.
    float contentHeight = cursorY_ - contentTop_;
    float maxScroll = std::max(0.0f, contentHeight - content_.size.y);
    float& scroll = scroll_[panelId_];
    scroll = std::min(scroll, maxScroll);
    if (maxScroll > 0) {
        // A thin bar on the right edge shows where we are.
        float track = content_.size.y;
        float bar = std::max(16.0f, track * content_.size.y / contentHeight);
        float offset = (track - bar) * (scroll / maxScroll);
        canvas_->rect(Vec2{content_.position.x + content_.size.x + 2, content_.position.y + offset}, Vec2{3, bar}, style.fieldHot);
    }
    panelId_ = 0;
}

uint64_t Gui::makeId(const std::string& label) {
    // The label alone is not enough: an inspector may show two fields called "Radius".
    // The position of the control in its panel tells them apart.
    uint64_t id = panelId_ * 1099511628211ULL + std::hash<std::string>()(label);
    id = id * 1099511628211ULL + uint64_t(++counter_);
    return id == 0 ? 1 : id;
}

/// Reserves the next row. Returns false if it falls outside the panel (scrolled away):
/// the control then draws nothing and does not react.
bool Gui::nextRow(Rect& row) {
    row = Rect{Vec2{content_.position.x, cursorY_}, Vec2{content_.size.x, style.rowHeight}};
    cursorY_ += style.rowHeight + style.spacing;
    return row.position.y >= content_.position.y - 0.5f && row.position.y + row.size.y <= content_.position.y + content_.size.y + 0.5f;
}

void Gui::splitRow(const Rect& row, const std::string& label, Rect& field) {
    float labelWidth = std::floor(row.size.x * style.labelWidth);
    drawText(label, Rect{row.position, Vec2{labelWidth - 4, row.size.y}}, style.textDim);
    field = Rect{row.position + Vec2{labelWidth, 0}, Vec2{row.size.x - labelWidth, row.size.y}};
}

/// The mouse button went down on this rectangle in this frame.
bool Gui::pressed(uint64_t id, const Rect& rect) {
    if (!mouseFree_ || active_ != 0 || !rect.contains(mouse_) || !input_->wasPressed(MouseButton::Left)) return false;
    active_ = id;
    dragDistance_ = 0;
    return true;
}

std::string Gui::fitted(const std::string& text, float width) const {
    if (canvas_->measureText(text, style.fontSize).x <= width) return text;
    std::string shorter = text;
    while (!shorter.empty() && canvas_->measureText(shorter + "..", style.fontSize).x > width) removeLastCharacter(shorter);
    return shorter + "..";
}

void Gui::drawText(const std::string& text, const Rect& rect, Vec4 color, TextAlign align) {
    float y = rect.position.y + (rect.size.y - style.fontSize) * 0.5f - 1;
    float x = align == TextAlign::Left ? rect.position.x : align == TextAlign::Center ? rect.position.x + rect.size.x * 0.5f
                                                                                      : rect.position.x + rect.size.x;
    canvas_->text(fitted(text, rect.size.x), Vec2{x, y}, style.fontSize, color, align);
}

// ---------------------------------------------------------------- simple controls

void Gui::heading(const std::string& text) {
    Rect row;
    if (!nextRow(row)) return;
    drawText(text, row, style.accent);
    canvas_->rect(Vec2{row.position.x, row.position.y + row.size.y - 1}, Vec2{row.size.x, 1}, style.field);
}

void Gui::label(const std::string& text) {
    Rect row;
    if (nextRow(row)) drawText(text, row, style.textDim);
}

void Gui::separator() {
    cursorY_ += style.spacing * 2;
}

bool Gui::button(const std::string& text) {
    return buttonRow({text}) == 0;
}

int Gui::buttonRow(const std::vector<std::string>& labels) {
    Rect row;
    bool visible = nextRow(row);
    int clicked = -1;
    float gap = 4;
    float width = (row.size.x - gap * float(labels.size() - 1)) / float(labels.size());
    for (size_t i = 0; i < labels.size(); i++) {
        uint64_t id = makeId(labels[i]);
        if (!visible) continue;
        Rect rect{Vec2{row.position.x + float(i) * (width + gap), row.position.y}, Vec2{width, row.size.y}};
        bool hot = mouseFree_ && rect.contains(mouse_);
        if (pressed(id, rect)) clicked = int(i);
        canvas_->rect(rect.position, rect.size, active_ == id ? style.accent : hot ? style.fieldHot : style.field);
        drawText(labels[i], rect, active_ == id ? style.title : style.text, TextAlign::Center);
    }
    return clicked;
}

bool Gui::tabs(const std::vector<std::string>& labels, int& current) {
    Rect row;
    bool visible = nextRow(row);
    bool switched = false;
    float width = row.size.x / float(labels.size());
    for (size_t i = 0; i < labels.size(); i++) {
        uint64_t id = makeId(labels[i]);
        if (!visible) continue;
        Rect rect{Vec2{row.position.x + float(i) * width, row.position.y}, Vec2{width, row.size.y}};
        if (pressed(id, rect) && current != int(i)) {
            current = int(i);
            switched = true;
        }
        bool selected = current == int(i);
        drawText(labels[i], rect, selected ? style.accent : style.textDim, TextAlign::Center);
        canvas_->rect(Vec2{rect.position.x, rect.position.y + rect.size.y - 2}, Vec2{rect.size.x, 2}, selected ? style.accent : style.field);
    }
    return switched;
}

bool Gui::selectable(const std::string& text, bool selected, float indent) {
    uint64_t id = makeId(text);
    Rect row;
    if (!nextRow(row)) return false;
    bool hot = mouseFree_ && row.contains(mouse_);
    bool clicked = pressed(id, row);
    if (selected) canvas_->rect(row.position, row.size, Vec4{style.accent.x, style.accent.y, style.accent.z, 0.28f});
    else if (hot) canvas_->rect(row.position, row.size, style.field);
    drawText(text, Rect{row.position + Vec2{6 + indent, 0}, row.size - Vec2{12 + indent, 0}}, selected ? style.text : style.textDim);
    return clicked;
}

bool Gui::checkbox(const std::string& label, bool& value) {
    uint64_t id = makeId(label);
    Rect row, field;
    if (!nextRow(row)) return false;
    splitRow(row, label, field);
    float side = row.size.y - 6;
    Rect box{field.position + Vec2{0, 3}, Vec2{side, side}};
    bool clicked = pressed(id, box);
    if (clicked) {
        value = !value;
        changed_ = true;
    }
    canvas_->rect(box.position, box.size, mouseFree_ && box.contains(mouse_) ? style.fieldHot : style.field);
    if (value) canvas_->rect(box.position + Vec2{4, 4}, box.size - Vec2{8, 8}, style.accent);
    return clicked;
}

// ---------------------------------------------------------------- numbers and text

/// The text being typed into the focused field. Returns true when the edit was confirmed
/// in this frame, with `value` replaced by what was typed.
bool Gui::editText(uint64_t id, const Rect& rect, std::string& value) {
    if (focus_ != id) return false;
    if (commitFocus_ && !(rect.contains(mouse_) && input_->wasPressed(MouseButton::Left))) {
        // Confirmed by Enter or Tab, or by a click somewhere else.
        bool differs = editBuffer_ != value;
        value = editBuffer_;
        focus_ = 0;
        committed_ = id;
        return differs;
    }
    committed_ = id;                    // still editing: tells end() the field is alive
    canvas_->rect(rect.position, rect.size, style.fieldHot);
    canvas_->rectOutline(rect.position, rect.size, 1, style.accent);
    Rect inner{rect.position + Vec2{6, 0}, rect.size - Vec2{12, 0}};
    if (selectAll_) {
        float width = std::min(canvas_->measureText(editBuffer_, style.fontSize).x, inner.size.x);
        canvas_->rect(Vec2{inner.position.x - 2, rect.position.y + 3}, Vec2{width + 4, rect.size.y - 6},
                      Vec4{style.accent.x, style.accent.y, style.accent.z, 0.35f});
    }
    drawText(editBuffer_, inner, style.text);
    // The insertion mark, after the last character.
    float end = std::min(canvas_->measureText(editBuffer_, style.fontSize).x, inner.size.x);
    canvas_->rect(Vec2{inner.position.x + end + 1, rect.position.y + 4}, Vec2{1, rect.size.y - 8}, style.accent);
    return false;
}

bool Gui::numberField(uint64_t id, const Rect& rect, float& value, float speed, float minimum, float maximum, Vec4 mark) {
    // Being typed into?
    if (focus_ == id) {
        std::string text = formatNumber(value);
        if (editText(id, rect, text)) {
            char* parsedEnd = nullptr;
            float parsed = std::strtof(text.c_str(), &parsedEnd);
            if (parsedEnd != text.c_str()) {            // keep the old value if this is not a number
                value = std::clamp(parsed, minimum, maximum);
                changed_ = true;
                return true;
            }
        }
        return false;
    }

    bool changedNow = false;
    pressed(id, rect);
    if (active_ == id) {
        if (input_->isDown(MouseButton::Left)) {
            // Dragging: so many units per point of pointer travel.
            float delta = input_->mouseDelta().x * speed;
            if (delta != 0 && dragDistance_ > 3) {
                value = std::clamp(value + delta, minimum, maximum);
                changedNow = true;
            }
        } else if (dragDistance_ <= 3) {
            // Pressed and released without moving: a click. Switch to typing.
            focus_ = id;
            editBuffer_ = formatNumber(value);
            selectAll_ = true;
        }
    }
    bool hot = mouseFree_ && rect.contains(mouse_);
    canvas_->rect(rect.position, rect.size, active_ == id || hot ? style.fieldHot : style.field);
    canvas_->rect(rect.position, Vec2{2, rect.size.y}, mark);
    drawText(formatNumber(value), Rect{rect.position + Vec2{6, 0}, rect.size - Vec2{10, 0}}, style.text);
    if (changedNow) changed_ = true;
    return changedNow;
}

bool Gui::dragFloat(const std::string& label, float& value, float speed, float minimum, float maximum) {
    uint64_t id = makeId(label);
    Rect row, field;
    if (!nextRow(row)) return false;
    splitRow(row, label, field);
    return numberField(id, field, value, speed, minimum, maximum, style.field);
}

bool Gui::dragVec3(const std::string& label, Vec3& value, float speed) {
    const Vec4 marks[3] = {rgb(0xe5484d), rgb(0x46a758), rgb(0x3e7bfa)};       // x red, y green, z blue, as on the gizmo
    uint64_t ids[3] = {makeId(label), makeId(label), makeId(label)};
    Rect row, field;
    if (!nextRow(row)) return false;
    splitRow(row, label, field);
    float gap = 3, width = (field.size.x - gap * 2) / 3;
    bool any = false;
    for (int i = 0; i < 3; i++) {
        float component = value[i];
        Rect rect{Vec2{field.position.x + float(i) * (width + gap), field.position.y}, Vec2{width, field.size.y}};
        if (numberField(ids[i], rect, component, speed, -std::numeric_limits<float>::infinity(),
                        std::numeric_limits<float>::infinity(), marks[i])) {
            value[i] = component;
            any = true;
        }
    }
    return any;
}

bool Gui::color(const std::string& label, Vec3& value) {
    uint64_t ids[3] = {makeId(label), makeId(label), makeId(label)};
    Rect row, field;
    if (!nextRow(row)) return false;
    splitRow(row, label, field);
    // The swatch shows the color as the screen will: linear values encoded to sRGB, and
    // clipped at 1 (the canvas takes sRGB colors).
    float side = field.size.y;
    Vec3 shown{std::pow(saturate(value.x), 1 / 2.2f), std::pow(saturate(value.y), 1 / 2.2f), std::pow(saturate(value.z), 1 / 2.2f)};
    canvas_->rect(field.position, Vec2{side, side}, Vec4{shown.x, shown.y, shown.z, 1});
    canvas_->rectOutline(field.position, Vec2{side, side}, 1, style.outline);

    float gap = 3, left = field.position.x + side + gap, width = (field.size.x - side - gap * 3) / 3;
    bool any = false;
    for (int i = 0; i < 3; i++) {
        float component = value[i];
        Rect rect{Vec2{left + float(i) * (width + gap), field.position.y}, Vec2{width, field.size.y}};
        if (numberField(ids[i], rect, component, 0.005f, 0.0f, 100.0f, style.field)) {
            value[i] = component;
            any = true;
        }
    }
    return any;
}

bool Gui::textField(const std::string& label, std::string& value) {
    uint64_t id = makeId(label);
    Rect row, field;
    if (!nextRow(row)) return false;
    splitRow(row, label, field);
    if (focus_ == id) {
        if (editText(id, field, value)) {
            changed_ = true;
            return true;
        }
        return false;
    }
    if (pressed(id, field)) {
        focus_ = id;
        editBuffer_ = value;
        selectAll_ = true;
        commitFocus_ = false;           // this very click must not end the edit it starts
    }
    canvas_->rect(field.position, field.size, mouseFree_ && field.contains(mouse_) ? style.fieldHot : style.field);
    drawText(value, Rect{field.position + Vec2{6, 0}, field.size - Vec2{12, 0}}, style.text);
    return false;
}

bool Gui::combo(const std::string& label, int& index, const std::vector<std::string>& items) {
    uint64_t id = makeId(label);
    // A choice made in the pop-up during the previous frame arrives here.
    bool chosen = false;
    if (popupResultId_ == id) {
        if (popupResult_ != index && popupResult_ < int(items.size())) {
            index = popupResult_;
            chosen = true;
            changed_ = true;
        }
        popupResultId_ = 0;
        popup_ = Popup{};
    }

    Rect row, field;
    if (!nextRow(row)) return chosen;
    splitRow(row, label, field);
    bool isOpen = popup_.id == id;
    // The combo itself must react while its own pop-up is open (to close it), so it
    // looks at the mouse directly instead of going through pressed().
    if (field.contains(mouse_) && input_->wasPressed(MouseButton::Left) && active_ == 0 && (mouseFree_ || isOpen)) {
        active_ = id;
        if (isOpen) {
            popup_ = Popup{};
        } else if (!items.empty()) {
            popup_ = Popup{};
            popup_.id = id;
            popup_.items = items;
            popup_.current = index;
            popup_.scroll = std::max(0.0f, std::min(float(index) - 2, float(items.size()) - kPopupRows));
        }
    }
    if (popup_.id == id) popup_.anchor = field;         // follows the panel if it scrolls

    canvas_->rect(field.position, field.size, isOpen || (mouseFree_ && field.contains(mouse_)) ? style.fieldHot : style.field);
    std::string shown = index >= 0 && index < int(items.size()) ? items[size_t(index)] : std::string("none");
    drawText(shown, Rect{field.position + Vec2{6, 0}, field.size - Vec2{24, 0}}, index >= 0 ? style.text : style.textDim);
    // A small "v" on the right says that this opens a list.
    Vec2 tip = field.position + Vec2{field.size.x - 11, field.size.y * 0.5f + 3};
    canvas_->line(tip + Vec2{-4, -5}, tip, 1.5f, style.textDim);
    canvas_->line(tip + Vec2{4, -5}, tip, 1.5f, style.textDim);
    return chosen;
}

}  // namespace lm
