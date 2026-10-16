import XCTest
import Darwin
@testable import TunnelCore

final class SessionEventLogTests: XCTestCase {
    private func withFile(_ body: (URL, FileHandle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tunneldeck-log-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        try PrivateSession.write(Data(), to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try body(file, handle)
    }

    private func drain(_ reader: SessionEventLog.Reader) throws -> [TunnelEvent] {
        var events: [TunnelEvent] = []
        // More than enough polls to consume the entire bounded file, including
        // polls containing only state records already seen before rotation.
        for _ in 0..<64 { events += try reader.readAvailable() }
        return events
    }

    func testDefaultLimitSurvivesFloodAndKeepsUnreadLifecycleEvents() throws {
        try withFile { file, handle in
            let writer = try SessionEventLog.Writer(fileDescriptor: handle.fileDescriptor)
            let reader = try SessionEventLog.Reader(file: file)
            try writer.append(TunnelEvent(.networkReady, "Сеть готова"))
            for index in 0..<2000 {
                try writer.append(TunnelEvent(.log, "\(index):" + String(repeating: "x", count: 4096)))
                if index.isMultiple(of: 100) {
                    XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, SessionEventLog.maximumBytes)
                }
            }
            try writer.append(TunnelEvent(.error, "Тестовая ошибка"))
            try writer.append(TunnelEvent(.stopped, "Сеанс завершён"))
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 5_000_000)
            let events = try drain(reader)
            XCTAssertEqual(events.filter { $0.kind != .log }.map(\.kind), [.networkReady, .error, .stopped])
            XCTAssertTrue(events.contains { $0.message.hasPrefix("1999:") })
            XCTAssertFalse(events.contains { $0.message.hasPrefix("0:") })
        }
    }

    func testReaderDetectsRepeatedRotationWithoutReplayingStates() throws {
        try withFile { file, handle in
            let writer = try SessionEventLog.Writer(fileDescriptor: handle.fileDescriptor, maximumBytes: 4096)
            let reader = try SessionEventLog.Reader(file: file)
            try writer.append(TunnelEvent(.networkReady, "ready"))
            XCTAssertEqual(try reader.readAvailable().map(\.kind), [.networkReady])
            for index in 0..<500 {
                try writer.append(TunnelEvent(.log, "\(index)" + String(repeating: "z", count: 200)))
            }
            try writer.append(TunnelEvent(.connected, "connected"))
            try writer.append(TunnelEvent(.stopped, "stopped"))
            // The rotated file has already grown past the old reader position.
            XCTAssertGreaterThan(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 500)
            let events = try drain(reader)
            XCTAssertEqual(events.filter { $0.kind != .log }.map(\.kind), [.connected, .stopped])
            XCTAssertTrue(try reader.readAvailable().isEmpty)
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 4096)
        }
    }

    func testHugeEscapedUnicodeMessagesCannotExceedFileLimit() throws {
        try withFile { file, handle in
            let writer = try SessionEventLog.Writer(fileDescriptor: handle.fileDescriptor, maximumBytes: 4096)
            let reader = try SessionEventLog.Reader(file: file)
            let huge = String(repeating: "🧭\u{0}\n\"", count: 20_000)
            for kind in [TunnelEvent.Kind.configuring, .networkReady, .connected, .error, .stopped] {
                try writer.append(TunnelEvent(kind, huge))
            }
            for _ in 0..<20 { try writer.append(TunnelEvent(.log, huge)) }
            let events = try drain(reader)
            XCTAssertEqual(events.filter { $0.kind != .log }.map(\.kind), [.configuring, .networkReady, .connected, .error, .stopped])
            XCTAssertFalse(events.last!.message.isEmpty)
            XCTAssertLessThan(events.last!.message.utf8.count, huge.utf8.count)
            XCTAssertLessThanOrEqual(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!, 4096)
        }
    }

    func testReaderHandlesChunkBoundariesAndDoesNotBlockOnWriterLock() throws {
        try withFile { file, handle in
            let reader = try SessionEventLog.Reader(file: file)
            XCTAssertTrue(try reader.readAvailable().isEmpty)
            let writer = try SessionEventLog.Writer(fileDescriptor: handle.fileDescriptor)
            let messages = (0..<40).map { "\($0):" + String(repeating: "ж", count: 4000) }
            for message in messages { try writer.append(TunnelEvent(.log, message)) }
            XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertTrue(try reader.readAvailable().isEmpty)
            XCTAssertEqual(flock(handle.fileDescriptor, LOCK_UN), 0)
            XCTAssertEqual(try drain(reader).map(\.message), messages)
        }
    }

    func testConcurrentEngineOutputProducesCompleteOrderedRecords() throws {
        try withFile { file, handle in
            let writer = try SessionEventLog.Writer(fileDescriptor: handle.fileDescriptor)
            DispatchQueue.concurrentPerform(iterations: 400) { index in
                do { try writer.append(TunnelEvent(.log, "record-\(index)")) }
                catch { XCTFail("Concurrent append failed: \(error)") }
            }
            let reader = try SessionEventLog.Reader(file: file)
            let events = try drain(reader)
            XCTAssertEqual(events.count, 400)
            XCTAssertEqual(Set(events.map(\.message)).count, 400)
        }
    }
}
