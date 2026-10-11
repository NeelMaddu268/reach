import SwiftUI

/// Top-down view of the table for the judge screen, in meters from the user's body: pinned objects, the hand,
/// and rings that pulse out of the target at the sonar's tick rate.
struct Minimap {
    struct Mark {
        var label: String
        /// Meters right of / forward from the user's body.
        var at: CGPoint
        var isTarget: Bool
    }

    var marks: [Mark]
    var hand: CGPoint?
    var tone: AudioGuide.Tone
}

struct MinimapView: View {
    let map: Minimap

    /// Meters shown either side of the body, and forward from it.
    static let halfWidth: CGFloat = 0.4
    static let depth: CGFloat = 0.7

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                func point(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: size.width / 2 + p.x / Self.halfWidth * size.width / 2, y: size.height - p.y / Self.depth * size.height)
                }
                func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                }

                // The user, at the bottom edge.
                var body = Path()
                body.addArc(center: CGPoint(x: size.width / 2, y: size.height), radius: 10,
                            startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                context.fill(body, with: .color(.white.opacity(0.7)))

                if let target = map.marks.first(where: \.isTarget), map.tone.volume > 0 {
                    let center = point(target.at)
                    if map.tone.beepPeriod > 0 {  // a ring per tick
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: map.tone.beepPeriod) / map.tone.beepPeriod
                        context.stroke(circle(center, 6 + phase * 28), with: .color(.yellow.opacity(1 - phase)), lineWidth: 2)
                    } else {  // solid tone: the hand is right over it
                        context.stroke(circle(center, 14), with: .color(.yellow), lineWidth: 3)
                    }
                }
                for mark in map.marks {
                    let center = point(mark.at)
                    let color: Color = mark.isTarget ? .yellow : .cyan
                    context.fill(circle(center, mark.isTarget ? 6 : 4), with: .color(color))
                    context.draw(Text(mark.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(color),
                                 at: CGPoint(x: center.x, y: center.y + 7), anchor: .top)
                }
                if let hand = map.hand {
                    context.fill(circle(point(hand), 5), with: .color(.green))
                    context.stroke(circle(point(hand), 5), with: .color(.white), lineWidth: 1)
                }
            }
        }
        .frame(width: 150, height: 150)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.3)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
