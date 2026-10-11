import SwiftUI

/// Mirrored-to-laptop judge view: what Reach found and where the hand is, drawn over the camera.
struct DebugOverlay: View {
    let model: AppModel
    let imageRect: CGRect

    var body: some View {
        // Read here (not inside Canvas) so Observation redraws on change.
        let tip = model.fingertip, box = model.targetBox, zone = model.lockZone, state = model.state
        let label = model.targetLabel
        let scene = model.sceneBoxes, touched = model.touchedLabel, money = model.moneyBoxes
        let showZone = model.tuning.showStats
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
                /// A filled label pill centered at `point` (or with its bottom / top edge there).
                func pill(_ text: String, at point: CGPoint, color: Color, size: CGFloat, anchor: UnitPoint = .center) {
                    let resolved = context.resolve(Text(text).font(Theme.rounded(size, .bold)).foregroundStyle(.black))
                    let textSize = resolved.measure(in: CGSize(width: 400, height: 100))
                    let pillSize = CGSize(width: textSize.width + size, height: textSize.height + size * 0.4)
                    let origin = CGPoint(x: point.x - pillSize.width * anchor.x, y: point.y - pillSize.height * anchor.y)
                    let rect = CGRect(origin: origin, size: pillSize)
                    context.fill(Path(roundedRect: rect, cornerRadius: pillSize.height / 2), with: .color(color))
                    context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY))
                }

                // Bills from the money reader: green with the amount, orange "?" where it couldn't read one.
                for (index, bill) in money.enumerated() {
                    let p = appear(boxesShownAt, delay: Double(index) * 0.08)
                    let rect = popping(imageRect.rect(atNormalized: bill.box), p)
                    let color = (bill.label == "?" ? Theme.warning : Theme.success).opacity(p)
                    context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(color), lineWidth: 3)
                    pill(bill.label, at: CGPoint(x: rect.midX, y: rect.midY), color: color, size: 20)
                }
                // Everything the table scan found; the one under the fingertip is filled.
                for (index, object) in scene.enumerated() {
                    let p = appear(boxesShownAt, delay: Double(index) * 0.08)
                    let rect = popping(imageRect.rect(atNormalized: object.box), p)
                    let path = Path(roundedRect: rect, cornerRadius: 8)
                    if object.label == touched { context.fill(path, with: .color(Theme.scan.opacity(0.25))) }
                    context.stroke(path, with: .color(Theme.scan.opacity(0.8 * p)), lineWidth: 1.5)
                    pill(object.label, at: CGPoint(x: rect.midX, y: rect.maxY + 4), color: Theme.scan.opacity(p), size: 11,
                         anchor: .top)
                }
                if showZone, let zone {
                    context.stroke(Path(roundedRect: imageRect.rect(atNormalized: zone), cornerRadius: 8),
                                   with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
                if let box {
                    let p = appear(targetShownAt)
                    let rect = popping(imageRect.rect(atNormalized: box), p)
                    let color = Self.color(for: state).opacity(p)
                    if state == .guiding || state == .lost {
                        // From the fingertip, or from the user's body (bottom center) when no hand is in view.
                        var line = Path()
                        line.move(to: imageRect.point(atNormalized: tip ?? CGPoint(x: 0.5, y: 1)))
                        line.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
                        context.stroke(line, with: .color(Theme.accent.opacity(tip == nil ? 0.3 : 0.6)),
                                       style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
                    }
                    let path = Path(roundedRect: rect, cornerRadius: 12)
                    context.stroke(path, with: .color(color.opacity(0.25)), lineWidth: 10)  // glow
                    context.stroke(path, with: .color(color), lineWidth: 3)
                    if let label {
                        pill(label, at: CGPoint(x: rect.midX, y: rect.minY - 6), color: color, size: 15, anchor: .bottom)
                    }
                }
                if let tip {
                    let p = imageRect.point(atNormalized: tip)
                    context.stroke(Path(ellipseIn: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)),
                                   with: .color(.white), lineWidth: 3)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(Theme.success))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func color(for state: Guide.State) -> Color {
        switch state {
        case .locked: Theme.success
        case .lost: Theme.warning
        case .idle, .locating, .guiding: Theme.accent
        }
    }
}

/// "Gemini 1.4 s": how long the last Gemini call took (judge view polish).
struct LatencyChip: View {
    let milliseconds: Double

    var body: some View {
        Label(String(format: "Gemini %.1f s", milliseconds / 1000), systemImage: "sparkles")
            .font(Theme.rounded(13))
            .foregroundStyle(Color(red: 0.78, green: 0.70, blue: 1.0))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
