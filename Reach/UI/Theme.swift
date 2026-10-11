import SwiftUI

/// Reach's look: dark, calm, one warm accent for the target.
enum Theme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.08)
    static let card = Color(red: 0.10, green: 0.11, blue: 0.15)
    /// The target and everything about "where to go".
    static let accent = Color(red: 1.0, green: 0.78, blue: 0.26)
    /// Things the table scan found.
    static let scan = Color(red: 0.42, green: 0.86, blue: 0.96)
    static let success = Color(red: 0.32, green: 0.86, blue: 0.52)
    static let warning = Color(red: 1.0, green: 0.58, blue: 0.24)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.38)
    static let mic = LinearGradient(colors: [Color(red: 0.38, green: 0.56, blue: 1.0), Color(red: 0.60, green: 0.38, blue: 1.0)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
