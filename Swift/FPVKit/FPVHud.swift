// FPVHud.swift
// What is drawn over the picture: the menu, the on-screen display while flying, the results.

import Foundation
import LMEngine
import simd

private let orange = rgb(0xfe8b3c)
private let green = rgb(0x7dff9a)
private let red = rgb(0xff5a4d)
private let white = Vec4(1, 1, 1, 0.96)

/// Text that stays readable over sky and over grass: white on its own dark shadow.
private func osd(_ canvas: Canvas, _ text: String, _ position: Vec2, size: Float, align: TextAlign = .left, _ color: Vec4 = white) {
    canvas.text(text, position + Vec2(1, 1.5), size: size, Vec4(0, 0, 0, 0.65 * color.w), align: align)
    canvas.text(text, position, size: size, color, align: align)
}

/// Where a point of the undistorted picture ends up on screen, after the lens has bent
/// it. `point` runs from -1 to 1 in both directions. The shader knows the other way
/// round (from the screen to the picture), so this looks for the answer in a few steps.
private func throughLens(_ point: Vec2, aspect: Float, distortion: Float) -> Vec2 {
    var guess = point
    let weight = Vec2(aspect, 1) / (aspect * aspect + 1).squareRoot()
    for _ in 0..<6 {
        let q = guess * weight
        let bend = (1 + distortion * simd_dot(q, q)) / (1 + distortion)
        guess = point / bend
    }
    return guess
}

extension FPVGame {
    /// A button for fingers and for the mouse. Returns true in the frame it is pressed.
    func button(_ engine: Engine, _ canvas: Canvas, _ label: String, _ position: Vec2, _ size: Vec2, primary: Bool = false) -> Bool {
        func isInside(_ p: Vec2) -> Bool {
            p.x >= position.x && p.y >= position.y && p.x < position.x + size.x && p.y < position.y + size.y
        }
        let input = engine.input
        // Any finger counts, not only the first: one thumb may already be holding a stick.
        let touched = input.touches.contains { $0.phase == .began && isInside($0.position) }
        let hovered = input.touches.isEmpty && isInside(input.mousePosition)
        let clicked = hovered && input.wasPressed(MouseButton.left)
        let radius = min(size.y * 0.28, 10)
        canvas.roundedRect(position, size, radius: radius, primary ? Vec4(orange.x, orange.y, orange.z, 0.95) : Vec4(0.05, 0.07, 0.1, hovered ? 0.8 : 0.62))
        if !primary { canvas.roundedRectOutline(position, size, radius: radius, thickness: 1, Vec4(1, 1, 1, 0.22)) }
        let textSize = min(size.y * 0.4, 18)
        canvas.text(label, position + Vec2(size.x * 0.5, (size.y - textSize) * 0.5 - 1), size: textSize, primary ? rgb(0x1b1d22) : white, align: .center)
        return touched || clicked
    }

    public func draw(_ engine: Engine, canvas: Canvas) {
        switch screen {
        case .menu: drawMenu(engine, canvas)
        case .flying: drawOSD(engine, canvas)
        case .finished: drawFinished(engine, canvas)
        }
    }

    // MARK: - The menu

