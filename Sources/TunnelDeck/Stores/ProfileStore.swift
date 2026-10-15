import Foundation
import TunnelCore

struct ProfileStore {
    struct Document: Codable {
        var profiles: [VPNProfile] = []
        var selectedProfile: UUID?
        var profilesWithoutSecrets: Set<UUID> = []
    }

    let file: URL

    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TunnelDeck/profiles.json")) {
        self.file = file
    }

    func load() -> Document {
        guard let data = try? Data(contentsOf: file) else { return Document() }
        if let document = try? JSONDecoder().decode(Document.self, from: data) { return document }
        // Keep profiles created by earlier builds when upgrading the storage format.
        let profiles = (try? JSONDecoder().decode([VPNProfile].self, from: data)) ?? []
        return Document(profiles: profiles)
    }
    func save(_ document: Document) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
