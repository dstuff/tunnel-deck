import XCTest
import TunnelCore
@testable import TunnelDeck

@MainActor final class ProfilePersistenceTests: XCTestCase {
    private func temporaryStore() -> ProfileStore {
        ProfileStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelDeckTests-\(UUID().uuidString)/profiles.json"))
    }

    func testAutosaveRestoresAllProtocolsSecretsAndSelection() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let keychain = MemorySecretStore()
        let model = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        let ocID = model.draft.id
        model.draft.name = "Рабочий ocserv"
        model.draft.server = "https://vpn.example:443/login?opaque%2Fsecret"
        model.draft.username = "test-user"
        model.draft.authGroup = "staff"
        model.draft.certificatePin = "pin-sha256:example"
        model.draft.disableDTLS = true
        model.secrets.password = "test-password"
        XCTAssertTrue(model.rememberSecrets)
        try await Task.sleep(for: .milliseconds(650))

        let restoredOC = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        XCTAssertEqual(restoredOC.draft.name, "Рабочий ocserv")
        XCTAssertEqual(restoredOC.draft.server, "https://vpn.example:443/login")
        XCTAssertEqual(restoredOC.draft.username, "test-user")
        XCTAssertEqual(restoredOC.draft.authGroup, "staff")
        XCTAssertEqual(restoredOC.draft.certificatePin, "pin-sha256:example")
        XCTAssertTrue(restoredOC.draft.disableDTLS)
        XCTAssertEqual(restoredOC.secrets.password, "test-password")
        XCTAssertEqual(restoredOC.secrets.camouflage, "opaque%2Fsecret")

        model.add(.amneziaWG)
        let awgID = model.draft.id
        model.draft.name = "AWG"
        model.secrets.configuration = "[Interface]\nPrivateKey = test-private-key"
        // Switching immediately must flush pending edits, without waiting for autosave.
        model.select(ocID)
        model.add(.xray)
        let xrayID = model.draft.id
        model.draft.name = "Xray"
        model.secrets.configuration = "vless://test-id@vpn.example:443#Saved"
        try await Task.sleep(for: .milliseconds(650))

        let restarted = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        XCTAssertEqual(restarted.profiles.count, 3)
        XCTAssertEqual(restarted.selection, xrayID)
        XCTAssertEqual(restarted.secrets.configuration, "vless://test-id@vpn.example:443#Saved")
        restarted.select(awgID)
        XCTAssertEqual(restarted.secrets.configuration, "[Interface]\nPrivateKey = test-private-key")
        restarted.select(ocID)
        XCTAssertEqual(restarted.secrets.password, "test-password")

        let metadata = try String(contentsOf: store.file, encoding: .utf8)
        for secret in ["test-password", "opaque%2Fsecret", "test-private-key", "vless://"] {
            XCTAssertFalse(metadata.contains(secret), "Secret leaked into profile metadata")
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testOptOutRemovesSecretsAndSurvivesRestart() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let keychain = MemorySecretStore()
        let model = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        let id = model.draft.id
        model.secrets.password = "session-only"
        XCTAssertTrue(model.save())
        XCTAssertNotNil(keychain.items[id])
        model.rememberSecrets = false
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertNil(keychain.items[id])

        model.add(.xray)
        XCTAssertTrue(model.rememberSecrets)
        model.select(id)
        XCTAssertFalse(model.rememberSecrets)
        XCTAssertEqual(model.secrets.password, "session-only")
        let restarted = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        XCTAssertFalse(restarted.rememberSecrets)
        XCTAssertTrue(restarted.secrets.password.isEmpty)
    }

    func testCombinedAddressReplacesLegacySecretAndSurvivesRestart() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let keychain = MemorySecretStore()
        let model = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        model.draft.server = "https://old.example/"
        model.secrets.camouflage = "old-secret"
        model.secrets.password = "keep-password"
        XCTAssertEqual(model.openConnectAddress, "https://old.example/?old-secret")