    private func drawMenu(_ engine: Engine, _ canvas: Canvas) {
        let size = canvas.size, safe = engine.safeArea
        canvas.rect(Vec2(0, 0), size, Vec4(0.02, 0.03, 0.06, 0.5))

        // Two columns: what to fly on the left, how on the right.
        let gap: Float = 10
        let rowHeight = min(max((size.y - safe.y - safe.w - 150) / 5 - gap, 34), 46)
        let columnWidth = min(320, (size.x - safe.x - safe.z - 72) * 0.5)
        let middle = safe.x + (size.x - safe.x - safe.z) * 0.5
        let left = middle - columnWidth - 12, right = middle + 12
        let top = max(size.y * 0.5 - (rowHeight + gap) * 2.5 + 26, safe.y + 96)

        canvas.text("FPV", Vec2(left, top - 82), size: 46, orange)
        canvas.text(bestTime > 0 ? "Best race  " + formatTime(bestTime) : "No race time yet", Vec2(left + 2, top - 30), size: 14, Vec4(1, 1, 1, 0.75))

        let wide = Vec2(columnWidth, rowHeight * 2 + gap)
        if button(engine, canvas, "Race, \(FPVGame.laps) laps", Vec2(left, top), wide, primary: true) { begin(.race) }
        if button(engine, canvas, "Free flight", Vec2(left, top + wide.y + gap), Vec2(columnWidth, rowHeight)) { begin(.free) }
        var hint = "Left thumb: throttle and yaw. Right thumb: pitch and roll.\nA controller or an RC radio works too."
        if engine.input.isGamepadConnected {
            hint = "Controller connected.\nLeft stick: throttle and yaw. Right stick: pitch and roll."
        } else if !controls.hasSeenTouch {
            hint = "W S throttle, A D yaw, arrows pitch and roll.\nA controller or an RC radio works too."
        }
        canvas.text(hint, Vec2(left + 2, top + wide.y + rowHeight + gap * 2 + 2), size: 12.5, Vec4(1, 1, 1, 0.7))

        let row = Vec2(columnWidth, rowHeight)
        var y = top
        if button(engine, canvas, "Drone: " + drone.airframe.name, Vec2(right, y), row) { chooseAirframe(engine, 1 - airframeIndex) }
        y += rowHeight + gap
        if button(engine, canvas, flightMode == .angle ? "Mode: Angle (levels itself)" : "Mode: Acro (rates)", Vec2(right, y), row) {
            toggleFlightMode()
        }
        y += rowHeight + gap
        let winds = ["Wind: calm", "Wind: a breeze", "Wind: gusty"]
        if button(engine, canvas, winds[min(max(windSetting, 0), 2)], Vec2(right, y), row) {
            windSetting = (windSetting + 1) % 3
            UserDefaults.standard.set(windSetting, forKey: "fpv.wind")
        }
        y += rowHeight + gap
        if button(engine, canvas, "Camera tilt: \(Int(cameraTilt)) degrees", Vec2(right, y), row) {
            cameraTilt = cameraTilt >= 45 ? 10 : cameraTilt + 5
        }
        y += rowHeight + gap
        if button(engine, canvas, controls.throttleUsesFullStick ? "Controller throttle: whole stick" : "Controller throttle: upper half",
                  Vec2(right, y), row) {
            controls.throttleUsesFullStick.toggle()
            UserDefaults.standard.set(controls.throttleUsesFullStick, forKey: "fpv.fullStick")
        }
    }

    // MARK: - While flying

