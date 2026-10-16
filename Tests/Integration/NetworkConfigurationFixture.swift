// Compiled with the real helper network transaction; all commands are recorded,
// never executed. No root privileges, routes, DNS changes or VPN credentials.
import Foundation
import TunnelCore

final class SecureSession {
    func emit(_ kind: TunnelEvent.Kind, _ message: String) {}
}

struct Invocation: Equatable {
    let executable: String
    let arguments: [String]
}
var calls: [Invocation] = []
var baseline4 = ""
var baseline6 = ""
var existing: Set<String> = []
var failCapture = false

@discardableResult
func tool(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws -> String {
    calls.append(.init(executable: executable, arguments: arguments))
    if arguments.contains("get") { return arguments.contains("-inet6") ? baseline6 : baseline4 }
    if arguments.contains("add") {
        if failCapture && arguments.suffix(2) == ["-interface", "utun300"] { throw VPNError("Synthetic capture failure") }
        if existing.contains(arguments.joined(separator: " ")) { return "route: writing to routing socket: File exists" }
    }
    return ""
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw VPNError(message) }
}
func route(_ action: String, _ args: [String]) -> Invocation {
    .init(executable: "/sbin/route", arguments: ["-q", "-n", action] + args)
}
let capture4 = ["0.0.0.0/1", "128.0.0.0/1"]
let capture6 = ["::/1", "8000::/1"]
func physical(_ prefix: String, via: [String] = ["192.0.2.1"]) -> [String] {
    [prefix.contains(":") ? "-inet6" : "-inet", "-ifscope", "en0", "-net", prefix] + via
}
func capture(_ prefix: String) -> [String] {
    [prefix.contains(":") ? "-inet6" : "-inet", "-net", prefix, "-interface", "utun300"]
}
func configureCapture(_ network: NetworkConfiguration) throws {
    try network.configure(interface: "utun300", addresses: SocksTunnelConfiguration.addresses,
                          mtu: SocksTunnelConfiguration.mtu, allowedIPs: ["0.0.0.0/0", "::/0"], dns: [])
}
func reset(v6: String = "") {
    calls = []; existing = []; failCapture = false
    baseline4 = "gateway: 192.0.2.1\ninterface: en0\n"
    baseline6 = v6
}

func testPhysicalExitAndCleanup() throws {
    reset(v6: "gateway: fe80::1%en0\ninterface: en0\n")
    let network = try NetworkConfiguration(session: SecureSession())
    try network.configure(interface: "utun8", addresses: ["10.9.0.2/24"], mtu: 1376,
                          allowedIPs: ["0.0.0.0/0", "::/0"], dns: [], scoped: true)
    try expect(!calls.contains { $0.arguments.contains("add") && $0.arguments.contains("en0") }, "Native scoped routes must not install global capture bypasses")
    try configureCapture(network)
    for prefix in capture4 + capture6 {
        let direct = physical(prefix, via: prefix.contains(":") ? ["fe80::1%en0"] : ["192.0.2.1"])
        let directIndex = calls.firstIndex(of: route("add", direct))
        let captureIndex = calls.firstIndex(of: route("add", capture(prefix)))
        try expect(directIndex != nil && captureIndex != nil && directIndex! < captureIndex!, "Physical scoped route must precede capture: " + prefix)
    }
    let installed = calls.filter { $0.arguments.prefix(3) == ["-q", "-n", "add"] }
    network.restore()
    let removed = calls.filter { $0.arguments.prefix(3) == ["-q", "-n", "delete"] }
    try expect(removed == installed.reversed().map { route("delete", Array($0.arguments.dropFirst(3))) }, "Restore must delete only owned routes in reverse order")
    let count = removed.count
    network.restore()
    try expect(calls.filter { $0.arguments.contains("delete") }.count == count, "Restore must be idempotent")
}

func testDifferentIPv6InterfaceIsNotPhysicalExit() throws {
    reset(v6: "gateway: fe80::1%utun7\ninterface: utun7\n")
    let network = try NetworkConfiguration(session: SecureSession())
    try configureCapture(network)
    try expect(calls.contains(route("add", physical(capture4[0]))), "IPv4 direct exit missing")
    try expect(!calls.contains { $0.arguments.contains("-inet6") && $0.arguments.contains("en0") }, "Must not route physical IPv6 via another interface's gateway")
}

func testExistingPhysicalRouteSurvivesRestore() throws {
    reset()
    let kept = physical(capture4[0])
    existing = [route("add", kept).arguments.joined(separator: " ")]
    let network = try NetworkConfiguration(session: SecureSession())
    try configureCapture(network)
    network.restore()
    try expect(!calls.contains(route("delete", kept)), "A pre-existing route must not be deleted")
    try expect(calls.contains(route("delete", physical(capture4[1]))), "Owned physical route must be deleted")
}

func testPartialFailureRemovesPhysicalRoute() throws {
    reset(); failCapture = true
    let network = try NetworkConfiguration(session: SecureSession())
    do {
        try configureCapture(network)
        throw VPNError("Expected capture failure")
    } catch {
        try expect(error.localizedDescription.contains("Synthetic capture failure"), "Unexpected failure")
    }
    network.restore()
    try expect(calls.contains(route("delete", physical(capture4[0]))), "Partial failure must release the physical route")
    try expect(!calls.contains(route("delete", capture(capture4[0]))), "A failed capture route is not owned")
}

func testOnLinkDefaultUsesInterface() throws {
    reset(); baseline4 = "gateway: link#14\ninterface: en0\n"
    let network = try NetworkConfiguration(session: SecureSession())
    try configureCapture(network)
    try expect(calls.contains(route("add", physical(capture4[0], via: ["-interface", "en0"]))), "On-link default must retain its interface route")
}

try testPhysicalExitAndCleanup()
try testDifferentIPv6InterfaceIsNotPhysicalExit()
try testExistingPhysicalRouteSurvivesRestore()
try testPartialFailureRemovesPhysicalRoute()
try testOnLinkDefaultUsesInterface()
print("PASS network transaction: scoped physical exit before capture, IPv4/IPv6 baseline, existing routes, partial failure and cleanup")
