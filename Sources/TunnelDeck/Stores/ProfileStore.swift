import Foundation
import Darwin
import TunnelCore

protocol ProfileStorage {
    /// nil means first launch; a saved document may intentionally contain no profiles.
    func load() throws -> ProfileStore.Document?
    func save(_ document: ProfileStore.Document) throws
}

struct ProfileStore: ProfileStorage {
    struct Document: Codable {
        let version: Int
        var profiles: [VPNProfile] = []
        var selectedProfile: UUID?
        var secrets: [String: ProfileSecrets] = [:]
        var routing: RoutingPolicy = .init()

        init(profiles: [VPNProfile] = [], selectedProfile: UUID? = nil,
             secrets: [String: ProfileSecrets] = [:], routing: RoutingPolicy = .init()) {
            version = 3
            self.profiles = profiles
            self.selectedProfile = selectedProfile
            self.secrets = secrets
            self.routing = routing
        }

        private enum CodingKeys: String, CodingKey { case version, profiles, selectedProfile, secrets, routing }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let storedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            guard (1...3).contains(storedVersion) else {
                throw VPNError("Версия локального файла профилей не поддерживается. Обновите приложение или восстановите совместимый файл и перезапустите TunnelDeck.")
            }
            version = 3
            profiles = try values.decode([VPNProfile].self, forKey: .profiles)
            selectedProfile = try values.decodeIfPresent(UUID.self, forKey: .selectedProfile)
            // Earlier files contain metadata only. Never read their secrets from Keychain.
            secrets = storedVersion >= 2 ? try values.decode([String: ProfileSecrets].self, forKey: .secrets) : [:]
            routing = storedVersion >= 3 ? try values.decode(RoutingPolicy.self, forKey: .routing) : .init()
            guard routing.format == "tunneldeck-routing", routing.version == 1 else { throw VPNError("Версия локальной схемы маршрутизации не поддерживается.") }
        }
    }

    let file: URL

    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TunnelDeck/profiles.json")) {
        self.file = file
    }

    func load() throws -> Document? {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch { throw VPNError("Не удалось прочитать локальный файл профилей. Проверьте доступ к файлу и перезапустите TunnelDeck.") }
        do {
            let decoder = JSONDecoder()
            if let profiles = try? decoder.decode([VPNProfile].self, from: data) {
                return Document(profiles: profiles)
            }
            return try decoder.decode(Document.self, from: data)
        } catch let error as VPNError { throw error }
        catch { throw VPNError("Локальный файл профилей повреждён. Исправьте или восстановите файл и перезапустите TunnelDeck. Исходный файл не изменён.") }
    }

    func save(_ document: Document) throws {
        let directory = file.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(document)
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                try? manager.removeItem(at: temporary)
            }
            guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(.EIO) }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporary.path, file.path) == 0 else { throw POSIXError(.EIO) }
        } catch {
            throw VPNError("Не удалось записать локальный файл профилей. Проверьте права доступа и свободное место.")
        }
    }
}