    /// The on-screen display: what a flight controller writes over the video for the pilot.
    private func drawOSD(_ engine: Engine, _ canvas: Canvas) {
        let size = canvas.size, safe = engine.safeArea
        let center = Vec2(safe.x + (size.x - safe.x - safe.z) * 0.5, size.y * 0.5)
        let top = safe.y + 10
        let left = safe.x + 14, right = size.x - safe.z - 14
        let blink = engine.time.elapsed.truncatingRemainder(dividingBy: 0.6) < 0.36

        // The strip of buttons at the top.
        if button(engine, canvas, "Menu", Vec2(left, top), Vec2(70, 34)) { screen = .menu }
        if button(engine, canvas, "Reset", Vec2(left + 78, top), Vec2(70, 34)) { begin(mode) }
        if button(engine, canvas, view == .onboard ? "Onboard" : "Chase", Vec2(right - 164, top), Vec2(82, 34)) {
            view = view == .onboard ? .chase : .onboard
        }
        if button(engine, canvas, flightMode == .angle ? "Angle" : "Acro", Vec2(right - 74, top), Vec2(74, 34)) { toggleFlightMode() }

        // ---- battery, top left: volts per cell (what pilots watch), the pack, and what was used
        let cell = drone.cellVoltage
        let batteryColor = cell < 3.3 ? red : cell < 3.5 ? orange : white
        let at = Vec2(left + 2, top + 46)
        canvas.roundedRectOutline(at + Vec2(0, 2), Vec2(26, 13), radius: 2.5, thickness: 1.5, batteryColor)
        canvas.rect(at + Vec2(26, 6), Vec2(2.5, 5), batteryColor)
        canvas.rect(at + Vec2(3, 5), Vec2(20 * drone.charge, 7), batteryColor)
        osd(canvas, String(format: "%.2f V", Double(cell)), at + Vec2(36, 0), size: 15, batteryColor)
        osd(canvas, String(format: "%.1f V   %.0f MAH", Double(drone.battery.voltage), Double(drone.battery.used * 1000)), at + Vec2(0, 21), size: 12)
        osd(canvas, String(format: "%.1f A", Double(drone.battery.current)), at + Vec2(0, 38), size: 12)

        // ---- radio link, top right
        let linkColor = link < 0.25 ? red : link < 0.5 ? orange : white
        for bar in 0..<4 {
            let barHeight = 4 + Float(bar) * 3
            canvas.rect(Vec2(right - 86 + Float(bar) * 5, top + 61 - barHeight), Vec2(3.5, barHeight),
                        link * 4 > Float(bar) + 0.2 ? linkColor : Vec4(1, 1, 1, 0.25))
        }
        osd(canvas, String(format: "LQ %.0f", Double(link * 100)), Vec2(right - 2, top + 46), size: 15, align: .right, linkColor)
        let home = world.pilot - drone.position
        osd(canvas, String(format: "HOME %.0f M", Double((home.x * home.x + home.z * home.z).squareRoot())), Vec2(right - 2, top + 67), size: 12,
            align: .right)

        // ---- the clock, top center
        if mode == .race {
            osd(canvas, formatTime(race.time), Vec2(center.x, top + 2), size: 26, align: .center)
            osd(canvas, "LAP \(min(race.lap + 1, race.laps))/\(race.laps)    GATE \(race.nextGate + 1)/\(race.gateCount)",
                Vec2(center.x, top + 34), size: 13, align: .center)
            if race.phase == .countdown {
                osd(canvas, "\(Int(race.countdown.rounded(.up)))", Vec2(center.x, size.y * 0.24), size: 84, align: .center, orange)
            }
            drawGateMarker(engine, canvas, courseGates[race.nextGate])
        } else {
            let seconds = Int(flightTime)
            osd(canvas, String(format: "FLY %02d:%02d", seconds / 60, seconds % 60), Vec2(center.x, top + 6), size: 18, align: .center)
        }

        // ---- the artificial horizon, as the flight controller sees it: level is the middle
        // of the screen, whatever the camera's tilt.
        if view == .onboard {
            let nose = drone.forward, wing = drone.right, up = drone.up
            let pitch = asin(min(max(nose.y, -1), 1))                   // nose up is positive
            let roll = atan2(-wing.y, up.y)                             // right wing down is positive
            let along = Vec2(cos(roll), -sin(roll))
            let middle = center + Vec2(0, min(max(degrees(pitch) * 2.2, -70), 70))
            let faint = Vec4(1, 1, 1, 0.7)
            canvas.line(from: middle - along * 96, to: middle - along * 26, thickness: 1.5, faint)
            canvas.line(from: middle + along * 26, to: middle + along * 96, thickness: 1.5, faint)
            canvas.ring(center: center, radius: 4, thickness: 1.5, faint)
            canvas.line(from: center - Vec2(16, 0), to: center - Vec2(7, 0), thickness: 1.5, faint)
            canvas.line(from: center + Vec2(7, 0), to: center + Vec2(16, 0), thickness: 1.5, faint)
        }

        // ---- throttle, speed, height: bottom center, between the thumbs
        let bottom = size.y - safe.w - 34
        let height = drone.position.y - groundHeight(drone.position.x, drone.position.z)
        osd(canvas, String(format: "THR %.0f", Double(sticks.throttle * 100)), Vec2(center.x - 118, bottom), size: 14, align: .center)
        osd(canvas, String(format: "%.0f KM/H", Double(drone.speed * 3.6)), Vec2(center.x, bottom - 2), size: 17, align: .center)
        osd(canvas, String(format: "ALT %.1f M", Double(max(height, 0))), Vec2(center.x + 118, bottom), size: 14, align: .center)

        // ---- warnings, one at a time, the most urgent first
        var warning = ""
        var warningColor = red
        if isCrashed {
            warning = lostSignal ? "RX LOSS" : "CRASHED"
        } else if isWaitingToArm {
            warning = "LOWER THE THROTTLE TO ARM"
        } else if drone.charge <= 0 {
            warning = "BATTERY EMPTY"
        } else if cell < 3.3 {
            warning = "LAND NOW"
        } else if link < 0.25 {
            warning = "RX LOSS SOON: TURN BACK"
        } else if cell < 3.5 {
            warning = "LOW BATTERY"
            warningColor = orange
        }
        if !warning.isEmpty && (blink || isCrashed || isWaitingToArm) {
            osd(canvas, warning, Vec2(center.x, size.y * 0.3), size: 22, align: .center, warningColor)
        }
        if noticeTimer > 0 { osd(canvas, notice, Vec2(center.x, size.y * 0.3 + 30), size: 15, align: .center) }

        if flashTimer > 0 { canvas.rect(Vec2(0, 0), size, Vec4(0.3, 1, 0.5, 0.22 * flashTimer / 0.25)) }
        controls.draw(engine, canvas)
    }

