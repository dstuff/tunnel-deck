import TunnelLocalization
import Foundation
import Observation
import Darwin
import TunnelCore

@MainActor @Observable final class ConnectionController {
    private(set) var state: ConnectionState = .idle
    private(set) var logs: [LogEntry] = []
    private var errorMessageContent: LocalizedMessage?
    var errorMessage: String? { errorMessageContent?.resolve() }
    private(set) var connectedAt: Date?
    private(set) var activeProfile: UUID?
    private(set) var statusProfile: UUID?
    private var checkResultContent: LocalizedMessage?
    var checkResult: String? { checkResultContent?.resolve() }
    private(set) var activeRouting: RoutingPolicy?
    private(set) var routingRuntime: RoutingRuntimeInfo?
    private let process = ProcessRunner()
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var privateSession: PrivateSession?
    private var redactor = LogRedactor()
    private var kind = VPNProtocol.openConnect
    private var receivedConnected = false
    private var trafficCheck: Task<Void, Never>?
    #if DEBUG
    private var isDesignPreview = false

    func prepareDesignPreview(profile: UUID, routing: RoutingPolicy = .init()) {
        isDesignPreview = true
        activeProfile = profile; statusProfile = profile; state = .connected
        connectedAt = Date().addingTimeInterval(-1458)
        activeRouting = routing
    }
    #endif
    var runtime: RuntimePaths { RuntimePaths(root: Bundle.main.resourceURL!.appendingPathComponent("Runtime")) }
    var hasSession: Bool { privateSession != nil }
    var locked: Bool { operation != nil || state.busy || hasSession || state == .connected }

    func state(for profileID: UUID) -> ConnectionState {
        statusProfile == profileID ? state : .idle
    }

    func append(_ message: String) {
        append(.verbatim(message))
    }
    func append(_ message: LocalizedMessage, date: Date = Date()) {
        logs.append(LogEntry(redactor.redact(message), date: date))
        if logs.count > 1200 { logs.removeFirst(logs.count - 1200) }
    }
    func clearLog() { logs.removeAll() }
    func resetProfileResult() {
        guard !locked else { return }
        checkResultContent = nil; errorMessageContent = nil; state = .idle; statusProfile = nil
    }
    var exportedLog: String { logs.map { "\($0.date.formatted(date: .omitted, time: .standard))  \($0.message)" }.joined(separator: "\n") }
    private func configureRedaction(profile: VPNProfile, secrets: ProfileSecrets, cookie: String = "") {
        redactor = LogRedactor(request: TunnelRequest(userID: getuid(), parentPID: getpid(), profile: profile, secrets: secrets, cookie: cookie))
    }

