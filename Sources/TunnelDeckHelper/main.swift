import Foundation
import Darwin
import TunnelCore

let args = CommandLine.arguments
guard args.count == 5, args[1] == "--session", args[3] == "--uid", let uid = UInt32(args[4]) else {
    fputs("TunnelDeckHelper --session <private-directory> --uid <uid>\n", stderr)
    exit(2)
}
do {
    let session = try SecureSession(path: args[2], userID: uid)
    do {
        let lockFile = open("/var/run/tunneldeck.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFile >= 0 else { throw VPNError("Не удалось заблокировать VPN-сеанс.") }
        defer { close(lockFile) }
        guard flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { throw VPNError("Другое подключение TunnelDeck уже работает.") }
        signal(SIGINT) { _ in helperInterrupted = true }
        signal(SIGTERM) { _ in helperInterrupted = true }
        signal(SIGPIPE, SIG_IGN)
        let executable = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let runtime = RuntimePaths(root: contents.appendingPathComponent("Resources/Runtime"))
        session.emit(.configuring, "Запускаем \(session.request.profile.kind.title)…")
        let runner = try BackendRunner(session: session, runtime: runtime)
        try runner.run()
        session.emit(.stopped, "Подключение завершено, сетевые настройки восстановлены.")
    } catch {
        session.emit(.error, error.localizedDescription)
        session.emit(.stopped, "Сеанс завершён.")
        exit(1)
    }
} catch {
    fputs("Не удалось открыть защищённый запрос VPN.\n", stderr)
    exit(1)
}
