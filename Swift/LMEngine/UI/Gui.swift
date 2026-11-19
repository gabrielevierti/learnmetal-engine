// Gui.swift
// A small immediate-mode user interface for tools: panels, buttons, number fields,
// text fields, lists and pop-up menus, drawn with the Canvas.
//
// "Immediate mode" means the interface is not built once and kept: every frame the
// program says what is on screen, and each call both draws a control and reports what
// the user did with it:
//
//     gui.beginPanel("Light", position: Vec2(16, 16), size: Vec2(280, 200))
//     gui.dragFloat("Intensity", &light.intensity, speed: 0.05, range: 0...100)
//     if gui.button("Reset") { light = Light() }
//     gui.endPanel()
//
// There is no list of widgets to keep in step with the data: the data is the only
// state. The few things the Gui itself must remember between frames (which control is
// being dragged, which text field has the keyboard, how far a panel is scrolled) are
// keyed by an id computed from the panel's title and the control's label.
//
// The engine's editor is built with this, and a game can use it for menus and debug
// panels. It only needs a Canvas and an Input, so it is tested without a GPU.

import Foundation
import simd

public final class Gui {
    public struct Style {
        public var fontSize: Float = 13
        public var rowHeight: Float = 22
        public var spacing: Float = 3               // between rows
        public var padding: Float = 8               // inside a panel
        public var labelWidth: Float = 0.38         // share of a row taken by the label of a field
        public var panel = rgb(0x14181f, alpha: 0.94)
        public var title = rgb(0x0d1015, alpha: 0.98)
        public var field = rgb(0x262c36)
        public var fieldHot = rgb(0x323a47)
        public var accent = rgb(0xfe8b3c)           // the LearnMetal orange
        public var text = rgb(0xe6e9ee)
        public var textDim = rgb(0x8d96a3)
        public var outline = rgb(0x000000, alpha: 0.5)
    }
    public var style = Style()

    private struct Rect {
        var position = Vec2(0, 0)
        var size = Vec2(0, 0)
        func contains(_ p: Vec2) -> Bool {
            p.x >= position.x && p.y >= position.y && p.x < position.x + size.x && p.y < position.y + size.y
        }
    }
    private struct Popup {
        var id: UInt64 = 0                          // the combo that opened it; 0 when closed
        var anchor = Rect()
        var items: [String] = []
        var current = -1
        var scroll: Float = 0
    }

    private static let popupRows: Float = 10

    private var canvas = Canvas()
    private var input = Input()
    private var mouse = Vec2(0, 0)
    private var mouseOverGui = false
    private var mouseFree = true                    // false while a pop-up is open: controls under it must not react

    private var active: UInt64 = 0                  // the control the mouse button went down on
    private var dragDistance: Float = 0             // how far the pointer moved since then
    private var focus: UInt64 = 0                   // the field being typed into
    private var editBuffer = ""
    private var selectAll = false                   // a fresh edit: the first key replaces the whole text
    private var commitFocus = false                 // the edit ended: its field picks the buffer up on its next call
    private var committed: UInt64 = 0

    // The panel being filled.
    private var panelId: UInt64 = 0
    private var content = Rect()                    // where rows may appear
    private var cursorY: Float = 0
    private var contentTop: Float = 0
    private var counter = 0
    private var scroll: [UInt64: Float] = [:]
    private var panels: [Rect] = []
    private var previousPanels: [Rect] = []

    private var popup = Popup()
    private var popupResultId: UInt64 = 0           // set by end(), read by the combo on the next frame
    private var popupResult = -1

    public init() {}

    /// True if the pointer is over a panel or a control is in use: the program should then
    /// leave the mouse alone (not select or move things in the 3D view).
    public var wantsMouse: Bool { mouseOverGui || active != 0 || popup.id != 0 }
    /// True while a text field has the keyboard: the program should ignore its shortcuts.
    public var wantsKeyboard: Bool { focus != 0 }
    /// True if any control changed a value during this frame.
    public private(set) var changed = false
    /// True while a control is being dragged or edited: an edit that is not finished yet.
    public var isBusy: Bool { active != 0 || focus != 0 }

