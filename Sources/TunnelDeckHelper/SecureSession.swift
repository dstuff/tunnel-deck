import Foundation
import Darwin
import TunnelCore

final class SecureSession {
    let request: TunnelRequest
    let redactor: LogRedactor
    private let events: Int32
    private let control: Int32
    private let lock = NSLock()
    private var shouldStop = false

    init(path: String, userID: UInt32) throws {
        guard getuid() == 0, userID > 0 else { throw VPNError("Для настройки VPN нужны права администратора.") }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw VPNError("Не удалось открыть сеанс.") }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == userID, info.st_mode & 0o077 == 0 else { throw VPNError("Недопустимые права каталога сеанса.") }
        func verified(_ name: String, flags: Int32, type: mode_t) throws -> Int32 {
            let fd = openat(directory, name, flags | O_NOFOLLOW)
            guard fd >= 0 else { throw VPNError("Не удалось открыть файл сеанса.") }
            var s = stat()
            guard fstat(fd, &s) == 0, s.st_uid == userID, s.st_mode & 0o077 == 0,
                  s.st_mode & S_IFMT == type, s.st_nlink == 1 else { close(fd); throw VPNError("Недопустимый файл сеанса.") }
            return fd
        }
        let input = try verified("request.json", flags: O_RDONLY, type: S_IFREG)
        let handle = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        let data = try handle.read(upToCount: 512_001) ?? Data()
        guard data.count <= 512_000, let decoded = try? JSONDecoder().decode(TunnelRequest.self, from: data),
              decoded.userID == userID, decoded.parentPID > 1 else { throw VPNError("Некорректный запрос подключения.") }
        request = decoded; redactor = LogRedactor(request: decoded)
        events = try verified("events.jsonl", flags: O_WRONLY | O_APPEND, type: S_IFREG)
        do { control = try verified("control", flags: O_RDWR | O_NONBLOCK, type: S_IFIFO) }
        catch { close(events); throw error }
        // Credentials are now in memory; do not leave the handoff file behind.
        _ = unlinkat(directory, "request.json", 0)
    }
    func emit(_ kind: TunnelEvent.Kind, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard var bytes = try? JSONEncoder().encode(TunnelEvent(kind, redactor.redact(message))) else { return }
        bytes.append(10)
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(events, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }; offset += n
            }
        }
    }
    func stopping() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 128)
        if read(control, &buffer, buffer.count) > 0 { shouldStop = true }
        if kill(request.parentPID, 0) != 0 && errno == ESRCH { shouldStop = true }
        return shouldStop || helperInterrupted
    }
    deinit { close(events); close(control) }
}

var helperInterrupted = false

final class OutputLines {
    private var pending = Data()
    private let lock = NSLock()
    let callback: (String) -> Void
    init(_ callback: @escaping (String) -> Void) { self.callback = callback }
    func receive(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            if !line.isEmpty { callback(line) }
        }
        if pending.count > 64_000 { pending.removeAll(); callback("Длинная строка журнала скрыта.") }
    }
    func finish() { receive(Data([10])) }
}
