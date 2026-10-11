import SwiftUI

/// Captions for the mirrored judge view: what the user said and what Reach said. Big enough to read on a laptop
/// across the room.
struct CaptionView: View {
    let heard: String?
    let said: String?
    var big = true

    var body: some View {
        if heard != nil || said != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let heard { line("YOU", "“\(heard)”", color: Theme.accent) }
                if let said { line("REACH", said, color: .white) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)  // it's all spoken already
        }
    }

    private func line(_ tag: String, _ text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tag)
                .font(Theme.rounded(11, .bold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.55))
            Text(text)
                .font(Theme.rounded(big ? 26 : 18, .bold))
                .foregroundStyle(color)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
        }
    }
}