        let address = "https://new.example:443/login?new%2Fsecret+with=parameters"
        model.openConnectAddress = address
        XCTAssertTrue(model.secrets.camouflage.isEmpty)
        XCTAssertTrue(model.save())
        let restarted = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        XCTAssertEqual(restarted.openConnectAddress, address)
        XCTAssertEqual(restarted.secrets.password, "keep-password")
        let config = try OpenConnectConfiguration.make(profile: restarted.draft, secrets: restarted.secrets)
        XCTAssertTrue(config.contains("server=\(address)\n"))
        let metadata = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertFalse(metadata.contains("new%2Fsecret"))
        XCTAssertFalse(metadata.contains("old-secret"))

        restarted.openConnectAddress = "https://new.example/"
        XCTAssertTrue(restarted.save())
        let withoutSecret = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        XCTAssertEqual(withoutSecret.openConnectAddress, "https://new.example/")
        XCTAssertTrue(withoutSecret.secrets.camouflage.isEmpty)
    }

    func testUnfinishedAndConflictingServerInputSurvivesRestart() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let keychain = MemorySecretStore()
        let model = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        model.draft.server = "https://"
        try await Task.sleep(for: .milliseconds(650))
        let restarted = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        XCTAssertEqual(restarted.draft.server, "https://")
        XCTAssertNil(model.persistenceError)

        restarted.draft.server = "https://vpn.example/?first-secret"
        restarted.secrets.camouflage = "other-secret"
        XCTAssertTrue(restarted.save())
        let next = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        XCTAssertEqual(next.draft.server, "https://vpn.example/?first-secret")
        XCTAssertEqual(next.secrets.camouflage, "other-secret")
        XCTAssertThrowsError(try VPNEndpoint(server: next.draft.server, camouflage: next.secrets.camouflage))
        let metadata = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertFalse(metadata.contains("first-secret"))
        XCTAssertFalse(metadata.contains("other-secret"))
    }

    func testLegacyProfilesAreMigratedWithoutChangingIDs() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let profile = VPNProfile(name: "Existing", server: "https://vpn.example/")
        try JSONEncoder().encode([profile]).write(to: store.file)
        let keychain = MemorySecretStore()
        var secrets = ProfileSecrets()
        secrets.password = "existing-password"
        keychain.items[profile.id] = secrets

        let model = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        XCTAssertEqual(model.draft, profile)
        XCTAssertEqual(model.secrets.password, "existing-password")
        XCTAssertTrue(model.rememberSecrets)
        XCTAssertTrue(model.save())
        XCTAssertEqual(store.load().profiles, [profile])
        XCTAssertEqual(store.load().selectedProfile, profile.id)
    }

    func testSaveFailureKeepsCurrentEditsAndPreventsProfileSwitch() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let first = VPNProfile(name: "First")
        let second = VPNProfile(name: "Second")
        try store.save(.init(profiles: [first, second], selectedProfile: first.id))
        let keychain = MemorySecretStore()
        let model = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        model.secrets.password = "unsaved-password"
        keychain.rejectWrites = true
        model.select(second.id)
        XCTAssertEqual(model.selection, first.id)
        XCTAssertEqual(model.secrets.password, "unsaved-password")
        XCTAssertNotNil(model.persistenceError)
        keychain.rejectWrites = false
        XCTAssertTrue(model.save())
        XCTAssertNil(model.persistenceError)
    }

    func testDeletingProfileCancelsPendingSaveAndRemovesSecrets() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let keychain = MemorySecretStore()
        let model = AppModel(profileStore: store, secretStore: keychain, arguments: [])
        let deletedID = model.draft.id
        model.secrets.password = "delete-me"
        XCTAssertTrue(model.save())
        model.draft.name = "Pending edit"
        model.deleteSelected()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertNil(keychain.items[deletedID])
        XCTAssertFalse(store.load().profiles.contains(where: { $0.id == deletedID }))
        XCTAssertEqual(store.load().selectedProfile, model.draft.id)
    }
}

private final class MemorySecretStore: ProfileSecretStorage {
    var items: [UUID: ProfileSecrets] = [:]
    var rejectWrites = false
    func load(_ id: UUID) -> ProfileSecrets? { items[id] }
    func save(_ secrets: ProfileSecrets, id: UUID) throws {
        if rejectWrites { throw VPNError("Test Keychain failure") }
        items[id] = secrets
    }
    func delete(_ id: UUID) throws { items.removeValue(forKey: id) }
}