    /// Shows where the next gate is: a ring on it when it is in view, an arrow at the edge
    /// of the screen when it is not.
    private func drawGateMarker(_ engine: Engine, _ canvas: Canvas, _ gate: Gate) {
        guard let transform = engine.scene[camera, Transform.self], let lens = engine.scene[camera, Camera.self] else { return }
        let size = canvas.size
        let aspect = size.x / size.y
        // The gate as the camera sees it: x right, y up, -z ahead.
        let local = transform.rotation.inverse.act(gate.center - transform.position)
        let tangent = tan(lens.fovY * 0.5)
        if local.z < -0.5 {
            var point = Vec2(local.x / (-local.z * tangent * aspect), local.y / (-local.z * tangent))
            point = throughLens(point, aspect: aspect, distortion: engine.renderer.settings.lensDistortion)
            if abs(point.x) < 0.94 && abs(point.y) < 0.9 {
                let at = Vec2((point.x * 0.5 + 0.5) * size.x, (0.5 - point.y * 0.5) * size.y)
                canvas.ring(center: at, radius: 11, thickness: 2, green)
                osd(canvas, "\(Int(simd_length(local))) M", at + Vec2(0, 14), size: 12, align: .center, green)
                return
            }
        }
        // Out of view: point toward it from the middle of the nearer side.
        let isLeft = local.x < 0
        let tip = Vec2(isLeft ? engine.safeArea.x + 22 : size.x - engine.safeArea.z - 22, size.y * 0.5)
        let back: Float = isLeft ? 16 : -16
        canvas.polyline([tip + Vec2(back, -13), tip, tip + Vec2(back, 13)], thickness: 3.5, green)
    }

    // MARK: - The results

    private func drawFinished(_ engine: Engine, _ canvas: Canvas) {
        let size = canvas.size
        let center = size.x * 0.5
        canvas.rect(Vec2(0, 0), size, Vec4(0.02, 0.03, 0.06, 0.6))
        let panelHeight = 214 + 22 * Float(race.lapTimes.count)
        var y = max((size.y - panelHeight) * 0.5, 8)
        canvas.roundedRect(Vec2(center - 190, y), Vec2(380, panelHeight), radius: 16, Vec4(0.05, 0.07, 0.1, 0.85))
        y += 22
        canvas.text("Finished", Vec2(center, y), size: 20, Vec4(1, 1, 1, 0.8), align: .center)
        y += 32
        canvas.text(formatTime(race.time), Vec2(center, y), size: 44, orange, align: .center)
        y += 58
        canvas.text(isNewBest ? "New best time" : "Best  " + formatTime(bestTime), Vec2(center, y), size: 16,
                    isNewBest ? green : Vec4(1, 1, 1, 0.8), align: .center)
        y += 30
        for (index, lapTime) in race.lapTimes.enumerated() {
            canvas.text("Lap \(index + 1)   " + formatTime(lapTime), Vec2(center, y), size: 15, Vec4(1, 1, 1, 0.8), align: .center)
            y += 22
        }
        y += 12
        if button(engine, canvas, "Race again", Vec2(center - 166, y), Vec2(160, 42), primary: true) { begin(.race) }
        if button(engine, canvas, "Menu", Vec2(center + 6, y), Vec2(160, 42)) { screen = .menu }
    }
}
