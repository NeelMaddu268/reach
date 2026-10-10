import Foundation

enum AppConfig {
    /// Set in Config/Secrets.xcconfig, passed through Info.plist. Empty when missing.
    static let geminiAPIKey = Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String ?? ""
}