    // MARK: - The frame

    /// Call once per frame before any control, and end() after the last one.
    public func begin(_ canvas: Canvas, _ input: Input) {
        self.canvas = canvas
        self.input = input
        mouse = input.mousePosition
        changed = false

        // Whether the pointer is over the interface is known from where the panels were in
        // the previous frame: this frame's panels have not been declared yet.
        previousPanels = panels
        panels.removeAll(keepingCapacity: true)
        mouseOverGui = previousPanels.contains { $0.contains(mouse) }
        mouseFree = popup.id == 0

        if active != 0 { dragDistance += abs(input.mouseDelta.x) + abs(input.mouseDelta.y) }

        // Typing goes to the focused field.
        if focus != 0 {
            if selectAll && (!input.textInput.isEmpty || input.wasPressed(Key.backspace)) {
                editBuffer = ""
                selectAll = false
            } else if input.wasPressed(Key.backspace) && !editBuffer.isEmpty {
                editBuffer.removeLast()
            }
            editBuffer += input.textInput
            if input.wasPressed(Key.enter) || input.wasPressed(Key.tab) { commitFocus = true }
            if input.wasPressed(Key.escape) { focus = 0 }                       // gives up the edit
            if input.wasPressed(MouseButton.left) { commitFocus = true }        // a click anywhere ends it
        }
    }

    public func end() {
        // A control that was pressed stays active until the button comes up, wherever the pointer went.
        if !input.isDown(MouseButton.left) {
            active = 0
            dragDistance = 0
        }
        // An edit whose field did not come by to collect it (the field is gone) is dropped.
        if commitFocus && committed == 0 { focus = 0 }
        commitFocus = false
        committed = 0

        // The pop-up is drawn last, so that it is on top of every panel.
        if popup.id != 0 {
            let rowHeight = style.rowHeight
            let visible = min(Float(popup.items.count), Gui.popupRows)
            var box = Rect(position: Vec2(popup.anchor.position.x, popup.anchor.position.y + popup.anchor.size.y),
                           size: Vec2(popup.anchor.size.x, visible * rowHeight))
            // Open upward if there is no room below.
            if box.position.y + box.size.y > canvas.size.y { box.position.y = popup.anchor.position.y - box.size.y }
            panels.append(box)

            let maxScroll = max(0, Float(popup.items.count) - Gui.popupRows)
            if box.contains(mouse) { popup.scroll = min(max(popup.scroll - input.scrollDelta, 0), maxScroll) }
            let first = Int(popup.scroll)

            canvas.rect(box.position, box.size, style.title)
            canvas.rectOutline(box.position, box.size, thickness: 1, style.accent)
            let clicked = input.wasPressed(MouseButton.left)
            for row in 0..<Int(visible) {
                let item = first + row
                let rect = Rect(position: Vec2(box.position.x, box.position.y + Float(row) * rowHeight), size: Vec2(box.size.x, rowHeight))
                let hot = rect.contains(mouse)
                if hot || item == popup.current { canvas.rect(rect.position, rect.size, hot ? style.fieldHot : style.field) }
                drawText(popup.items[item], Rect(position: rect.position + Vec2(6, 0), size: rect.size - Vec2(12, 0)),
                         item == popup.current ? style.accent : style.text)
                if hot && clicked {
                    popupResultId = popup.id
                    popupResult = item
                }
            }
            // Any click closes it: on an item (chosen above) or outside (nothing chosen).
            if clicked && !popup.anchor.contains(mouse) { popup = Popup() }
        }
    }

    // MARK: - Panels

