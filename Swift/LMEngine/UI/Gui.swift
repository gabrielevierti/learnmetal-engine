// Gui.swift
// A small immediate-mode user interface for tools: panels, buttons, number fields,
// text fields, lists, pop-up menus and icons, drawn with the Canvas.
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
// being dragged, which text field has the keyboard, how far a panel is scrolled, which
// sections are folded) are keyed by an id computed from the panel's title and the
// control's label.
//
// How it looks follows three rules. Things to fill in (fields) are darker than the
// panel they sit on, like wells; things to press (buttons) are lighter, like keys. The
// accent color is spent only on what is selected or being changed. And nothing is an
// image: icons are a few lines and curves drawn by the Canvas, sharp at any size.
//
// The engine's editor is built with this, and a game can use it for menus and debug
// panels. It only needs a Canvas and an Input, so it is tested without a GPU.

import Foundation
import simd

public final class Gui {
    /// The pictures a button or a list row can carry.
    public enum Icon: Int, CaseIterable {
        case none, move, rotate, scale, play, stop, undo, redo, save, add, trash, copy
        case cube, light, camera, empty, file, image, material, check, chevronRight, chevronDown
    }

    public struct Style {
        public var fontSize: Float = 13
        public var rowHeight: Float = 24
        public var spacing: Float = 4               // between rows
        public var padding: Float = 10              // inside a panel
        public var labelWidth: Float = 0.36         // share of a row taken by the label of a field
        public var radius: Float = 4                // of the corners of fields and buttons
        public var chrome = rgb(0x1b1d22)           // bars along the edges of the window
        public var panel = rgb(0x24272d)
        public var well = rgb(0x17191d)             // fields: darker than the panel
        public var raised = rgb(0x343840)           // buttons: lighter than the panel
        public var raisedHot = rgb(0x424752)        // a button under the pointer
        public var line = rgb(0x101216)             // between panels, and around pop-ups
        public var accent = rgb(0xfe8b3c)           // the LearnMetal orange: selection and changes only
        public var text = rgb(0xe4e7ec)
        public var textDim = rgb(0x9aa1ad)
        public var textFaint = rgb(0x6b7280)
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
    private static let headerHeight: Float = 30     // of a panel's title
    private static let tooltipDelay = 24            // frames the pointer must rest before a tooltip shows

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
    private var content = Rect()                    // where rows are laid out
    private var clip = Rect()                       // what is visible of them: the panel below its title
    private var cursorY: Float = 0
    private var contentTop: Float = 0
    private var counter = 0
    private var scroll: [UInt64: Float] = [:]
    private var folded: [UInt64: Bool] = [:]        // sections, by id: true when closed
    private var panels: [Rect] = []
    private var previousPanels: [Rect] = []
    private var popup = Popup()
    private var popupResultId: UInt64 = 0           // set by end(), read by the combo on the next frame
    private var popupResult = -1

    // The tooltip: shown once the pointer has rested on the same control for a moment.
    private var tooltipId: UInt64 = 0
    private var tooltipSeen: UInt64 = 0
    private var tooltipFrames = 0
    private var tooltipAnchor = Rect()
    private var tooltipText = ""

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
        panelId = 0
        tooltipSeen = 0

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
            var box = Rect(position: Vec2(popup.anchor.position.x, popup.anchor.position.y + popup.anchor.size.y + 2),
                           size: Vec2(popup.anchor.size.x, visible * rowHeight + 6))
            // Open upward if there is no room below.
            if box.position.y + box.size.y > canvas.size.y { box.position.y = popup.anchor.position.y - box.size.y - 2 }
            panels.append(box)

            let maxScroll = max(0, Float(popup.items.count) - Gui.popupRows)
            if box.contains(mouse) { popup.scroll = min(max(popup.scroll - input.scrollDelta, 0), maxScroll) }
            let first = Int(popup.scroll)

