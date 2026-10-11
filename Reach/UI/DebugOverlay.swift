import SwiftUI

/// Mirrored-to-laptop judge view: what Reach sees and is tracking.
struct DebugOverlay: View {
    let model: AppModel
    let imageRect: CGRect

    var body: some View {
        // Read here (not inside Canvas) so Observation redraws on change.
        let tip = model.fingertip, box = model.targetBox, zone = model.lockZone, state = model.state
        let label = model.targetLabel
        let scene = model.sceneBoxes, touched = model.touchedLabel, money = model.moneyBoxes
        // Judge view polish: boxes pop in (staggered) when a scan, find or money read comes back.
        let animate = model.tuning.judgePolish
        let boxesShownAt = model.boxesShownAt, targetShownAt = model.targetShownAt
        let animating = animate && Date().timeIntervalSince(max(boxesShownAt, targetShownAt)) < 2
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { timeline in
            Canvas { context, _ in
                /// 0 → 1 over 0.35 s, starting `delay` after `start`; 1 when not animating.
                func appear(_ start: Date, delay: Double = 0) -> CGFloat {
                    guard animate else { return 1 }
                    let t = (timeline.date.timeIntervalSince(start) - delay) / 0.35
                    let p = CGFloat(min(max(t, 0), 1))
                    return 1 - (1 - p) * (1 - p)  // ease out
                }
                /// `rect` scaled up from its center while it appears.
                func popping(_ rect: CGRect, _ p: CGFloat) -> CGRect {
                    let scale = 1.3 - 0.3 * p
                    return rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
                }

                // Bills from the money reader: green with the amount, orange "?" where it couldn't read one.
                for (index, bill) in money.enumerated() {
                    let p = appear(boxesShownAt, delay: Double(index) * 0.08)
                    let rect = popping(imageRect.rect(atNormalized: bill.box), p)
                    let color: Color = (bill.label == "?" ? Color.orange : .green).opacity(p)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(color), lineWidth: 4)
                    context.draw(Text(bill.label).font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(color),
                                 at: CGPoint(x: rect.midX, y: rect.midY))
                }
                // Everything the table scan found; the one under the fingertip is filled.
                for (index, object) in scene.enumerated() {
                    let p = appear(boxesShownAt, delay: Double(index) * 0.08)
                    let rect = popping(imageRect.rect(atNormalized: object.box), p)
                    if object.label == touched { context.fill(Path(rect), with: .color(.cyan.opacity(0.3))) }
                    context.stroke(Path(rect), with: .color(.cyan.opacity(p)), lineWidth: 2)
                    context.draw(Text(object.label).font(.caption.bold()).foregroundStyle(.cyan.opacity(p)),
                                 at: CGPoint(x: rect.midX, y: rect.maxY + 2), anchor: .top)
                }
                if let zone {
                    context.stroke(Path(imageRect.rect(atNormalized: zone)), with: .color(.white.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                }
                if let box {
                    let p = appear(targetShownAt)
                    let rect = popping(imageRect.rect(atNormalized: box), p)
                    let color = Self.color(for: state).opacity(p)
                    context.stroke(Path(rect), with: .color(color), lineWidth: 3)
                    if let label {
                        context.draw(Text(label).font(.headline).foregroundStyle(color),
                                     at: CGPoint(x: rect.midX, y: rect.minY - 4), anchor: .bottom)
                    }
                    if state == .guiding || state == .lost {
                        // From the fingertip, or from the user's body (bottom center) when no hand is in view.
                        var line = Path()
                        line.move(to: imageRect.point(atNormalized: tip ?? CGPoint(x: 0.5, y: 1)))
                        line.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
                        context.stroke(line, with: .color(.yellow.opacity(tip == nil ? 0.4 : 0.9)),
                                       style: StrokeStyle(lineWidth: 2, dash: tip == nil ? [4, 4] : []))
                    }
                }
                if let tip {
                    let p = imageRect.point(atNormalized: tip)
                    let dot = CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)
                    context.fill(Path(ellipseIn: dot), with: .color(.green))
                    context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func color(for state: Guide.State) -> Color {
        switch state {
        case .locked: .green
        case .lost: .orange
        case .idle, .locating, .guiding: .yellow
        }
    }
}

/// "Gemini 1.4 s": how long the last Gemini call took (judge view polish).
struct LatencyChip: View {
    let milliseconds: Double

    var body: some View {
        Label(String(format: "Gemini %.1f s", milliseconds / 1000), systemImage: "sparkles")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.purple.opacity(0.8), in: Capsule())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct StatusHUD: View {
    let model: AppModel

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(model.tuning.judgePolish ? 1 : nil)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private var text: String {
        if let error = model.cameraError { return error }
        let hand = model.fingertip == nil ? "hand –" : "hand ✓"
        let key = AppConfig.geminiAPIKey.isEmpty ? "key ✗" : "key ✓"
        let reaches = model.tuning.reachTimer && !model.reachTimes.isEmpty ? model.reachTimes : nil
        if model.tuning.judgePolish {  // one line; timings live in the chip, captions at the bottom
            var parts = [model.state.rawValue, hand, "\(Int(model.fps.rounded())) fps", "\(Int(model.latencyMs)) ms"]
            if let reaches {
                parts.append(String(format: "%d reaches, avg %.1f s", reaches.count, reaches.reduce(0, +) / Double(reaches.count)))
            }
            if let note = model.trackingNote { parts.append("AR: \(note)") }
            if model.torchOn { parts.append("torch") }
            if AppConfig.geminiAPIKey.isEmpty { parts.append(key) }
            return parts.joined(separator: " · ")
        }
        var lines = ["\(model.state.rawValue)  \(hand)  \(Int(model.fps.rounded())) fps  \(Int(model.latencyMs)) ms  \(key)"]
        if let note = model.trackingNote { lines.append("AR: \(note)") }
        if model.torchOn { lines.append("torch on (dark room)") }
        if !model.lastHeard.isEmpty || model.locateMs != nil || model.readMs != nil {
            let gemini = model.locateMs.map { String(format: "  gemini %.1f s", $0 / 1000) } ?? ""
            let claude = model.readMs.map { String(format: "  read %.1f s", $0 / 1000) } ?? ""
            lines.append("heard “\(model.lastHeard)”\(gemini)\(claude)")
        }
        if let reaches {
            lines.append(String(format: "reaches %d  avg %.1f s  best %.1f s", reaches.count,
                                reaches.reduce(0, +) / Double(reaches.count), reaches.min()!))
        }
        if !model.tuning.deadAirKiller, let caption = model.caption { lines.append("🔊 \(caption)") }  // else: big captions
        return lines.joined(separator: "\n")
    }
}
