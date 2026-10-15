import XCTest
import AppKit
import TunnelCore
@testable import TunnelDeck

@MainActor final class ConnectionStatusTests: XCTestCase {
    func testCheckAndFailureOnlyAffectTheirProfile() async throws {
        let controller = ConnectionController()
        let profile = VPNProfile(kind: .amneziaWG)
        let other = VPNProfile(kind: .xray)
        controller.check(profile: profile, secrets: ProfileSecrets())
        XCTAssertEqual(controller.state(for: profile.id), .checking)
        XCTAssertEqual(controller.state(for: other.id), .idle)
        // An empty AWG configuration fails before touching any network settings.
        for _ in 0..<100 {
            if controller.state == .failed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.state(for: profile.id), .failed)
        XCTAssertEqual(controller.state(for: other.id), .idle)
        controller.resetProfileResult()
        XCTAssertEqual(controller.state(for: profile.id), .idle)
    }

    func testConnectionStartsWithProfileSpecificStatusAndChainIcon() async {
        let controller = ConnectionController()
        let profile = VPNProfile()
        controller.connect(profile: profile, secrets: ProfileSecrets())
        XCTAssertEqual(controller.state(for: profile.id), .authorizing)
        XCTAssertEqual(controller.state(for: UUID()), .idle)
        controller.disconnect()
        XCTAssertEqual(controller.state(for: profile.id), .idle)
        XCTAssertEqual(ConnectionState.idle.menuBarSymbol, "link")
        XCTAssertEqual(ConnectionState.connected.menuBarSymbol, "link.circle.fill")
        XCTAssertEqual(ConnectionState.authorizing.menuBarSymbol, "link.circle")
    }

    func testMenuBarSymbolsExistOnThisMac() async {
        for state in [ConnectionState.idle, .authorizing, .connected] {
            XCTAssertNotNil(NSImage(systemSymbolName: state.menuBarSymbol, accessibilityDescription: nil))
        }
    }
}
