import XCTest
import TunnelCore
@testable import TunnelDeck

@MainActor final class RoutingPersistenceTests: XCTestCase {
    private func store() -> ProfileStore {
        .init(file: FileManager.default.temporaryDirectory.appendingPathComponent("RoutingTests-\(UUID().uuidString)/profiles.json"))
    }
    func testRoutingAutosaveAndLegacyMigration() async throws {
        let storage = store(); defer { try? FileManager.default.removeItem(at: storage.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: storage, arguments: [])
        XCTAssertEqual(model.routing.defaultAction, .vpn)
        model.routing.name = "Общие правила"
        model.routing.rules = [.init(match: .init(type: .country, value: "RU"), action: .direct)]
        try await Task.sleep(for: .milliseconds(600))
        let restarted = AppModel(profileStore: storage, arguments: [])
        XCTAssertEqual(restarted.routing, model.routing)
        XCTAssertEqual(try storage.load().version, 3)
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: storage.file)) as! [String: Any]
        document["version"] = 2; document.removeValue(forKey: "routing")
        try JSONSerialization.data(withJSONObject: document).write(to: storage.file)
        XCTAssertEqual(AppModel(profileStore: storage, arguments: []).routing, RoutingPolicy())
    }
    func testImportIsAtomicAndDoesNotConnect() throws {
        let storage = store(); defer { try? FileManager.default.removeItem(at: storage.file.deletingLastPathComponent()) }
        let failing = RejectingStore(storage)
        let model = AppModel(profileStore: failing, arguments: [])
        XCTAssertTrue(model.save(showNotice: false)); let original = try Data(contentsOf: storage.file)
        var policy = RoutingPolicy(); policy.defaultAction = .direct
        failing.reject = true
        XCTAssertFalse(model.replaceRouting(policy)); XCTAssertEqual(model.routing.defaultAction, .vpn)
        XCTAssertEqual(try Data(contentsOf: storage.file), original)
        failing.reject = false
        XCTAssertTrue(model.replaceRouting(policy)); XCTAssertEqual(model.connection.state, .idle)
        XCTAssertFalse(model.connection.hasSession)
    }
    func testActiveRoutingIsAnImmutableSnapshotAndReconnectAppliesChanges() async throws {
        let storage = store(); defer { try? FileManager.default.removeItem(at: storage.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: storage, arguments: [])
        model.connection.prepareDesignPreview(profile: model.draft.id)
        model.routing.defaultAction = .direct
        XCTAssertTrue(model.routingPending)
        XCTAssertEqual(model.connection.activeRouting?.defaultAction, .vpn)
        XCTAssertTrue(model.save(showNotice: false))
        model.applyRouting()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.connection.activeRouting?.defaultAction, .direct)
        XCTAssertFalse(model.routingPending)
    }
    func testInvalidDraftSurvivesRestartWithoutChangingActiveSnapshot() async throws {
        let storage = store(); defer { try? FileManager.default.removeItem(at: storage.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: storage, arguments: [])
        model.connection.prepareDesignPreview(profile: model.draft.id)
        model.routing.rules.append(RoutingRule())
        XCTAssertNotNil(model.routingError); XCTAssertFalse(model.canApplyRouting)
        XCTAssertTrue(model.save(showNotice: false))
        XCTAssertEqual(AppModel(profileStore: storage, arguments: []).routing.rules.count, 1)
        XCTAssertTrue(model.connection.activeRouting?.rules.isEmpty == true)
    }
    private final class RejectingStore: ProfileStorage {
        let wrapped: ProfileStore
        var reject = false
        init(_ wrapped: ProfileStore) { self.wrapped = wrapped }
        func load() throws -> ProfileStore.Document { try wrapped.load() }
        func save(_ document: ProfileStore.Document) throws {
            if reject { throw VPNError("Synthetic write failure") }; try wrapped.save(document)
        }
    }
}
