import SwiftUI

/// Captions for the mirrored judge view: what the user said and what Reach said. Big enough to read on a laptop
/// across the room.
struct CaptionView: View {
    let heard: String?
    let said: String?
    var big = true

    var body: some View {
        if heard != nil || said != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let heard {
                    Label("“\(heard)”", systemImage: "mic.fill")
                        .foregroundStyle(.yellow)
                }
                if let said {
                    Label(said, systemImage: "speaker.wave.2.fill")
                        .foregroundStyle(.white)
                }
            }
            .font(.system(size: big ? 30 : 20, weight: .bold, design: .rounded))
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
            .allowsHitTesting(false)
            .accessibilityHidden(true)  // it's all spoken already
        }
    }
}