    /// Controls go between beginPanel and endPanel, one per row, top to bottom. A panel
    /// scrolls with the mouse wheel when its content is taller than it is.
    public func beginPanel(_ title: String, position: Vec2, size: Vec2) {
        panelId = Gui.hash(title)
        counter = 0
        let whole = Rect(position: position, size: size)
        panels.append(whole)

        let titleHeight = style.rowHeight + 4
        canvas.rect(position, size, style.panel)
        canvas.rect(position, Vec2(size.x, titleHeight), style.title)
        canvas.rectOutline(position, size, thickness: 1, style.outline)
        canvas.text(title, position + Vec2(style.padding, (titleHeight - style.fontSize) * 0.5 - 1), size: style.fontSize, style.textDim)

        content = Rect(position: position + Vec2(style.padding, titleHeight + style.padding),
                       size: size - Vec2(style.padding * 2, titleHeight + style.padding * 2))
        var offset = scroll[panelId] ?? 0
        if whole.contains(mouse) && mouseFree { offset -= input.scrollDelta * (style.rowHeight + style.spacing) * 2 }   // two rows per notch
        offset = max(offset, 0)
        scroll[panelId] = offset
        contentTop = content.position.y - offset
        cursorY = contentTop
    }

    public func endPanel() {
        // Now the height of the content is known: do not let the panel scroll past its end.
        let contentHeight = cursorY - contentTop
        let maxScroll = max(0, contentHeight - content.size.y)
        let offset = min(scroll[panelId] ?? 0, maxScroll)
        scroll[panelId] = offset
        if maxScroll > 0 {
            // A thin bar on the right edge shows where we are.
            let track = content.size.y
            let bar = max(16, track * content.size.y / contentHeight)
            let barOffset = (track - bar) * (offset / maxScroll)
            canvas.rect(Vec2(content.position.x + content.size.x + 2, content.position.y + barOffset), Vec2(3, bar), style.fieldHot)
        }
        panelId = 0
    }

