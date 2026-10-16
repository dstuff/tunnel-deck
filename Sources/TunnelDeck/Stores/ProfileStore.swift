import Foundation
import Darwin
import TunnelCore

protocol ProfileStorage {
    func load() throws -> ProfileStore.Document
    func save(_ document: ProfileStore.Document) throws
}

struct ProfileStore: ProfileStorage {
    struct Document: Codable {
        let version: Int
        var profiles: [VPNProfile] = []
        var selectedProfile: UUID?
        var secrets: [String: ProfileSecrets] = [:]

        init(profiles: [VPNProfile] = [], selectedProfile: UUID? = nil,
             secrets: [String: ProfileSecrets] = [:]) {
            version = 2
            self.profiles = profiles
            self.selectedProfile = selectedProfile
            self.secrets = secrets
        }

        private enum CodingKeys: String, CodingKey { case version, profiles, selectedProfile, secrets }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let storedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            guard storedVersion == 1 || storedVersion == 2 else {
                throw VPNError("Версия локального файла профилей не поддерживается. Обновите приложение или восстановите совместимый файл и перезапустите TunnelDeck.")
            }
            version = 2
            profiles = try values.decode([VPNProfile].self, forKey: .profiles)
            selectedProfile = try values.decodeIfPresent(UUID.self, forKey: .selectedProfile)
            // Earlier files contain metadata only. Never read their secrets from Keychain.
            secrets = storedVersion == 2 ? try values.decode([String: ProfileSecrets].self, forKey: .secrets) : [:]
        }
    }

    let file: URL

    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TunnelDeck/profiles.json")) {
        self.file = file
    }

    func load() throws -> Document {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch CocoaError.fileReadNoSuchFile { return Document() }
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