            drawShadow(box, radius: 6)
            canvas.roundedRect(box.position, box.size, radius: 6, style.chrome)
            canvas.roundedRectOutline(box.position, box.size, radius: 6, thickness: 1, style.raisedHot)
            let clicked = input.wasPressed(MouseButton.left)
            for row in 0..<Int(visible) {
                let item = first + row
                let rect = Rect(position: Vec2(box.position.x + 3, box.position.y + 3 + Float(row) * rowHeight),
                                size: Vec2(box.size.x - 6, rowHeight))
                let hot = rect.contains(mouse)
                if hot { canvas.roundedRect(rect.position, rect.size, radius: style.radius, style.raised) }
                let isCurrent = item == popup.current
                drawText(popup.items[item], Rect(position: rect.position + Vec2(8, 0), size: rect.size - Vec2(30, 0)),
                         isCurrent || hot ? style.text : style.textDim)
                if isCurrent { icon(.check, center: rect.position + Vec2(rect.size.x - 13, rect.size.y * 0.5), size: 12, style.accent) }
                if hot && clicked {
                    popupResultId = popup.id
                    popupResult = item
                }
            }
            // Any click closes it: on an item (chosen above) or outside (nothing chosen).
            if clicked && !popup.anchor.contains(mouse) { popup = Popup() }
        }

