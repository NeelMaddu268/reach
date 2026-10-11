import Foundation

/// "This is my mug": reference photos of the user's own things, kept across launches, so "find my mug" can pick
/// theirs out of similar ones.
enum MyObjects {
    /// Saves a reference photo for `label`, replacing any earlier one.
    static func save(_ jpeg: Data, as label: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: folder.appendingPathComponent(ElevenLabs.slug(label) + ".jpg"))
    }

    /// The reference photo for whatever `query` names ("mug" finds "my mug"), if there is one.
    static func reference(for query: String) -> Data? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let match = files.first { file in
            let label = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            return AppModel.matches(label, query)
        }
        return match.flatMap { try? Data(contentsOf: $0) }
    }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MyObjects")
    }
}
