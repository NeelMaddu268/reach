import Foundation

enum AppConfig {
    /// Set in Config/Secrets.xcconfig, passed through Info.plist. Empty when missing.
    static let geminiAPIKey = Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String ?? ""
    static let anthropicAPIKey = Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") as? String ?? ""
    /// Only needed when the key isn't scoped to a workspace.
    static let anthropicWorkspaceID = Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_WORKSPACE_ID") as? String ?? ""
    static let elevenLabsAPIKey = Bundle.main.object(forInfoDictionaryKey: "ELEVENLABS_API_KEY") as? String ?? ""
}