    /// A stable number for a string (FNV-1a). Swift's own hashValue changes from run to run.
    private static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 14695981039346656037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return value
    }

    private func makeId(_ label: String) -> UInt64 {
        // The label alone is not enough: an inspector may show two fields called "Radius".
        // The position of the control in its panel tells them apart.
        counter += 1
        var id = panelId &* 1099511628211 &+ Gui.hash(label)
        id = id &* 1099511628211 &+ UInt64(counter)
        return id == 0 ? 1 : id
    }

    /// Reserves the next row. Returns nil if it falls outside the panel (scrolled away):
    /// the control then draws nothing and does not react.
    private func nextRow() -> Rect? {
        let row = Rect(position: Vec2(content.position.x, cursorY), size: Vec2(content.size.x, style.rowHeight))
        cursorY += style.rowHeight + style.spacing
        let isVisible = row.position.y >= content.position.y - 0.5
            && row.position.y + row.size.y <= content.position.y + content.size.y + 0.5
        return isVisible ? row : nil
    }

    /// Draws the label on the left of a row and returns the rectangle left for the field.
    private func splitRow(_ row: Rect, _ label: String) -> Rect {
        let labelWidth = (row.size.x * style.labelWidth).rounded(.down)
        drawText(label, Rect(position: row.position, size: Vec2(labelWidth - 4, row.size.y)), style.textDim)
        return Rect(position: row.position + Vec2(labelWidth, 0), size: Vec2(row.size.x - labelWidth, row.size.y))
    }

    /// The mouse button went down on this rectangle in this frame.
    private func pressed(_ id: UInt64, _ rect: Rect) -> Bool {
        if !mouseFree || active != 0 || !rect.contains(mouse) || !input.wasPressed(MouseButton.left) { return false }
        active = id
        dragDistance = 0
        return true
    }

    private func fitted(_ text: String, _ width: Float) -> String {
        if canvas.measureText(text, size: style.fontSize).x <= width { return text }
        var shorter = text
        while !shorter.isEmpty && canvas.measureText(shorter + "..", size: style.fontSize).x > width { shorter.removeLast() }
        return shorter + ".."
    }

    private func drawText(_ text: String, _ rect: Rect, _ color: Vec4, align: TextAlign = .left) {
        let y = rect.position.y + (rect.size.y - style.fontSize) * 0.5 - 1
        let x = align == .left ? rect.position.x : align == .center ? rect.position.x + rect.size.x * 0.5 : rect.position.x + rect.size.x
        canvas.text(fitted(text, rect.size.x), Vec2(x, y), size: style.fontSize, color, align: align)
    }

    // MARK: - Simple controls

    public func heading(_ text: String) {
        guard let row = nextRow() else { return }
        drawText(text, row, style.accent)
        canvas.rect(Vec2(row.position.x, row.position.y + row.size.y - 1), Vec2(row.size.x, 1), style.field)
    }

    public func label(_ text: String) {
        if let row = nextRow() { drawText(text, row, style.textDim) }
    }

    public func separator() {
        cursorY += style.spacing * 2
    }

    public func button(_ text: String) -> Bool {
        buttonRow([text]) == 0
    }

    /// Several buttons on one row. Returns the position of the one clicked, or -1.
    public func buttonRow(_ labels: [String]) -> Int {
        let row = nextRow()
        var clicked = -1
        let gap: Float = 4
        for (i, label) in labels.enumerated() {
            let id = makeId(label)
            guard let row = row else { continue }
            let width = (row.size.x - gap * Float(labels.count - 1)) / Float(labels.count)
            let rect = Rect(position: Vec2(row.position.x + Float(i) * (width + gap), row.position.y), size: Vec2(width, row.size.y))
            let hot = mouseFree && rect.contains(mouse)
            if pressed(id, rect) { clicked = i }
            canvas.rect(rect.position, rect.size, active == id ? style.accent : hot ? style.fieldHot : style.field)
            drawText(label, rect, active == id ? style.title : style.text, align: .center)
        }
        return clicked
    }

    /// Like buttonRow, but one stays selected. Returns true when another one was chosen.
    @discardableResult
    public func tabs(_ labels: [String], _ current: inout Int) -> Bool {
        let row = nextRow()
        var switched = false
        for (i, label) in labels.enumerated() {
            let id = makeId(label)
            guard let row = row else { continue }
            let width = row.size.x / Float(labels.count)
            let rect = Rect(position: Vec2(row.position.x + Float(i) * width, row.position.y), size: Vec2(width, row.size.y))
            if pressed(id, rect) && current != i {
                current = i
                switched = true
            }
            let selected = current == i
            drawText(label, rect, selected ? style.accent : style.textDim, align: .center)
            canvas.rect(Vec2(rect.position.x, rect.position.y + rect.size.y - 2), Vec2(rect.size.x, 2), selected ? style.accent : style.field)
        }
        return switched
    }

    /// A row of a list: highlighted when `selected`, returns true when clicked.
    public func selectable(_ text: String, selected: Bool, indent: Float = 0) -> Bool {
        let id = makeId(text)
        guard let row = nextRow() else { return false }
        let hot = mouseFree && row.contains(mouse)
        let clicked = pressed(id, row)
        if selected {
            canvas.rect(row.position, row.size, Vec4(style.accent.x, style.accent.y, style.accent.z, 0.28))
        } else if hot {
            canvas.rect(row.position, row.size, style.field)
        }
        drawText(text, Rect(position: row.position + Vec2(6 + indent, 0), size: row.size - Vec2(12 + indent, 0)),
                 selected ? style.text : style.textDim)
        return clicked
    }

    @discardableResult
    public func checkbox(_ label: String, _ value: inout Bool) -> Bool {
        let id = makeId(label)
        guard let row = nextRow() else { return false }
        let field = splitRow(row, label)
        let side = row.size.y - 6
        let box = Rect(position: field.position + Vec2(0, 3), size: Vec2(side, side))
        let clicked = pressed(id, box)
        if clicked {
            value.toggle()
            changed = true
        }
        canvas.rect(box.position, box.size, mouseFree && box.contains(mouse) ? style.fieldHot : style.field)
        if value { canvas.rect(box.position + Vec2(4, 4), box.size - Vec2(8, 8), style.accent) }
        return clicked
    }

    // MARK: - Numbers and text

    private static func formatNumber(_ value: Float) -> String {
        var text = String(format: "%.3f", Double(value))
        // 1.500 reads better as 1.5, and 2.000 as 2.
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// The text being typed into the focused field. Returns true when the edit was confirmed
    /// in this frame, with `value` replaced by what was typed.
    private func editText(_ id: UInt64, _ rect: Rect, _ value: inout String) -> Bool {
        if focus != id { return false }
        if commitFocus && !(rect.contains(mouse) && input.wasPressed(MouseButton.left)) {
            // Confirmed by Enter or Tab, or by a click somewhere else.
            let differs = editBuffer != value
            value = editBuffer
            focus = 0
            committed = id
            return differs
        }
        committed = id                      // still editing: tells end() the field is alive
        canvas.rect(rect.position, rect.size, style.fieldHot)
        canvas.rectOutline(rect.position, rect.size, thickness: 1, style.accent)
        let inner = Rect(position: rect.position + Vec2(6, 0), size: rect.size - Vec2(12, 0))
        let textWidth = min(canvas.measureText(editBuffer, size: style.fontSize).x, inner.size.x)
        if selectAll {
            canvas.rect(Vec2(inner.position.x - 2, rect.position.y + 3), Vec2(textWidth + 4, rect.size.y - 6),
                        Vec4(style.accent.x, style.accent.y, style.accent.z, 0.35))
        }
        drawText(editBuffer, inner, style.text)
        // The insertion mark, after the last character.
        canvas.rect(Vec2(inner.position.x + textWidth + 1, rect.position.y + 4), Vec2(1, rect.size.y - 8), style.accent)
        return false
    }

    private func numberField(_ id: UInt64, _ rect: Rect, _ value: inout Float, speed: Float, range: ClosedRange<Float>, mark: Vec4) -> Bool {
        // Being typed into?
        if focus == id {
            var text = Gui.formatNumber(value)
            if editText(id, rect, &text), let parsed = Float(text.trimmingCharacters(in: .whitespaces)) {
                // (Text that is not a number leaves the old value.)
                value = min(max(parsed, range.lowerBound), range.upperBound)
                changed = true
                return true
            }
            return false
        }

        var changedNow = false
        _ = pressed(id, rect)
        if active == id {
            if input.isDown(MouseButton.left) {
                // Dragging: so many units per point of pointer travel.
                let delta = input.mouseDelta.x * speed
                if delta != 0 && dragDistance > 3 {
                    value = min(max(value + delta, range.lowerBound), range.upperBound)
                    changedNow = true
                }
            } else if dragDistance <= 3 {
                // Pressed and released without moving: a click. Switch to typing.
                focus = id
                editBuffer = Gui.formatNumber(value)
                selectAll = true
            }
        }
        let hot = mouseFree && rect.contains(mouse)
        canvas.rect(rect.position, rect.size, active == id || hot ? style.fieldHot : style.field)
        canvas.rect(rect.position, Vec2(2, rect.size.y), mark)
        drawText(Gui.formatNumber(value), Rect(position: rect.position + Vec2(6, 0), size: rect.size - Vec2(10, 0)), style.text)
        if changedNow { changed = true }
        return changedNow
    }

    /// A number changed by dragging sideways; a click without dragging lets you type it.
    @discardableResult
    public func dragFloat(_ label: String, _ value: inout Float, speed: Float = 0.01,
                          range: ClosedRange<Float> = -Float.infinity...Float.infinity) -> Bool {
        let id = makeId(label)
        guard let row = nextRow() else { return false }
        return numberField(id, splitRow(row, label), &value, speed: speed, range: range, mark: style.field)
    }

    @discardableResult
    public func dragVec3(_ label: String, _ value: inout Vec3, speed: Float = 0.01) -> Bool {
        let marks = [rgb(0xe5484d), rgb(0x46a758), rgb(0x3e7bfa)]       // x red, y green, z blue, as on the gizmo
        let ids = [makeId(label), makeId(label), makeId(label)]
        guard let row = nextRow() else { return false }
        let field = splitRow(row, label)
        let gap: Float = 3, width = (field.size.x - gap * 2) / 3
        var any = false
        for i in 0..<3 {
            var component = value[i]
            let rect = Rect(position: Vec2(field.position.x + Float(i) * (width + gap), field.position.y), size: Vec2(width, field.size.y))
            if numberField(ids[i], rect, &component, speed: speed, range: -Float.infinity...Float.infinity, mark: marks[i]) {
                value[i] = component
                any = true
            }
        }
        return any
    }

    /// Three numbers and a swatch. Colors are linear; values above 1 are allowed (they bloom).
    @discardableResult
    public func color(_ label: String, _ value: inout Vec3) -> Bool {
        let ids = [makeId(label), makeId(label), makeId(label)]
        guard let row = nextRow() else { return false }
        let field = splitRow(row, label)
        // The swatch shows the color as the screen will: linear values encoded to sRGB, and
        // clipped at 1 (the canvas takes sRGB colors).
        let side = field.size.y
        let shown = Vec4(pow(saturate(value.x), 1 / 2.2), pow(saturate(value.y), 1 / 2.2), pow(saturate(value.z), 1 / 2.2), 1)
        canvas.rect(field.position, Vec2(side, side), shown)
        canvas.rectOutline(field.position, Vec2(side, side), thickness: 1, style.outline)

        let gap: Float = 3, left = field.position.x + side + gap, width = (field.size.x - side - gap * 3) / 3
        var any = false
        for i in 0..<3 {
            var component = value[i]
            let rect = Rect(position: Vec2(left + Float(i) * (width + gap), field.position.y), size: Vec2(width, field.size.y))
            if numberField(ids[i], rect, &component, speed: 0.005, range: 0...100, mark: style.field) {
                value[i] = component
                any = true
            }
        }
        return any
    }

    /// Returns true when the text was changed and confirmed (Enter, or a click elsewhere).
    @discardableResult
    public func textField(_ label: String, _ value: inout String) -> Bool {
        let id = makeId(label)
        guard let row = nextRow() else { return false }
        let field = splitRow(row, label)
        if focus == id {
            if editText(id, field, &value) {
                changed = true
                return true
            }
            return false
        }
        if pressed(id, field) {
            focus = id
            editBuffer = value
            selectAll = true
            commitFocus = false             // this very click must not end the edit it starts
        }
        canvas.rect(field.position, field.size, mouseFree && field.contains(mouse) ? style.fieldHot : style.field)
        drawText(value, Rect(position: field.position + Vec2(6, 0), size: field.size - Vec2(12, 0)), style.text)
        return false
    }

    /// A pop-up list. `index` may be -1 for "nothing chosen".
    @discardableResult
    public func combo(_ label: String, _ index: inout Int, _ items: [String]) -> Bool {
        let id = makeId(label)
        // A choice made in the pop-up during the previous frame arrives here.
        var chosen = false
        if popupResultId == id {
            if popupResult != index && popupResult < items.count {
                index = popupResult
                chosen = true
                changed = true
            }
            popupResultId = 0
            popup = Popup()
        }

        guard let row = nextRow() else { return chosen }
        let field = splitRow(row, label)
        let isOpen = popup.id == id
        // The combo itself must react while its own pop-up is open (to close it), so it
        // looks at the mouse directly instead of going through pressed().
        if field.contains(mouse) && input.wasPressed(MouseButton.left) && active == 0 && (mouseFree || isOpen) {
            active = id
            if isOpen {
                popup = Popup()
            } else if !items.isEmpty {
                popup = Popup()
                popup.id = id
                popup.items = items
                popup.current = index
                popup.scroll = max(0, min(Float(index) - 2, Float(items.count) - Gui.popupRows))
            }
        }
        if popup.id == id { popup.anchor = field }          // follows the panel if it scrolls

        canvas.rect(field.position, field.size, isOpen || (mouseFree && field.contains(mouse)) ? style.fieldHot : style.field)
        let shown = index >= 0 && index < items.count ? items[index] : "none"
        drawText(shown, Rect(position: field.position + Vec2(6, 0), size: field.size - Vec2(24, 0)), index >= 0 ? style.text : style.textDim)
        // A small "v" on the right says that this opens a list.
        let tip = field.position + Vec2(field.size.x - 11, field.size.y * 0.5 + 3)
        canvas.line(from: tip + Vec2(-4, -5), to: tip, thickness: 1.5, style.textDim)
        canvas.line(from: tip + Vec2(4, -5), to: tip, thickness: 1.5, style.textDim)
        return chosen
    }
}
