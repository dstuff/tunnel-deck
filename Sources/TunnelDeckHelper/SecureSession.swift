import TunnelLocalization
import Foundation
import Darwin
import TunnelCore

final class SecureSession {
    let request: TunnelRequest
    let redactor: LogRedactor
    private let events: Int32
    private let control: Int32
    private let lease: Int32
    private let journal: SessionEventLog.Writer
    private var shouldStop = false

    init(path: String, userID: UInt32) throws {
        guard getuid() == 0, userID > 0 else { throw VPNError(L10n.message("securesession.administrator_privileges_are_required_to_configure_the_vpn")) }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw VPNError(L10n.message("securesession.could_not_open_the_session")) }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == userID, info.st_mode & 0o077 == 0 else { throw VPNError(L10n.message("securesession.invalid_session_directory_permissions")) }
        func verified(_ name: String, flags: Int32, type: mode_t) throws -> Int32 {
            let fd = openat(directory, name, flags | O_NOFOLLOW)
            guard fd >= 0 else { throw VPNError(L10n.message("securesession.could_not_open_the_session_file")) }
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_uid == userID, s.st_mode & 0o077 == 0,
                  s.st_mode & S_IFMT == type, s.st_nlink == 1 else { close(fd); throw VPNError(L10n.message("securesession.invalid_session_file")) }
            return fd
        }
        let input = try verified("request.json", flags: O_RDONLY, type: S_IFREG)
        let handle = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        let data = try handle.read(upToCount: 512_001) ?? Data()
        guard data.count <= 512_000, let decoded = try? JSONDecoder().decode(TunnelRequest.self, from: data),
              decoded.userID == userID, decoded.parentPID > 1 else { throw VPNError(L10n.message("securesession.invalid_connection_request")) }
        request = decoded; redactor = LogRedactor(request: decoded)
        _ = try decoded.routing.validated()
        events = try verified("events.jsonl", flags: O_WRONLY | O_APPEND, type: S_IFREG)
        do { control = try verified("control", flags: O_RDWR | O_NONBLOCK, type: S_IFIFO) }
        catch { close(events); throw error }
        do { lease = try verified("lease", flags: O_RDONLY | O_CLOEXEC, type: S_IFREG) }
        catch { close(events); close(control); throw error }
        guard flock(lease, LOCK_SH | LOCK_NB) == 0 else {
            close(events); close(control); close(lease)
            throw VPNError(L10n.message("privatesession.could_not_retain_the_vpn_session_directory"))
        }
        do { journal = try SessionEventLog.Writer(fileDescriptor: events) }
        catch { close(events); close(control); close(lease); throw error }
        // Credentials are now in memory; do not leave the handoff file behind.
        _ = unlinkat(directory, "request.json", 0)
    }
    func emit(_ kind: TunnelEvent.Kind, _ message: String) {
        try? journal.append(TunnelEvent(kind, redactor.redact(message)))
    }
    func emit(_ kind: TunnelEvent.Kind, _ message: LocalizedMessage) {
        try? journal.append(TunnelEvent(kind, redactor.redact(message)))
    }
    func routingReady(_ info: RoutingRuntimeInfo) {
        try? journal.append(TunnelEvent(.routingReady, L10n.message("securesession.shared_routing_is_ready"), routing: info))
    }
    func stopping() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 128)
        if read(control, &buffer, buffer.count) > 0 { shouldStop = true }
        if kill(request.parentPID, 0) != 0 && errno == ESRCH { shouldStop = true }
        return shouldStop || helperInterrupted
    }
    deinit { close(events); close(control); close(lease) }
}

var helperInterrupted = false

final class OutputLines {
    private var pending = Data()
    private let lock = NSLock()
    let callback: (LocalizedMessage) -> Void
    init(_ callback: @escaping (LocalizedMessage) -> Void) { self.callback = callback }
    func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            if !line.isEmpty { callback(.verbatim(line)) }
        }
        if pending.count > 64_000 { pending.removeAll(); callback(L10n.message("securesession.a_long_log_line_was_hidden")) }
    }
    func finish() { receive(Data([10])) }
}
