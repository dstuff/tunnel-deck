import TunnelLocalization
import Foundation
import Darwin
import TunnelCore

let args = CommandLine.arguments
if args.count == 3, args[1] == "--openconnect-network" {
    do { try writeOpenConnectNetworkEvent(directory: args[2]); exit(0) }
    catch { fputs(L10n.text("main.openconnect_invalid_network_event_n"), stderr); exit(1) }
}
guard args.count == 5, args[1] == "--session", args[3] == "--uid", let uid = UInt32(args[4]) else {
    fputs("TunnelDeckHelper --session <private-directory> --uid <uid>\n", stderr)
    exit(2)
}
do {
    let session = try SecureSession(path: args[2], userID: uid)
    do {
        let lockFile = open("/var/run/tunneldeck.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFile >= 0 else { throw VPNError(L10n.message("main.could_not_lock_the_vpn_session")) }
        defer { close(lockFile) }
        guard flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { throw VPNError(L10n.message("main.another_tunneldeck_connection_is_already_running")) }
        signal(SIGINT) { _ in helperInterrupted = true }
        signal(SIGTERM) { _ in helperInterrupted = true }
        signal(SIGPIPE, SIG_IGN)
        let executable = URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let runtime = RuntimePaths(root: contents.appendingPathComponent("Resources/Runtime"))
        session.emit(.configuring, L10n.message("main.starting", [.init(session.request.profile.kind.title)]))
        let runner = try BackendRunner(session: session, runtime: runtime)
        try runner.run()
        session.emit(.stopped, L10n.message("main.the_connection_ended_and_network_settings_were_restored"))
    } catch {
        session.emit(.error, error.localizedMessage)
        session.emit(.stopped, L10n.message("main.the_session_ended"))
        exit(1)
    }
} catch {
    fputs(L10n.text("main.could_not_open_the_secure_vpn_request_n"), stderr)
    exit(1)
}
