import AppIntents

/// "Hey Siri, Reach find" → "What should I find?" → "my keys" → Reach opens and starts guiding.
struct FindIntent: AppIntent {
    static let title: LocalizedStringResource = "Find an object"
    static let description = IntentDescription("Opens Reach and guides your hand to an object on the table.")
    static let openAppWhenRun = true

    @Parameter(title: "Object", requestValueDialog: "What should I find?")
    var object: String

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriRequests.shared.send(.find(object))
        return .result()
    }
}

/// "Hey Siri, what's on the table in Reach" → Reach opens and scans the table.
struct ScanIntent: AppIntent {
    static let title: LocalizedStringResource = "What's on the table"
    static let description = IntentDescription("Opens Reach and names everything on the table, left to right.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SiriRequests.shared.send(.scan)
        return .result()
    }
}

/// Siri phrases, registered when the app is installed (no setup in the Shortcuts app).
/// Siri doesn't allow free-form words inside a phrase, so the object is asked for separately.
struct ReachShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindIntent(), phrases: [
            "\(.applicationName) find",
            "Find something with \(.applicationName)",
            "Find with \(.applicationName)",
        ], shortTitle: "Find", systemImageName: "hand.point.up.left")
        AppShortcut(intent: ScanIntent(), phrases: [
            "What's on the table in \(.applicationName)",
            "\(.applicationName) what's on the table",
        ], shortTitle: "What's on the table", systemImageName: "eye")
    }
}

/// Hands Siri requests to the app model, holding one until the model is ready (Siri can cold-launch the app).
@MainActor
final class SiriRequests {
    enum Request {
        case find(String)
        case scan
    }

    static let shared = SiriRequests()
    private(set) var pending: Request?
    var handler: ((Request) -> Void)? {
        didSet {
            guard let handler, let pending else { return }
            self.pending = nil
            handler(pending)
        }
    }

    func send(_ request: Request) {
        if let handler { handler(request) } else { pending = request }
    }
}
