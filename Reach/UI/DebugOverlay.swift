import SwiftUI

/// Mirrored-to-laptop judge view: what Reach sees and is tracking.
struct DebugOverlay: View {
    let model: AppModel
    let imageRect: CGRect

    var body: some View {
        // Read here (not inside Canvas) so Observation redraws on change.
        let tip = model.fingertip, box = model.targetBox, zone = model.lockZone, state = model.state
        let label = model.targetLabel
        let scene = model.sceneBoxes, touched = model.touchedLabel
        Canvas { context, _ in
            // Everything the table scan found; the one under the fingertip is filled.
            for object in scene {
                let rect = imageRect.rect(atNormalized: object.box)
                if object.label == touched { context.fill(Path(rect), with: .color(.cyan.opacity(0.3))) }
                context.stroke(Path(rect), with: .color(.cyan), lineWidth: 2)
                context.draw(Text(object.label).font(.caption.bold()).foregroundStyle(.cyan),
                             at: CGPoint(x: rect.midX, y: rect.maxY + 2), anchor: .top)
            }
            if let zone {
                context.stroke(Path(imageRect.rect(atNormalized: zone)), with: .color(.white.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
            }
            if let box {
                let rect = imageRect.rect(atNormalized: box)
                context.stroke(Path(rect), with: .color(Self.color(for: state)), lineWidth: 3)
                if let label {
                    context.draw(Text(label).font(.headline).foregroundStyle(Self.color(for: state)),
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

struct StatusHUD: View {
    let model: AppModel

    var body: some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private var text: String {
        if let error = model.cameraError { return error }
        let hand = model.fingertip == nil ? "hand –" : "hand ✓"
        let key = AppConfig.geminiAPIKey.isEmpty ? "key ✗" : "key ✓"
        var lines = ["\(model.state.rawValue)  \(hand)  \(Int(model.fps.rounded())) fps  \(Int(model.latencyMs)) ms  \(key)"]
        if let note = model.trackingNote { lines.append("AR: \(note)") }
        if !model.lastHeard.isEmpty || model.locateMs != nil || model.readMs != nil {
            let gemini = model.locateMs.map { String(format: "  gemini %.1f s", $0 / 1000) } ?? ""
            let claude = model.readMs.map { String(format: "  claude %.1f s", $0 / 1000) } ?? ""
            lines.append("heard “\(model.lastHeard)”\(gemini)\(claude)")
        }
        if let caption = model.caption { lines.append("🔊 \(caption)") }
        return lines.joined(separator: "\n")
    }
}