        // The tooltip, once the pointer has rested on one control for a while.
        if tooltipSeen == 0 {
            tooltipId = 0
            tooltipFrames = 0
        } else if tooltipSeen == tooltipId {
            tooltipFrames += 1
        } else {
            tooltipId = tooltipSeen
            tooltipFrames = 0
        }
        if tooltipFrames > Gui.tooltipDelay && active == 0 && !tooltipText.isEmpty {
            let size = canvas.measureText(tooltipText, size: style.fontSize - 1) + Vec2(16, 10)
            var position = Vec2(tooltipAnchor.position.x + (tooltipAnchor.size.x - size.x) * 0.5,
                                tooltipAnchor.position.y + tooltipAnchor.size.y + 6)
            position.x = min(max(position.x, 4), max(4, canvas.size.x - size.x - 4))
            if position.y + size.y > canvas.size.y { position.y = tooltipAnchor.position.y - size.y - 6 }
            drawShadow(Rect(position: position, size: size), radius: 4)
            canvas.roundedRect(position, size, radius: 4, style.chrome)
            canvas.roundedRectOutline(position, size, radius: 4, thickness: 1, style.raisedHot)
            canvas.text(tooltipText, position + Vec2(8, 4), size: style.fontSize - 1, style.text)
        }
    }

    // MARK: - Drawing helpers

    private static func withAlpha(_ color: Vec4, _ alpha: Float) -> Vec4 { Vec4(color.x, color.y, color.z, alpha) }

    /// A field: darker than the panel, with a line around it while the pointer is on it.
    private func drawWell(_ rect: Rect, hot: Bool, active isActive: Bool) {
        canvas.roundedRect(rect.position, rect.size, radius: style.radius, style.well)
        if isActive {
            canvas.roundedRectOutline(rect.position, rect.size, radius: style.radius, thickness: 1, style.accent)
        } else if hot {
            canvas.roundedRectOutline(rect.position, rect.size, radius: style.radius, thickness: 1, style.raisedHot)
        }
    }

    /// A button: lighter than the panel; the accent color while it is held down.
    private func drawButton(_ rect: Rect, hot: Bool, down: Bool, selected: Bool) {
        if down {
            canvas.roundedRect(rect.position, rect.size, radius: style.radius, style.accent)
        } else if selected {
            canvas.roundedRect(rect.position, rect.size, radius: style.radius, Gui.withAlpha(style.accent, 0.22))
            canvas.roundedRectOutline(rect.position, rect.size, radius: style.radius, thickness: 1, Gui.withAlpha(style.accent, 0.7))
        } else {
            canvas.roundedRect(rect.position, rect.size, radius: style.radius, hot ? style.raisedHot : style.raised)
        }
    }

    /// A soft shadow below something that floats: a few wider and fainter copies of its shape.
    private func drawShadow(_ rect: Rect, radius: Float) {
        for i in stride(from: 4, through: 1, by: -1) {
            let grow = Float(i) * 2
            canvas.roundedRect(rect.position + Vec2(-grow, -grow + 3), rect.size + Vec2(grow * 2, grow * 2), radius: radius + grow,
                               Vec4(0, 0, 0, 0.07))
        }
    }

    private func showTooltip(_ id: UInt64, _ rect: Rect, _ text: String) {
        tooltipSeen = id
        tooltipAnchor = rect
        tooltipText = text
    }

    /// Draws an icon, centered, `size` points wide.
    public func icon(_ which: Icon, center: Vec2, size: Float, _ color: Vec4) {
        let c = canvas
        let u = size / 16                           // icons are designed on a 16 x 16 grid, origin in the middle
        let w = max(1.5 * u, 1.2)                   // the width of their lines
        func at(_ x: Float, _ y: Float) -> Vec2 { center + Vec2(x, y) * u }
        func path(_ points: [(Float, Float)], closed: Bool = false) {
            c.polyline(points.map { center + Vec2($0.0, $0.1) * u }, thickness: w, color, isClosed: closed)
        }
        switch which {
        case .none:
            break
        case .move:
            c.line(from: at(-6.5, 0), to: at(6.5, 0), thickness: w, color)
            c.line(from: at(0, -6.5), to: at(0, 6.5), thickness: w, color)
            path([(4.5, -2), (6.5, 0), (4.5, 2)])
            path([(-4.5, -2), (-6.5, 0), (-4.5, 2)])
            path([(-2, 4.5), (0, 6.5), (2, 4.5)])
            path([(-2, -4.5), (0, -6.5), (2, -4.5)])
        case .rotate:
            c.arc(center: center, radius: 6 * u + w * 0.5, from: 0.3 * Float.pi, to: 1.85 * Float.pi, thickness: w, color)
            path([(2.2, -4.6), (5.6, -2.7), (6.6, -6.4)])
        case .scale:
            c.roundedRectOutline(at(-6.5, 0.5), Vec2(6, 6) * u, radius: 1 * u, thickness: w, color)
            c.line(from: at(-0.5, 0.5), to: at(6, -6), thickness: w, color)
            path([(2, -6), (6, -6), (6, -2)])
        case .play:
            c.triangle(at(-4, -6), at(6, 0), at(-4, 6), color)
        case .stop:
            c.roundedRect(at(-5, -5), Vec2(10, 10) * u, radius: 2 * u, color)
        case .undo:
            path([(-5.5, -2), (1.5, -2), (4, -1), (5, 1), (4, 3), (1.5, 4), (-3, 4)])
            path([(-2.5, -5), (-5.5, -2), (-2.5, 1)])
        case .redo:
            path([(5.5, -2), (-1.5, -2), (-4, -1), (-5, 1), (-4, 3), (-1.5, 4), (3, 4)])
            path([(2.5, -5), (5.5, -2), (2.5, 1)])
        case .save:
            c.roundedRectOutline(at(-6.5, -6.5), Vec2(13, 13) * u, radius: 2 * u, thickness: w, color)
            path([(-3, -6), (-3, -2.5), (3, -2.5), (3, -6)])
            c.roundedRectOutline(at(-3.5, 1), Vec2(7, 5.5) * u, radius: 1 * u, thickness: w, color)
        case .add:
            c.line(from: at(-5.5, 0), to: at(5.5, 0), thickness: w * 1.2, color)
            c.line(from: at(0, -5.5), to: at(0, 5.5), thickness: w * 1.2, color)
        case .trash:
            c.line(from: at(-6, -4), to: at(6, -4), thickness: w, color)
            path([(-2, -4), (-2, -6.5), (2, -6.5), (2, -4)])
            path([(-4.5, -4), (-3.5, 6.5), (3.5, 6.5), (4.5, -4)])
        case .copy:
            c.roundedRectOutline(at(-6.5, -6.5), Vec2(9, 9) * u, radius: 1.5 * u, thickness: w, color)
            c.roundedRectOutline(at(-2.5, -2.5), Vec2(9, 9) * u, radius: 1.5 * u, thickness: w, color)
        case .cube:
            path([(0, -7), (6, -3.5), (6, 3.5), (0, 7), (-6, 3.5), (-6, -3.5)], closed: true)
            path([(-6, -3.5), (0, 0), (6, -3.5)])
            c.line(from: at(0, 0), to: at(0, 7), thickness: w, color)
        case .light:
            c.ring(center: center, radius: 3.2 * u + w * 0.5, thickness: w, color)
            for i in 0..<8 {
                let angle = Float(i) * Float.pi * 0.25
                let direction = Vec2(cos(angle), sin(angle))
                c.line(from: center + direction * (5.2 * u), to: center + direction * (7.2 * u), thickness: w, color)
            }
        case .camera:
            c.roundedRectOutline(at(-7, -4), Vec2(9.5, 8) * u, radius: 1.5 * u, thickness: w, color)
            path([(2.5, -1), (7, -3.8), (7, 3.8), (2.5, 1)])
        case .empty:
            path([(0, -5.5), (5.5, 0), (0, 5.5), (-5.5, 0)], closed: true)
        case .file:
            path([(-4.5, -7), (1.5, -7), (4.5, -4), (4.5, 7), (-4.5, 7)], closed: true)
            path([(1.5, -7), (1.5, -4), (4.5, -4)])
        case .image:
            c.roundedRectOutline(at(-7, -5.5), Vec2(14, 11) * u, radius: 1.5 * u, thickness: w, color)
            path([(-5.5, 3.5), (-2, -0.5), (0.5, 2), (2.5, 0.2), (5.5, 3.5)])
            c.circle(center: at(3, -2.3), radius: 1.3 * u, color)
        case .material:
            c.ring(center: center, radius: 6.5 * u, thickness: w, color)
            c.arc(center: center, radius: 3.8 * u, from: 1.05 * Float.pi, to: 1.55 * Float.pi, thickness: w, color)
        case .check:
            c.polyline([at(-4.5, 0.3), at(-1.3, 3.6), at(4.8, -3.6)], thickness: w * 1.25, color)
        case .chevronRight:
            path([(-2, -4), (2, 0), (-2, 4)])
        case .chevronDown:
            path([(-4, -2), (0, 2), (4, -2)])
        }
    }

    // MARK: - Panels

    /// Controls go between beginPanel and endPanel, one per row, top to bottom. A panel
    /// scrolls with the mouse wheel when its content is taller than it is. A title that
    /// starts with # is not shown: the panel has no title bar, but keeps its identity.
    public func beginPanel(_ title: String, position: Vec2, size: Vec2) {
        panelId = Gui.hash(title)
        if panelId == 0 { panelId = 1 }
        counter = 0
        let whole = Rect(position: position, size: size)
        panels.append(whole)

        let header: Float = title.isEmpty || title.hasPrefix("#") ? 0 : Gui.headerHeight
        canvas.rect(position, size, style.panel)
        if header > 0 {
            canvas.text(title, position + Vec2(style.padding, (header - style.fontSize) * 0.5 - 1), size: style.fontSize, style.text)
            canvas.rect(Vec2(position.x, position.y + header - 1), Vec2(size.x, 1), style.line)
        }
        canvas.rectOutline(position, size, thickness: 1, style.line)

        content = Rect(position: position + Vec2(style.padding, header + style.padding),
                       size: size - Vec2(style.padding * 2, header + style.padding * 2))
        clip = Rect(position: position + Vec2(1, header), size: size - Vec2(2, header + 1))
        var offset = scroll[panelId] ?? 0
        if whole.contains(mouse) && mouseFree { offset -= input.scrollDelta * (style.rowHeight + style.spacing) * 3 }   // three rows per notch
        offset = max(offset, 0)
        scroll[panelId] = offset
        contentTop = content.position.y - offset
        cursorY = contentTop
        // Rows scroll under the title and the bottom edge: the canvas cuts off what sticks out.
        canvas.pushClip(clip.position, clip.size)
    }

    public func endPanel() {
        canvas.popClip()
        // Now the height of the content is known: do not let the panel scroll past its end.
        let contentHeight = cursorY - contentTop - style.spacing
        let maxScroll = max(0, contentHeight - content.size.y)
        let offset = min(scroll[panelId] ?? 0, maxScroll)
        scroll[panelId] = offset
        if maxScroll > 0 {
            // A thin bar on the right edge shows where we are.
            let track = clip.size.y - 8
            let bar = max(24, track * content.size.y / contentHeight)
            let barOffset = (track - bar) * (offset / maxScroll)
            canvas.roundedRect(Vec2(clip.position.x + clip.size.x - 6, clip.position.y + 4 + barOffset), Vec2(4, bar), radius: 2,
                               Gui.withAlpha(style.textFaint, 0.7))
        }
        panelId = 0
    }

    /// A stable number for a string (FNV-1a). Swift's own hashValue changes from run to run.
    private static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 14695981039346656037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return value
    }

    /// An id for a control that is placed by hand: its text and where it is.
    private static func freeId(_ text: String, _ position: Vec2) -> UInt64 {
        var id = hash(text) &* 1099511628211
        id = id &+ UInt64(truncatingIfNeeded: Int64(position.x * 4)) &* 0x9e3779b97f4a7c15 &+ UInt64(truncatingIfNeeded: Int64(position.y * 4))
        return id == 0 ? 1 : id
    }

    private func makeId(_ label: String) -> UInt64 {
        // The label alone is not enough: an inspector may show two fields called "Radius".
        // The position of the control in its panel tells them apart.
        counter += 1
        var id = panelId &* 1099511628211 &+ Gui.hash(label)
        id = id &* 1099511628211 &+ UInt64(counter)
        return id == 0 ? 1 : id
    }

    /// Reserves the next row. Returns nil if no part of it shows (scrolled away): the
    /// control then draws nothing and does not react.
    private func nextRow() -> Rect? {
        let row = Rect(position: Vec2(content.position.x, cursorY), size: Vec2(content.size.x, style.rowHeight))
        cursorY += style.rowHeight + style.spacing
        let isVisible = row.position.y + row.size.y > clip.position.y && row.position.y < clip.position.y + clip.size.y
        return isVisible ? row : nil
    }

    /// Draws the label on the left of a row and returns the rectangle left for the field.
    private func splitRow(_ row: Rect, _ label: String) -> Rect {
        let labelWidth = (row.size.x * style.labelWidth).rounded(.down)
        drawText(label, Rect(position: row.position, size: Vec2(labelWidth - 6, row.size.y)), style.textDim)
        return Rect(position: row.position + Vec2(labelWidth, 0), size: Vec2(row.size.x - labelWidth, row.size.y))
    }

    /// The pointer is on this rectangle, and on a part of it that shows.
    private func hovers(_ rect: Rect) -> Bool {
        mouseFree && rect.contains(mouse) && (panelId == 0 || clip.contains(mouse))
    }

    /// The mouse button went down on this rectangle in this frame.
    private func pressed(_ id: UInt64, _ rect: Rect) -> Bool {
        if active != 0 || !hovers(rect) || !input.wasPressed(MouseButton.left) { return false }
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

    private static func formatNumber(_ value: Float) -> String {
        var text = String(format: "%.3f", Double(value))
        // 1.500 reads better as 1.5, and 2.000 as 2.
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    // MARK: - Simple controls

    /// A title that folds what follows it. Returns true while open: put the controls of
    /// the section inside `if gui.section("Transform") { ... }`.
    public func section(_ title: String, startsOpen: Bool = true) -> Bool {
        // Not makeId: folding a section changes how many controls come before the next one,
        // and a section must keep its state all the same. Its title is its identity.
        var id = panelId &* 1099511628211 &+ Gui.hash(title) &+ 0x5ec7
        if id == 0 { id = 1 }
        if folded[id] == nil { folded[id] = !startsOpen }

        if cursorY > contentTop { cursorY += style.spacing }           // a little air above
        guard let row = nextRow() else { return !(folded[id] ?? false) }
        // The band runs the whole width of the panel, edge to edge.
        let band = Rect(position: Vec2(clip.position.x, row.position.y), size: Vec2(clip.size.x, row.size.y))
        let hot = hovers(band)
        if pressed(id, band) { folded[id] = !(folded[id] ?? false) }
        let isOpen = !(folded[id] ?? false)
        canvas.rect(band.position, band.size, hot ? style.raised : Gui.withAlpha(style.raised, 0.55))
        icon(isOpen ? .chevronDown : .chevronRight, center: row.position + Vec2(6, row.size.y * 0.5), size: 11, style.textDim)
        drawText(title, Rect(position: row.position + Vec2(18, 0), size: row.size - Vec2(18, 0)), style.text)
        return isOpen
    }

    public func heading(_ text: String) {
        guard let row = nextRow() else { return }
        drawText(text, row, style.text)
        canvas.rect(Vec2(row.position.x, row.position.y + row.size.y - 1), Vec2(row.size.x, 1), style.raised)
    }

    public func label(_ text: String) {
        if let row = nextRow() { drawText(text, row, style.textDim) }
    }

    public func separator() {
        cursorY += style.spacing
        canvas.rect(Vec2(content.position.x, cursorY), Vec2(content.size.x, 1), style.raised)
        cursorY += style.spacing * 2 + 1
    }

    public func button(_ text: String) -> Bool {
        buttonRow([text]) == 0
    }

    /// Several buttons on one row. Returns the position of the one clicked, or -1.
    public func buttonRow(_ labels: [String]) -> Int {
        let row = nextRow()
        var clicked = -1
        let gap: Float = 6
        for (index, text) in labels.enumerated() {
            let id = makeId(text)
            guard let row = row else { continue }
            let width = (row.size.x - gap * Float(labels.count - 1)) / Float(labels.count)
            let rect = Rect(position: Vec2(row.position.x + Float(index) * (width + gap), row.position.y), size: Vec2(width, row.size.y))
            if pressed(id, rect) { clicked = index }
            drawButton(rect, hot: hovers(rect), down: active == id, selected: false)
            drawText(text, Rect(position: rect.position + Vec2(4, 0), size: rect.size - Vec2(8, 0)), active == id ? style.chrome : style.text,
                     align: .center)
        }
        return clicked
    }

    /// Like buttonRow, but one stays selected.
    @discardableResult
    public func tabs(_ labels: [String], _ current: inout Int) -> Bool {
        let row = nextRow()
        var switched = false
        // One sunken track; the chosen tab is a key standing on it.
        if let row = row { canvas.roundedRect(row.position, row.size, radius: style.radius + 2, style.well) }
        for (index, text) in labels.enumerated() {
            let id = makeId(text)
            guard let row = row else { continue }
            let width = row.size.x / Float(labels.count)
            let rect = Rect(position: Vec2(row.position.x + Float(index) * width, row.position.y), size: Vec2(width, row.size.y))
            if pressed(id, rect) && current != index {
                current = index
                switched = true
            }
            let selected = current == index
            if selected { canvas.roundedRect(rect.position + Vec2(2, 2), rect.size - Vec2(4, 4), radius: style.radius, style.raised) }
            drawText(text, rect, selected || hovers(rect) ? style.text : style.textDim, align: .center)
        }
        return switched
    }

    /// A row of a list: highlighted when `selected`, returns true when clicked.
    public func selectable(_ text: String, selected: Bool, indent: Float = 0, icon picture: Icon = .none) -> Bool {
        let id = makeId(text)
        guard let row = nextRow() else { return false }
        let hot = hovers(row)
        let clicked = pressed(id, row)
        if selected {
            canvas.roundedRect(row.position, row.size, radius: style.radius, Gui.withAlpha(style.accent, 0.24))
        } else if hot {
            canvas.roundedRect(row.position, row.size, radius: style.radius, Gui.withAlpha(style.raised, 0.7))
        }
        var left = 8 + indent
        if picture != .none {
            icon(picture, center: row.position + Vec2(left + 7, row.size.y * 0.5), size: 13, selected ? style.accent : style.textFaint)
            left += 21
        }
        drawText(text, Rect(position: row.position + Vec2(left, 0), size: row.size - Vec2(left + 6, 0)), selected || hot ? style.text : style.textDim)
        return clicked
    }

    @discardableResult
    public func checkbox(_ label: String, _ value: inout Bool) -> Bool {
        let id = makeId(label)
        guard let row = nextRow() else { return false }
        let field = splitRow(row, label)
        let side: Float = 16
        let box = Rect(position: field.position + Vec2(0, (row.size.y - side) * 0.5), size: Vec2(side, side))
        let clicked = pressed(id, box)
        if clicked {
            value.toggle()
            changed = true
        }
        if value {
            canvas.roundedRect(box.position, box.size, radius: 4, style.accent)
            icon(.check, center: box.position + box.size * 0.5, size: 12, style.chrome)
        } else {
            canvas.roundedRect(box.position, box.size, radius: 4, style.well)
            canvas.roundedRectOutline(box.position, box.size, radius: 4, thickness: 1, hovers(box) ? style.textDim : style.raisedHot)
        }
        return clicked
    }

    // MARK: - Numbers and text

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
        drawWell(rect, hot: true, active: true)
        let inner = Rect(position: rect.position + Vec2(7, 0), size: rect.size - Vec2(14, 0))
        let textWidth = min(canvas.measureText(editBuffer, size: style.fontSize).x, inner.size.x)
        if selectAll {
            canvas.roundedRect(Vec2(inner.position.x - 2, rect.position.y + 4), Vec2(textWidth + 4, rect.size.y - 8), radius: 2,
                               Gui.withAlpha(style.accent, 0.4))
        }
        drawText(editBuffer, inner, style.text)
        // The insertion mark, after the last character.
        canvas.rect(Vec2(inner.position.x + textWidth + 1, rect.position.y + 5), Vec2(1, rect.size.y - 10), style.accent)
        return false
    }

    private func numberField(_ id: UInt64, _ rect: Rect, _ value: inout Float, speed: Float, range: ClosedRange<Float>, mark: Vec4,
                             letter: String?) -> Bool {
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
        drawWell(rect, hot: hovers(rect), active: active == id)
        // Between two limits, a line along the bottom shows how far along the value is.
        if range.lowerBound.isFinite && range.upperBound.isFinite && range.upperBound > range.lowerBound {
            let share = saturate((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            canvas.rect(rect.position + Vec2(style.radius, rect.size.y - 3), Vec2((rect.size.x - style.radius * 2) * share, 2),
                        Gui.withAlpha(style.accent, active == id ? 1 : 0.75))
        }
        var left: Float = 7
        if let letter = letter {
            canvas.text(letter, rect.position + Vec2(6, (rect.size.y - (style.fontSize - 2)) * 0.5 - 1), size: style.fontSize - 2, mark)
            left = 19
        }
        drawText(Gui.formatNumber(value), Rect(position: rect.position + Vec2(left, 0), size: rect.size - Vec2(left + 4, 0)), style.text)
        if changedNow { changed = true }
        return changedNow
    }

    /// A number changed by dragging sideways; a click without dragging lets you type it.
    /// With a finite range, the field also shows where the value is in it.
    @discardableResult
    public func dragFloat(_ label: String, _ value: inout Float, speed: Float = 0.01,
                          range: ClosedRange<Float> = -Float.infinity...Float.infinity) -> Bool {
        let id = makeId(label)
        guard let row = nextRow() else { return false }
        return numberField(id, splitRow(row, label), &value, speed: speed, range: range, mark: style.text, letter: nil)
    }

    @discardableResult
    public func dragVec3(_ label: String, _ value: inout Vec3, speed: Float = 0.01) -> Bool {
        let marks = [rgb(0xf0666b), rgb(0x5cc470), rgb(0x5b93ff)]       // x red, y green, z blue, as on the gizmo
        let letters = ["X", "Y", "Z"]
        let ids = [makeId(label), makeId(label), makeId(label)]
        guard let row = nextRow() else { return false }
        let field = splitRow(row, label)
        let gap: Float = 4, width = (field.size.x - gap * 2) / 3
        var any = false
        for i in 0..<3 {
            var component = value[i]
            let rect = Rect(position: Vec2(field.position.x + Float(i) * (width + gap), field.position.y), size: Vec2(width, field.size.y))
            if numberField(ids[i], rect, &component, speed: speed, range: -Float.infinity...Float.infinity, mark: marks[i], letter: letters[i]) {
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
        canvas.roundedRect(field.position, Vec2(side, side), radius: style.radius, shown)
        canvas.roundedRectOutline(field.position, Vec2(side, side), radius: style.radius, thickness: 1, Gui.withAlpha(style.text, 0.25))

        let gap: Float = 4, left = field.position.x + side + gap, width = (field.size.x - side - gap * 3) / 3
        var any = false
        for i in 0..<3 {
            var component = value[i]
            let rect = Rect(position: Vec2(left + Float(i) * (width + gap), field.position.y), size: Vec2(width, field.size.y))
            if numberField(ids[i], rect, &component, speed: 0.005, range: 0...100, mark: style.text, letter: nil) {
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
        drawWell(field, hot: hovers(field), active: false)
        drawText(value, Rect(position: field.position + Vec2(7, 0), size: field.size - Vec2(14, 0)), style.text)
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
        let onField = field.contains(mouse) && clip.contains(mouse)
        if onField && input.wasPressed(MouseButton.left) && active == 0 && (mouseFree || isOpen) {
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
        if popup.id == id { popup.anchor = field }              // follows the panel if it scrolls

        drawWell(field, hot: hovers(field), active: isOpen)
        let shown = index >= 0 && index < items.count ? items[index] : "Choose..."
        drawText(shown, Rect(position: field.position + Vec2(7, 0), size: field.size - Vec2(28, 0)), index >= 0 ? style.text : style.textFaint)
        icon(.chevronDown, center: field.position + Vec2(field.size.x - 12, field.size.y * 0.5), size: 10, style.textDim)
        return chosen
    }

    // MARK: - Free controls: placed by the program anywhere on screen, outside any panel.
    // Tool bars and status bars are made of these.

    /// A strip of window chrome. The pointer over it belongs to the interface.
    public func bar(position: Vec2, size: Vec2) {
        panels.append(Rect(position: position, size: size))
        canvas.rect(position, size, style.chrome)
        canvas.rectOutline(position, size, thickness: 1, style.line)
    }

    /// A rounded surface that floats over the 3D view, with a shadow.
    public func card(position: Vec2, size: Vec2) {
        let rect = Rect(position: position, size: size)
        panels.append(rect)
        drawShadow(rect, radius: 8)
        canvas.roundedRect(position, size, radius: 8, Gui.withAlpha(style.panel, 0.96))
        canvas.roundedRectOutline(position, size, radius: 8, thickness: 1, Gui.withAlpha(style.text, 0.08))
    }

    public func button(_ text: String, position: Vec2, size: Vec2, isSelected: Bool = false, icon picture: Icon = .none) -> Bool {
        let id = Gui.freeId(text, position)
        let rect = Rect(position: position, size: size)
        let clicked = pressed(id, rect)
        drawButton(rect, hot: hovers(rect), down: active == id, selected: isSelected)
        let ink = active == id ? style.chrome : style.text
        if picture == .none {
            drawText(text, Rect(position: position + Vec2(6, 0), size: size - Vec2(12, 0)), ink, align: .center)
        } else {
            // The icon and the text are centered together.
            let width = 12 + 7 + canvas.measureText(text, size: style.fontSize).x
            let left = position.x + (size.x - width) * 0.5
            icon(picture, center: Vec2(left + 6, position.y + size.y * 0.5), size: 12, ink)
            drawText(text, Rect(position: Vec2(left + 19, position.y), size: size), ink)
        }
        return clicked
    }

    /// `tooltip` appears when the pointer rests on the button.
    public func iconButton(_ picture: Icon, position: Vec2, size: Vec2, tooltip: String, isSelected: Bool = false) -> Bool {
        let id = Gui.freeId(tooltip, position)
        let rect = Rect(position: position, size: size)
        let hot = hovers(rect)
        let clicked = pressed(id, rect)
        let down = active == id
        // Quiet until touched: no key shape at rest, so a row of icons reads as one strip.
        if down {
            canvas.roundedRect(position, size, radius: style.radius + 1, style.accent)
        } else if isSelected {
            canvas.roundedRect(position, size, radius: style.radius + 1, Gui.withAlpha(style.accent, 0.24))
        } else if hot {
            canvas.roundedRect(position, size, radius: style.radius + 1, style.raised)
        }
        icon(picture, center: position + size * 0.5, size: min(size.x, size.y) * 0.56,
             down ? style.chrome : isSelected ? style.accent : hot ? style.text : style.textDim)
        if hot && !tooltip.isEmpty { showTooltip(id, rect, tooltip) }
        return clicked
    }
}
