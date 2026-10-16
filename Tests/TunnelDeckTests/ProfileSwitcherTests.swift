import XCTest
@testable import TunnelDeck

@MainActor final class ProfileSwitcherTests: XCTestCase {
    func testSwitchWaitsForCleanupEvenIfStatusAlreadyIdle() async throws {
        let connection = FakeConnectionLifecycle()
        let switcher = ProfileSwitcher(connection: connection)
        let target = UUID()
        var starts = 0
        switcher.start(to: target) { starts += 1 }
        XCTAssertEqual(connection.disconnects, 1)
        XCTAssertEqual(switcher.targetProfile, target)
        connection.state = .idle
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(starts, 0, "Idle status alone must not allow overlapping helpers")
        connection.cleanupPending = false
        try await waitUntil { !switcher.isSwitching }
        XCTAssertEqual(starts, 1)
        XCTAssertNil(switcher.errorMessage)
    }

    func testCancelPreventsQueuedConnection() async throws {
        let connection = FakeConnectionLifecycle()
        let switcher = ProfileSwitcher(connection: connection)
        var starts = 0
        switcher.start(to: UUID()) { starts += 1 }
        switcher.cancel()
        connection.state = .idle
        connection.cleanupPending = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(switcher.isSwitching)
        XCTAssertEqual(starts, 0)
    }

    func testFailedCleanupAndTimeoutNeverStartNextTunnel() async throws {
        let connection = FakeConnectionLifecycle()
        let switcher = ProfileSwitcher(connection: connection, timeout: .milliseconds(150))
        var starts = 0
        switcher.start(to: UUID()) { starts += 1 }
        try await waitUntil { !switcher.isSwitching }
        XCTAssertNotNil(switcher.errorMessage)
        XCTAssertEqual(starts, 0)

        connection.state = .connected
        switcher.start(to: UUID()) { starts += 1 }
        connection.state = .failed
        connection.cleanupPending = false
        try await waitUntil { !switcher.isSwitching }
        XCTAssertNotNil(switcher.errorMessage)
        XCTAssertEqual(starts, 0)
    }

    func testRepeatedSwitchKeepsOriginalTargetAndCancelCannotEraseNewOperation() async throws {
        let connection = FakeConnectionLifecycle()
        let switcher = ProfileSwitcher(connection: connection)
        let first = UUID()
        let second = UUID()
        var starts: [UUID] = []
        switcher.start(to: first) { starts.append(first) }
        switcher.start(to: second) { starts.append(second) }
        XCTAssertEqual(switcher.targetProfile, first)
        XCTAssertEqual(connection.disconnects, 1)
        switcher.cancel()
        connection.state = .connected
        switcher.start(to: second) { starts.append(second) }
        connection.state = .idle
        connection.cleanupPending = false
        try await waitUntil { !switcher.isSwitching }
        XCTAssertEqual(starts, [second])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for profile switch")
    }
}

@MainActor private final class FakeConnectionLifecycle: ConnectionLifecycle {
    var state: ConnectionState = .connected
    var cleanupPending = true
    var disconnects = 0
    var locked: Bool { cleanupPending || state.busy || state == .connected }
    func disconnect() { disconnects += 1; state = .disconnecting }
}
