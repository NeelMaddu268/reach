import SwiftUI

/// Maps normalized image coordinates (origin top-left) onto the screen, matching the aspect-fit preview.
enum ImageSpace {
    static let aspect: CGFloat = 720.0 / 1280.0  // portrait 1280×720 frames

    static func fitRect(in size: CGSize) -> CGRect {
        var width = size.width, height = size.width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

extension CGRect {
    func point(atNormalized p: CGPoint) -> CGPoint {
        CGPoint(x: minX + p.x * width, y: minY + p.y * height)
    }
}

/// Mirrored-to-laptop judge view: what Reach sees and is tracking.
struct DebugOverlay: View {
    let model: AppModel
    let imageRect: CGRect

    var body: some View {
        let tip = model.fingertip  // read here (not inside Canvas) so Observation redraws on change
        Canvas { context, _ in
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
        return "\(hand)  \(Int(model.fps.rounded())) fps  \(Int(model.latencyMs)) ms  \(key)"
    }
}
