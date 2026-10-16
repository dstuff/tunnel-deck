import Foundation
import Darwin

/// A bounded event stream shared by the helper and UI through one verified file.
public enum SessionEventLog {
    public static let maximumBytes = 5_000_000
    private static let headerSize = Data("{\"generation\":\"00000000-0000-0000-0000-000000000000\"}\n".utf8).count

    private struct Record: Codable {
        let sequence: UInt64
        let event: TunnelEvent
    }

    private struct SavedRecord {
        let sequence: UInt64
        let bytes: Data
    }

    private static func ioError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    public final class Writer {
        // The caller owns this descriptor and verifies its owner, type and links.
        private let descriptor: Int32
        private let limit: Int
        private let recordLimit: Int
        private let lock = NSLock()
        private var byteCount = 0
        private var sequence: UInt64 = 0
        private var states: [String: SavedRecord] = [:]
        private var needsRotation = false

        public init(fileDescriptor: Int32, maximumBytes: Int = SessionEventLog.maximumBytes) throws {
            guard maximumBytes >= 4096 else { throw VPNError("Недопустимый размер журнала.") }
            descriptor = fileDescriptor
            limit = maximumBytes
            // Six state kinds, one new record and a header always fit together.
            recordLimit = min(64_000, (maximumBytes - SessionEventLog.headerSize) / 8)
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_APPEND) == 0 else {
                throw SessionEventLog.ioError()
            }
            guard flock(descriptor, LOCK_EX) == 0 else { throw SessionEventLog.ioError() }
            defer { flock(descriptor, LOCK_UN) }
            try rotate()
        }

        public func append(_ event: TunnelEvent) throws {
            lock.lock(); defer { lock.unlock() }
            guard flock(descriptor, LOCK_EX) == 0 else { throw SessionEventLog.ioError() }
            defer { flock(descriptor, LOCK_UN) }

            var bounded = event
            if bounded.message.utf8.count > recordLimit {
                bounded.message = String(decoding: bounded.message.utf8.prefix(recordLimit), as: UTF8.self)
            }
            let next = sequence + 1
            var bytes = try JSONEncoder().encode(Record(sequence: next, event: bounded))
            // JSON escaping also counts toward the byte limit, including for a
            // single unusually long engine line. Redaction happens before here.
            while bytes.count + 1 > recordLimit {
                bounded.message = String(bounded.message.prefix(bounded.message.count / 2))
                bytes = try JSONEncoder().encode(Record(sequence: next, event: bounded))
            }
            bytes.append(10)
            do {
                if needsRotation || byteCount + bytes.count > limit { try rotate() }
                try write(bytes)
                sequence = next
                if event.kind != .log {
                    states[event.kind.rawValue] = SavedRecord(sequence: next, bytes: bytes)
                }
            } catch {
                // Do not append another JSON record after an incomplete write.
                needsRotation = true
                throw error
            }
        }

        private func rotate() throws {
            guard ftruncate(descriptor, 0) == 0 else { throw SessionEventLog.ioError() }
            byteCount = 0
            try write(Data("{\"generation\":\"\(UUID().uuidString)\"}\n".utf8))
            // Retain the latest event of every state kind, even if the UI has
            // not read it yet. Diagnostic noise cannot erase readiness or stop.
            for record in states.values.sorted(by: { $0.sequence < $1.sequence }) {
                try write(record.bytes)
            }
            needsRotation = false
        }

        private func write(_ bytes: Data) throws {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw SessionEventLog.ioError() }
                    offset += count
                    byteCount += count
                }
            }
        }
    }

    public final class Reader {
        private let handle: FileHandle
        private var generation = Data()
        private var offset: UInt64 = 0
        private var sequence: UInt64 = 0
        private var pending = Data()

        public init(file: URL) throws { handle = try FileHandle(forReadingFrom: file) }

        public func readAvailable() throws -> [TunnelEvent] {
            // Poll again if the helper is writing; never block the UI on its lock.
            guard flock(handle.fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EINTR { return [] }
                throw SessionEventLog.ioError()
            }
            defer { flock(handle.fileDescriptor, LOCK_UN) }
            try handle.seek(toOffset: 0)
            let header = try handle.read(upToCount: SessionEventLog.headerSize) ?? Data()
            guard header.count == SessionEventLog.headerSize else { return [] }
            if header != generation {
                generation = header
                offset = UInt64(SessionEventLog.headerSize)
                pending.removeAll(keepingCapacity: true)
            }
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: 128_000) ?? Data()
            offset += UInt64(bytes.count)
            pending.append(bytes)
            var events: [TunnelEvent] = []
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[..<end])
                pending.removeSubrange(...end)
                if let record = try? JSONDecoder().decode(Record.self, from: line), record.sequence > sequence {
                    sequence = record.sequence
                    events.append(record.event)
                }
            }
            return events
        }

        deinit { try? handle.close() }
    }
}