    func check(profile: VPNProfile, secrets: ProfileSecrets) {
        guard !locked else { return }
        #if DEBUG
        if isDesignPreview {
            statusProfile = profile.id
            checkResultContent = L10n.message("connectioncontroller.interface_preview_no_network_checks_were_performed")
            return
        }
        #endif
        statusProfile = profile.id
        state = .checking; errorMessageContent = nil; checkResultContent = nil
        configureRedaction(profile: profile, secrets: secrets)
        operation = Task {
            defer { operation = nil }
            do {
                try runtime.check(profile.kind)
                switch profile.kind {
                case .openConnect:
                    _ = try OpenConnectConfiguration.make(profile: profile, secrets: secrets)
                    let endpoint = try VPNEndpoint(server: profile.server, camouflage: secrets.camouflage)
                    var request = URLRequest(url: URL(string: endpoint.url)!)
                    request.timeoutInterval = 15; request.cachePolicy = .reloadIgnoringLocalCacheData
                    let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]
                    let client = URLSession(configuration: config); defer { client.invalidateAndCancel() }
                    let (data, response) = try await client.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw VPNError(L10n.message("connectioncontroller.the_server_did_not_return_an_http_response")) }
                    if [401, 404].contains(http.statusCode) { throw VPNError(L10n.message("connectioncontroller.http_the_server_rejected_the_request_check_the_camouflage", [.init(http.statusCode)])) }
                    guard http.statusCode == 200 else { throw VPNError(L10n.message("connectioncontroller.the_server_returned_http", [.init(http.statusCode)])) }
                    let body = String(decoding: data.prefix(64_000), as: UTF8.self)
                    guard body.contains("config-auth") || body.contains("<auth") || body.localizedCaseInsensitiveContains("AnyConnect") else {
                        throw VPNError(L10n.message("connectioncontroller.tls_and_http_work_but_the_response_does_not"))
                    }
                    checkResultContent = L10n.message("connectioncontroller.the_certificate_is_valid_the_ocserv_server_returned_a")
                case .amneziaWG:
                    let config = try AmneziaConfiguration(secrets.configuration)
                    checkResultContent = L10n.message("connectioncontroller.the_awg_3_1_configuration_was_read_addresses_servers", [
                        .init(L10n.message("awg.address_count", [.init(config.addresses.count)])),
                        .init(L10n.message("awg.server_count", [.init(config.endpointHosts.count)]))])
                case .xray:
                    let config = try XrayConfiguration(secrets.configuration)
                    let session = try PrivateSession(); defer { session.remove() }
                    let file = session.directory.appendingPathComponent("xray-check.json")
                    try PrivateSession.write(config.selectedProbeData(port: 1, selected: profile.xrayOutboundTag), to: file)
                    let output = try await process.run(runtime.xray, ["run", "-test", "-config", file.path])
                    guard output.status == 0 else { throw VPNError(redactor.redact(output.stderr + output.stdout)) }
                    append(L10n.message("connectioncontroller.xray_accepted_the_configuration_checking_https_through_the_server"))
                    let logRedactor = redactor
                    try await XrayProbe.check(configuration: config, runtime: runtime, selectedOutbound: profile.xrayOutboundTag) { [weak self] line in
                        let safe = logRedactor.redact(line)
                        Task { @MainActor in self?.append(safe) }
                    }
                    checkResultContent = L10n.message("connectioncontroller.xray_https_through_the_server_works_the_system_tunnel")
                }
                try Task.checkCancellation()
                append(checkResultContent ?? L10n.message("connectioncontroller.check_complete")); state = .idle
            } catch {
                if Task.isCancelled { state = .idle } else { fail(error) }
            }
        }
    }

    func connect(profile: VPNProfile, secrets: ProfileSecrets, routing: RoutingPolicy = .init()) {
        guard !locked else { return }
        #if DEBUG
        if isDesignPreview {
            prepareDesignPreview(profile: profile.id, routing: routing)
            return
        }
        #endif
        activeProfile = profile.id; statusProfile = profile.id; kind = profile.kind; receivedConnected = false
        errorMessageContent = nil; checkResultContent = nil; connectedAt = nil
        activeRouting = nil; routingRuntime = nil
        configureRedaction(profile: profile, secrets: secrets)
        state = profile.kind == .openConnect ? .authorizing : .checking
        operation = Task {
            defer { operation = nil }
            do {
                try runtime.check(profile.kind)
                try runtime.checkRouting()
                let policy = try routing.validated()
                var request = TunnelRequest(userID: getuid(), parentPID: getpid(), profile: profile, secrets: secrets, routing: policy)
                switch profile.kind {
                case .openConnect:
                    guard !secrets.password.isEmpty else { throw VPNError(L10n.message("connectioncontroller.enter_the_vpn_user_password")) }
                    let session = try PrivateSession(); defer { session.remove() }
                    let config = try OpenConnectConfiguration.make(profile: profile, secrets: secrets)
                    let file = session.directory.appendingPathComponent("auth.conf")
                    try PrivateSession.write(Data(config.utf8), to: file)
                    append(L10n.message("connectioncontroller.openconnect_sending_the_initial_url_with_camouflage_certificate_verification"))
                    let logRedactor = redactor
                    let output = try await process.run(runtime.openconnect!, ["--config", file.path, "--cookieonly", "--passwd-on-stdin"], input: secrets.password) { [weak self] line in
                        let safe = logRedactor.redact(line)
                        Task { @MainActor in self?.append(safe) }
                    }
                    guard output.status == 0 else { throw VPNError(L10n.message("connectioncontroller.openconnect_authentication_failed_check_the_log_username_and_password")) }
                    let cookies = output.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    guard cookies.count == 1, cookies[0].utf8.count <= 64_000 else { throw VPNError(L10n.message("connectioncontroller.openconnect_did_not_return_an_authentication_cookie")) }
                    request.cookie = cookies[0]; request.secrets.password = ""
                    configureRedaction(profile: profile, secrets: secrets, cookie: request.cookie)
                    append(L10n.message("connectioncontroller.authentication_succeeded_configuring_the_vpn"))
                case .amneziaWG: _ = try AmneziaConfiguration(secrets.configuration)
                case .xray: _ = try XrayConfiguration(secrets.configuration).selectedOutboundTag(profile.xrayOutboundTag)
                }
                try Task.checkCancellation()
                let session = try PrivateSession()
                try session.save(request); privateSession = session; activeRouting = policy
                startMonitoring(session)
                state = .permission
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TunnelDeckHelper").path
                guard FileManager.default.isExecutableFile(atPath: helper) else { throw VPNError(L10n.message("connectioncontroller.the_app_is_missing_the_network_configuration_helper")) }
                func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let command = quote(helper) + " --session " + quote(session.directory.path) + " --uid " + String(getuid()) + " >/dev/null 2>&1 &"
                let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let script = "do shell script \"\(escaped)\" with administrator privileges"
                let result = try await process.run("/usr/bin/osascript", ["-e", script], timeout: 180)
                guard result.status == 0 else { throw VPNError(L10n.message("connectioncontroller.macos_permission_to_configure_the_vpn_was_not_granted")) }
                if state == .permission { state = .configuring }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, self.state == .configuring || self.state == .permission else { return }
                    self.errorMessageContent = L10n.message("connectioncontroller.setup_is_still_in_progress_check_the_system_prompt")
                }
            } catch {
                if let privateSession { privateSession.stop() }
                if Task.isCancelled && privateSession == nil { state = .idle; activeProfile = nil }
                else { fail(error); if state == .failed { finishSession() } }
            }
        }
    }

    func disconnect() {
        #if DEBUG
        if isDesignPreview {
            state = .idle; activeProfile = nil; connectedAt = nil; activeRouting = nil; routingRuntime = nil
            return
        }
        #endif
        operation?.cancel(); process.cancel()
        if let privateSession { state = .disconnecting; privateSession.stop(); append(L10n.message("connectioncontroller.stopping_the_vpn_and_restoring_the_network")) }
        else { state = operation == nil ? .idle : .disconnecting; activeProfile = nil }
    }
    private func startMonitoring(_ session: PrivateSession) {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            guard let reader = try? SessionEventLog.Reader(file: session.eventFile) else { return }
            while !Task.isCancelled {
                for event in (try? reader.readAvailable()) ?? [] { self?.receive(event) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    private func receive(_ event: TunnelEvent) {
        let content = event.localizedMessage ?? .verbatim(event.message)
        append(content, date: event.timestamp)
        switch event.kind {
        case .log: break
        case .routingReady: routingRuntime = event.routing
        case .configuring: if state != .disconnecting { state = .configuring }
        case .networkReady:
            if state != .disconnecting { state = .waiting; verifyTraffic() }
        case .connected:
            receivedConnected = true
            if state != .disconnecting { state = .connected; connectedAt = Date(); verifyTraffic() }
        case .error: errorMessageContent = redactor.redact(content); state = .failed
        case .stopped:
            let failed = errorMessage != nil
            finishSession(); state = failed ? .failed : .idle
        }
    }
    func verifyTraffic() {
        guard trafficCheck == nil, let session = privateSession else { return }
        let sessionPath = session.directory
        trafficCheck = Task { @MainActor in
            defer { if privateSession?.directory == sessionPath { trafficCheck = nil } }
            do {
                guard let port = routingRuntime?.probePort else { throw VPNError(L10n.message("connectioncontroller.the_router_has_not_reported_its_diagnostic_port_yet")) }
                let result = try await ProcessRunner().run("/usr/bin/curl", ["--disable", "--silent", "--show-error", "--fail",
                    "--proxy", "socks5h://127.0.0.1:\(port)", "--noproxy", "", "--connect-timeout", "5", "--max-time", "15",
                    "--output", "/dev/null", "https://example.com/"])
                guard result.status == 0 else { throw VPNError(L10n.message("connectioncontroller.no_successful_https_response_was_received_through_the_vpn")) }
                let systemResult = try await ProcessRunner().run("/usr/bin/curl", ["--disable", "--silent", "--show-error", "--fail",
                    "--proxy", "", "--noproxy", "*", "--resolve", "example.com:443:\(RoutingConfiguration.systemProbeAddress)",
                    "--connect-timeout", "5", "--max-time", "15", "--output", "/dev/null", "https://example.com/"])
                guard systemResult.status == 0 else { throw VPNError(L10n.message("connectioncontroller.the_vpn_channel_is_available_but_https_transfer_through")) }
                guard !Task.isCancelled, privateSession?.directory == sessionPath,
                      state == .waiting || state == .connected else { return }
                append(L10n.message("connectioncontroller.data_check_https_passed_through_the_system_tun_and"))
                if kind == .xray && state == .waiting { state = .connected; connectedAt = Date(); receivedConnected = true }
            } catch {
                if !Task.isCancelled, privateSession?.directory == sessionPath,
                   state == .waiting || state == .connected {
                    append(L10n.message("connectioncontroller.data_check_https_example_com_is_unavailable", [.init(error.localizedMessage)]))
                    if kind == .xray && state == .waiting {
                        errorMessageContent = L10n.message("connectioncontroller.data_transfer_through_xray_has_not_been_confirmed_the")
                        state = .failed
                        session.stop()
                    }
                }
            }
        }
    }
    private func finishSession() {
        trafficCheck?.cancel(); trafficCheck = nil
        monitor?.cancel(); monitor = nil
        privateSession?.remove(); privateSession = nil
        activeProfile = nil; connectedAt = nil
        activeRouting = nil; routingRuntime = nil
    }
    private func fail(_ error: Error) {
        let message = redactor.redact(error.localizedMessage)
        errorMessageContent = message; state = .failed; append(message)
    }
}
