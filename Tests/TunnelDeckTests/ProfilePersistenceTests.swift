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
        let model = AppModel(profileStore: store, arguments: [])
        let ocID = model.draft.id
        model.draft.name = "Рабочий ocserv"
        model.draft.server = "https://vpn.example:443/login?opaque%2Fsecret"
        model.draft.username = "test-user"
        model.draft.authGroup = "staff"
        model.draft.certificatePin = "pin-sha256:example"
        model.draft.disableDTLS = true
        model.secrets.password = "test-password"
        try await Task.sleep(for: .milliseconds(650))

        let restoredOC = AppModel(profileStore: store, arguments: [])
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

        let restarted = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(restarted.profiles.count, 3)
        XCTAssertEqual(restarted.selection, xrayID)
        XCTAssertEqual(restarted.secrets.configuration, "vless://test-id@vpn.example:443#Saved")
        restarted.select(awgID)
        XCTAssertEqual(restarted.secrets.configuration, "[Interface]\nPrivateKey = test-private-key")
        restarted.select(ocID)
        XCTAssertEqual(restarted.secrets.password, "test-password")

        let metadata = try String(contentsOf: store.file, encoding: .utf8)
        for secret in ["test-password", "opaque%2Fsecret", "test-private-key", "vless://"] {
            XCTAssertTrue(metadata.contains(secret), "All profile data must be stored locally")
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let directory = store.file.deletingLastPathComponent()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["profiles.json"])
    }

    func testCombinedAddressReplacesLegacySecretAndSurvivesRestart() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: store, arguments: [])
        model.draft.server = "https://old.example/"
        model.secrets.camouflage = "old-secret"
        model.secrets.password = "keep-password"
        XCTAssertEqual(model.openConnectAddress, "https://old.example/?old-secret")

        let address = "https://new.example:443/login?new%2Fsecret+with=parameters"
        model.openConnectAddress = address
        XCTAssertTrue(model.secrets.camouflage.isEmpty)
        XCTAssertTrue(model.save())
        let restarted = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(restarted.openConnectAddress, address)
        XCTAssertEqual(restarted.secrets.password, "keep-password")
        let config = try OpenConnectConfiguration.make(profile: restarted.draft, secrets: restarted.secrets)
        XCTAssertTrue(config.contains("server=\(address)\n"))
        let metadata = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertTrue(metadata.contains("new%2Fsecret"))
        XCTAssertFalse(metadata.contains("old-secret"))

        restarted.openConnectAddress = "https://new.example/"
        XCTAssertTrue(restarted.save())
        let withoutSecret = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(withoutSecret.openConnectAddress, "https://new.example/")
        XCTAssertTrue(withoutSecret.secrets.camouflage.isEmpty)
    }

    func testUnfinishedAndConflictingServerInputSurvivesRestart() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: store, arguments: [])
        model.draft.server = "https://"
        try await Task.sleep(for: .milliseconds(650))
        let restarted = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(restarted.draft.server, "https://")
        XCTAssertNil(model.persistenceError)

        restarted.draft.server = "https://vpn.example/?first-secret"
        restarted.secrets.camouflage = "other-secret"
        XCTAssertTrue(restarted.save())
        let next = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(next.draft.server, "https://vpn.example/?first-secret")
        XCTAssertEqual(next.secrets.camouflage, "other-secret")
        XCTAssertThrowsError(try VPNEndpoint(server: next.draft.server, camouflage: next.secrets.camouflage))
        let metadata = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertTrue(metadata.contains("first-secret"))
        XCTAssertTrue(metadata.contains("other-secret"))
    }

    func testLegacyProfilesAreMigratedWithoutChangingIDs() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let profile = VPNProfile(name: "Existing", server: "https://vpn.example/")
        try JSONEncoder().encode([profile]).write(to: store.file)
        let model = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(model.draft, profile)
        XCTAssertTrue(model.secrets.password.isEmpty)
        XCTAssertTrue(model.save())
        XCTAssertEqual((try store.load()).profiles, [profile])
        XCTAssertEqual((try store.load()).selectedProfile, profile.id)
    }

    func testSaveFailureKeepsCurrentEditsAndPreventsProfileSwitch() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let first = VPNProfile(name: "First")
        let second = VPNProfile(name: "Second")
        try store.save(.init(profiles: [first, second], selectedProfile: first.id))
        let failing = FailingProfileStore(store: store)
        let model = AppModel(profileStore: failing, arguments: [])
        let originalData = try Data(contentsOf: store.file)
        model.draft.name = "Unsaved name"
        model.secrets.password = "unsaved-password"
        failing.rejectWrites = true
        model.select(second.id)
        XCTAssertEqual(model.selection, first.id)
        XCTAssertEqual(model.secrets.password, "unsaved-password")
        XCTAssertEqual(model.draft.name, "Unsaved name")
        XCTAssertEqual(model.profiles[0].name, "First")
        XCTAssertEqual(try Data(contentsOf: store.file), originalData)
        XCTAssertNotNil(model.persistenceError)
        failing.rejectWrites = false
        XCTAssertTrue(model.save())
        XCTAssertNil(model.persistenceError)
    }

    func testDeletingProfileCancelsPendingSaveAndRemovesSecrets() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: store, arguments: [])
        let deletedID = model.draft.id
        model.secrets.password = "delete-me"
        XCTAssertTrue(model.save())
        model.draft.name = "Pending edit"
        model.deleteSelected()
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertNil((try store.load()).secrets[deletedID.uuidString])
        XCTAssertFalse((try store.load()).profiles.contains(where: { $0.id == deletedID }))
        XCTAssertEqual((try store.load()).selectedProfile, model.draft.id)
    }

    func testQuickImportPersistsAllDataWithoutConnecting() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: store, arguments: [])
        let original = model.draft.id
        model.draft.name = "Existing edits"
        let link = "trojan://synthetic-password@vpn.example:443#Imported"
        XCTAssertTrue(model.importConnection(try ConnectionImport(link), name: "", username: "unused-user", password: "unused-password"))
        let importedID = model.draft.id
        XCTAssertNotEqual(importedID, original)
        XCTAssertEqual(model.draft.name, "Imported")
        XCTAssertEqual(model.secrets.configuration, link)
        XCTAssertTrue(model.draft.username.isEmpty)
        XCTAssertTrue(model.secrets.password.isEmpty)
        XCTAssertEqual((try store.load()).secrets[importedID.uuidString]?.configuration, link)
        XCTAssertEqual(model.connection.state, .idle, "Import must not start a connection")
        XCTAssertEqual((try store.load()).profiles.first?.name, "Existing edits")
        let metadata = try String(contentsOf: store.file, encoding: .utf8)
        XCTAssertTrue(metadata.contains("synthetic-password"))
        XCTAssertTrue(metadata.contains("trojan://"))
        let restarted = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(restarted.selection, importedID)
        XCTAssertEqual(restarted.secrets.configuration, link)
    }

    func testImportFailureDoesNotCreateOrSelectPartialProfile() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let failing = FailingProfileStore(store: store)
        let model = AppModel(profileStore: failing, arguments: [])
        XCTAssertTrue(model.save())
        let original = model.draft.id
        let originalData = try Data(contentsOf: store.file)
        failing.maximumProfiles = 1
        let imported = try ConnectionImport("https://vpn.example/?synthetic-secret")
        XCTAssertFalse(model.importConnection(imported, name: "New", username: "test-user", password: "synthetic-password"))
        XCTAssertEqual(model.selection, original)
        XCTAssertEqual(model.profiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: store.file), originalData)
        XCTAssertNotNil(model.persistenceError)
    }

    func testLegacyDocumentKeepsOrderSelectionAndIgnoresOldOptOut() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        struct LegacyDocument: Encodable {
            let profiles: [VPNProfile]
            let selectedProfile: UUID
            let profilesWithoutSecrets: [UUID]
        }
        let first = VPNProfile(name: "First")
        let second = VPNProfile(name: "Second", kind: .xray)
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(LegacyDocument(profiles: [first, second], selectedProfile: second.id,
                                                profilesWithoutSecrets: [second.id])).write(to: store.file)
        let model = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(model.profiles, [first, second])
        XCTAssertEqual(model.selection, second.id)
        XCTAssertTrue(model.secrets.configuration.isEmpty)
        model.secrets.configuration = "vless://synthetic-id@vpn.example:443"
        XCTAssertTrue(model.save())
        let document = try store.load()
        XCTAssertEqual(document.version, 2)
        XCTAssertEqual(document.profiles, [first, second])
        let restarted = AppModel(profileStore: store, arguments: [])
        XCTAssertEqual(restarted.secrets.configuration, model.secrets.configuration)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
        XCTAssertNil(json["profilesWithoutSecrets"])
    }

    func testUnreadableInvalidAndFutureFilesAreNotOverwritten() throws {
        let store = temporaryStore()
        let directory = store.file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(try store.load().profiles.isEmpty, "A missing file is a valid first launch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for contents in ["{invalid-json-with-synthetic-secret", "", "{\"version\":99,\"profiles\":[],\"secrets\":{}}",
                         "{\"version\":2,\"profiles\":[]}"] {
            let original = Data(contents.utf8)
            try original.write(to: store.file)
            XCTAssertThrowsError(try store.load())
            let model = AppModel(profileStore: store, arguments: [])
            XCTAssertNotNil(model.persistenceError)
            XCTAssertFalse(model.persistenceError?.contains("synthetic-secret") ?? true)
            model.secrets.password = "must-not-overwrite"
            XCTAssertFalse(model.save())
            model.add(.xray)
            model.deleteSelected()
            XCTAssertFalse(model.importConnection(try ConnectionImport("https://vpn.example/"), name: "", username: "", password: ""))
            XCTAssertEqual(try Data(contentsOf: store.file), original)
        }
        try FileManager.default.removeItem(at: store.file)
        try FileManager.default.createDirectory(at: store.file, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.load())
        let unreadable = AppModel(profileStore: store, arguments: [])
        XCTAssertNotNil(unreadable.persistenceError)
        XCTAssertFalse(unreadable.save())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.file.path), [])
    }

    func testFailedAddDeleteAndSelectionKeepThePreviousDocument() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.file.deletingLastPathComponent()) }
        let first = VPNProfile(name: "First")
        let second = VPNProfile(name: "Second")
        var savedSecrets = ProfileSecrets()
        savedSecrets.password = "synthetic-password"
        try store.save(.init(profiles: [first, second], selectedProfile: first.id,
                             secrets: [first.id.uuidString: savedSecrets, second.id.uuidString: ProfileSecrets()]))
        let original = try Data(contentsOf: store.file)
        let failing = FailingProfileStore(store: store)
        let model = AppModel(profileStore: failing, arguments: [])
        failing.maximumProfiles = 2
        model.add(.xray)
        XCTAssertEqual(model.profiles, [first, second])
        XCTAssertEqual(model.selection, first.id)
        failing.rejectWrites = true
        model.deleteSelected()
        XCTAssertEqual(model.profiles, [first, second])
        XCTAssertEqual(model.secrets.password, "synthetic-password")
        failing.rejectWrites = false
        failing.rejectedSelection = second.id
        model.selection = second.id
        model.select(second.id)
        XCTAssertEqual(model.selection, first.id)
        XCTAssertEqual(try Data(contentsOf: store.file), original)
        XCTAssertNotNil(model.persistenceError)
    }

    func testAtomicReplacementFailureRemovesPrivateTemporaryFile() throws {
        let store = temporaryStore()
        let directory = store.file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A directory at the destination guarantees that rename fails, even as root.
        try FileManager.default.createDirectory(at: store.file, withIntermediateDirectories: true)
        let marker = store.file.appendingPathComponent("keep")
        try Data("original".utf8).write(to: marker)
        XCTAssertThrowsError(try store.save(.init(profiles: [VPNProfile()])))
        XCTAssertEqual(try Data(contentsOf: marker), Data("original".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["profiles.json"])
        try FileManager.default.removeItem(at: store.file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try store.save(.init())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int, 0o600)
    }
}

private final class FailingProfileStore: ProfileStorage {
    let store: ProfileStore
    var rejectWrites = false
    var maximumProfiles = Int.max
    var rejectedSelection: UUID?
    init(store: ProfileStore) { self.store = store }
    func load() throws -> ProfileStore.Document { try store.load() }
    func save(_ document: ProfileStore.Document) throws {
        if rejectWrites || document.profiles.count > maximumProfiles ||
            (rejectedSelection != nil && document.selectedProfile == rejectedSelection) {
            throw VPNError("Test file write failure")
        }
        try store.save(document)
    }
}
