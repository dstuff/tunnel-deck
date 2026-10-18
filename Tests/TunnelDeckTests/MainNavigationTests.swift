import XCTest
import TunnelCore
@testable import TunnelDeck

@MainActor final class MainNavigationTests: XCTestCase {
    func testFailedSaveBlocksBackAndCommandsWithoutLosingDraft() throws {
        let storage = RejectingStore()
        defer { try? FileManager.default.removeItem(at: storage.wrapped.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: storage, arguments: [])
        let navigation = MainNavigation(model: model)
        navigation.open(.settings)
        navigation.open(.routing)
        model.routing.name = "Unsaved synthetic policy"
        storage.reject = true

        XCTAssertFalse(navigation.goBack())
        XCTAssertEqual(navigation.destination, .routing)
        XCTAssertNotNil(model.persistenceError)
        XCTAssertFalse(navigation.open(.settings))
        XCTAssertFalse(navigation.open(.connections))
        XCTAssertEqual(model.routing.name, "Unsaved synthetic policy")
        XCTAssertFalse(model.connection.hasSession)

        storage.reject = false
        XCTAssertTrue(navigation.goBack())
        XCTAssertEqual(navigation.destination, .settings)
        XCTAssertEqual(try storage.load()?.routing.name, "Unsaved synthetic policy")
    }

    func testResizeAndRepeatedNavigationPreserveRuleAndActiveRouting() {
        let storage = RejectingStore()
        defer { try? FileManager.default.removeItem(at: storage.wrapped.file.deletingLastPathComponent()) }
        let model = AppModel(profileStore: storage, arguments: [])
        model.connection.prepareDesignPreview(profile: model.draft.id)
        let active = model.connection.activeRouting
        let rule = RoutingRule(match: .init(type: .domainSuffix, value: "example.org"), action: .direct)
        model.routing.rules = [rule]
        let navigation = MainNavigation(model: model)
        navigation.open(.routing)
        navigation.selectedRuleID = rule.id
        navigation.compactRuleEditor = true

        for width: CGFloat in [520, 1100, 780, 900, 899, 520] {
            navigation.updateWidth(width)
            navigation.open(.routing)
            XCTAssertEqual(navigation.selectedRuleID, rule.id)
            XCTAssertEqual(model.routing.rules, [rule])
            XCTAssertEqual(model.connection.activeRouting, active)
            XCTAssertEqual(model.connection.state, .connected)
        }
        XCTAssertTrue(navigation.showingRuleEditor)
        XCTAssertTrue(navigation.goBack())
        XCTAssertFalse(navigation.showingRuleEditor)
        XCTAssertEqual(navigation.destination, .routing)
        XCTAssertTrue(navigation.goBack())
        XCTAssertEqual(navigation.destination, .connections)
    }

    private final class RejectingStore: ProfileStorage {
        let wrapped = ProfileStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("MainNavigationTests-\(UUID().uuidString)/profiles.json"))
        var reject = false
        func load() throws -> ProfileStore.Document? { try wrapped.load() }
        func save(_ document: ProfileStore.Document) throws {
            if reject { throw VPNError("Synthetic write failure") }
            try wrapped.save(document)
        }
    }
}
