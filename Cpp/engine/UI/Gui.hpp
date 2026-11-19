// Gui.hpp
// A small immediate-mode user interface for tools: panels, buttons, number fields,
// text fields, lists and pop-up menus, drawn with the Canvas.
//
// "Immediate mode" means the interface is not built once and kept: every frame the
// program says what is on screen, and each call both draws a control and reports what
// the user did with it:
//
//     gui.beginPanel("Light", Vec2{16, 16}, Vec2{280, 200});
//     gui.dragFloat("Intensity", light.intensity, 0.05f, 0.0f, 100.0f);
//     if (gui.button("Reset")) light = Light{};
//     gui.endPanel();
//
// There is no list of widgets to keep in step with the data: the data is the only
// state. The few things the Gui itself must remember between frames (which control is
// being dragged, which text field has the keyboard, how far a panel is scrolled) are
// keyed by an id computed from the panel's title and the control's label.
//
// The engine's editor is built with this, and a game can use it for menus and debug
// panels. It only needs a Canvas and an Input, so it is tested without a GPU.
#pragma once

#include "Input/Input.hpp"
#include "Rendering/Canvas.hpp"

#include <limits>
#include <string>
#include <unordered_map>
#include <vector>

namespace lm {

class Gui {
public:
    struct Style {
        float fontSize = 13.0f;
        float rowHeight = 22.0f;
        float spacing = 3.0f;               // between rows
        float padding = 8.0f;               // inside a panel
        float labelWidth = 0.38f;           // share of a row taken by the label of a field
        Vec4 panel = rgb(0x14181f, 0.94f);
        Vec4 title = rgb(0x0d1015, 0.98f);
        Vec4 field = rgb(0x262c36);
        Vec4 fieldHot = rgb(0x323a47);
        Vec4 accent = rgb(0xfe8b3c);        // the LearnMetal orange
        Vec4 text = rgb(0xe6e9ee);
        Vec4 textDim = rgb(0x8d96a3);
        Vec4 outline = rgb(0x000000, 0.5f);
    };
    Style style;

    /// Call once per frame before any control, and end() after the last one.
    void begin(Canvas& canvas, const Input& input);
    void end();

    /// True if the pointer is over a panel or a control is in use: the program should then
    /// leave the mouse alone (not select or move things in the 3D view).
    bool wantsMouse() const { return mouseOverGui_ || active_ != 0 || popup_.id != 0; }
    /// True while a text field has the keyboard: the program should ignore its shortcuts.
    bool wantsKeyboard() const { return focus_ != 0; }
    /// True if any control changed a value during this frame.
    bool changed() const { return changed_; }
    /// True while a control is being dragged or edited: an edit that is not finished yet.
    bool isBusy() const { return active_ != 0 || focus_ != 0; }

    // ---- panels. Controls go between beginPanel and endPanel, one per row, top to bottom.
    // A panel scrolls with the mouse wheel when its content is taller than it is.
    void beginPanel(const std::string& title, Vec2 position, Vec2 size);
    void endPanel();

    // ---- controls. Those that edit a value return true in the frame it changed.
    void heading(const std::string& text);
    void label(const std::string& text);
    void separator();
    bool button(const std::string& text);
    /// Several buttons on one row. Returns the position of the one clicked, or -1.
    int buttonRow(const std::vector<std::string>& labels);
    /// Like buttonRow, but one stays selected.
    bool tabs(const std::vector<std::string>& labels, int& current);
    /// A row of a list: highlighted when `selected`, returns true when clicked.
    bool selectable(const std::string& text, bool selected, float indent = 0.0f);
    bool checkbox(const std::string& label, bool& value);
    /// A number changed by dragging sideways; a click without dragging lets you type it.
    bool dragFloat(const std::string& label, float& value, float speed = 0.01f,
                   float minimum = -std::numeric_limits<float>::infinity(), float maximum = std::numeric_limits<float>::infinity());
    bool dragVec3(const std::string& label, Vec3& value, float speed = 0.01f);
    /// Three numbers and a swatch. Colors are linear; values above 1 are allowed (they bloom).
    bool color(const std::string& label, Vec3& value);
    /// Returns true when the text was changed and confirmed (Enter, or a click elsewhere).
    bool textField(const std::string& label, std::string& value);
    /// A pop-up list. `index` may be -1 for "nothing chosen".
    bool combo(const std::string& label, int& index, const std::vector<std::string>& items);

private:
    struct Rect {
        Vec2 position{0, 0}, size{0, 0};
        bool contains(Vec2 p) const {
            return p.x >= position.x && p.y >= position.y && p.x < position.x + size.x && p.y < position.y + size.y;
        }
    };
    struct Popup {
        uint64_t id = 0;                    // the combo that opened it; 0 when closed
        Rect anchor;
        std::vector<std::string> items;
        int current = -1;
        float scroll = 0;
    };

    uint64_t makeId(const std::string& label);
    bool nextRow(Rect& row);
    void splitRow(const Rect& row, const std::string& label, Rect& field);
    bool pressed(uint64_t id, const Rect& rect);
    bool numberField(uint64_t id, const Rect& rect, float& value, float speed, float minimum, float maximum, Vec4 mark);
    bool editText(uint64_t id, const Rect& rect, std::string& value);
    void drawText(const std::string& text, const Rect& rect, Vec4 color, TextAlign align = TextAlign::Left);
    std::string fitted(const std::string& text, float width) const;

    Canvas* canvas_ = nullptr;
    const Input* input_ = nullptr;
    Vec2 mouse_{0, 0};
    bool mouseOverGui_ = false;
    bool changed_ = false;
    bool mouseFree_ = true;                 // false while a pop-up is open: controls under it must not react

    uint64_t active_ = 0;                   // the control the mouse button went down on
    float dragDistance_ = 0;                // how far the pointer moved since then
    uint64_t focus_ = 0;                    // the field being typed into
    std::string editBuffer_;
    bool selectAll_ = false;                // a fresh edit: the first key replaces the whole text
    bool commitFocus_ = false;              // the edit ended: its field picks the buffer up on its next call
    uint64_t committed_ = 0;

    // The panel being filled.
    uint64_t panelId_ = 0;
    Rect content_;                          // where rows may appear
    float cursorY_ = 0;
    float contentTop_ = 0;
    int counter_ = 0;
    std::unordered_map<uint64_t, float> scroll_;
    std::vector<Rect> panels_, previousPanels_;

    Popup popup_;
    uint64_t popupResultId_ = 0;            // set by end(), read by the combo on the next frame
    int popupResult_ = -1;
};

}  // namespace lm
