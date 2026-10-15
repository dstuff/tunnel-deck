import Foundation
import Observation
import Darwin
import TunnelCore

@MainActor @Observable final class ConnectionController {
    private(set) var state: ConnectionState = .idle
    private(set) var logs: [LogEntry] = []
    private(set) var errorMessage: String?
    private(set) var connectedAt: Date?
    private(set) var activeProfile: UUID?
    private(set) var statusProfile: UUID?
    private(set) var checkResult: String?
    private let process = ProcessRunner()
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var privateSession: PrivateSession?
    private var redactor = LogRedactor()
    private var kind = VPNProtocol.openConnect
    private var receivedConnected = false
    private var trafficCheck: Task<Void, Never>?
    var runtime: RuntimePaths { RuntimePaths(root: Bundle.main.resourceURL!.appendingPathComponent("Runtime")) }
    var hasSession: Bool { privateSession != nil }
    var locked: Bool { state.busy || hasSession || state == .connected }

    func state(for profileID: UUID) -> ConnectionState {
        statusProfile == profileID ? state : .idle
    }

    func append(_ message: String) {
        logs.append(LogEntry(redactor.redact(message)))
        if logs.count > 1200 { logs.removeFirst(logs.count - 1200) }
    }
    func clearLog() { logs.removeAll() }
    func resetProfileResult() {
        guard !locked else { return }
        checkResult = nil; errorMessage = nil; state = .idle; statusProfile = nil
    }
    var exportedLog: String { logs.map { "\($0.date.formatted(date: .omitted, time: .standard))  \($0.message)" }.joined(separator: "\n") }
    private func configureRedaction(profile: VPNProfile, secrets: ProfileSecrets, cookie: String = "") {
        redactor = LogRedactor(request: TunnelRequest(userID: getuid(), parentPID: getpid(), profile: profile, secrets: secrets, cookie: cookie))
    }

    func check(profile: VPNProfile, secrets: ProfileSecrets) {
        guard !locked else { return }
        statusProfile = profile.id
        state = .checking; errorMessage = nil; checkResult = nil
        configureRedaction(profile: profile, secrets: secrets)
        operation = Task {
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
                    guard let http = response as? HTTPURLResponse else { throw VPNError("Сервер не вернул HTTP-ответ.") }
                    if [401, 404].contains(http.statusCode) { throw VPNError("HTTP \(http.statusCode): сервер не пропустил запрос. Проверьте camouflage-секрет и путь URL.") }
                    guard http.statusCode == 200 else { throw VPNError("Сервер ответил HTTP \(http.statusCode).") }
                    let body = String(decoding: data.prefix(64_000), as: UTF8.self)
                    guard body.contains("config-auth") || body.contains("<auth") || body.localizedCaseInsensitiveContains("AnyConnect") else {
                        throw VPNError("TLS и HTTP работают, но ответ не похож на форму ocserv. Для проверки авторизации используйте «Подключить».")
                    }
                    checkResult = "Сертификат действителен. Сервер ocserv вернул форму входа."
                case .amneziaWG:
                    let config = try AmneziaConfiguration(secrets.configuration)
                    checkResult = "Конфигурация AWG 3.1 прочитана. Адресов: \(config.addresses.count), серверов: \(config.endpointHosts.count). Handshake проверяется при подключении."
                case .xray:
                    let config = try XrayConfiguration(secrets.configuration)
                    let session = try PrivateSession(); defer { session.remove() }
                    let file = session.directory.appendingPathComponent("xray-check.json")
                    try PrivateSession.write(config.data(), to: file)
                    let output = try await process.run(runtime.xray, ["run", "-test", "-config", file.path])
                    guard output.status == 0 else { throw VPNError(redactor.redact(output.stderr + output.stdout)) }
                    append("Xray принял конфигурацию. Проверяем HTTPS через сервер без изменения маршрутов…")
                    let logRedactor = redactor
                    try await XrayProbe.check(configuration: config, runtime: runtime) { [weak self] line in
                        let safe = logRedactor.redact(line)
                        Task { @MainActor in self?.append(safe) }
                    }
                    checkResult = "Xray: HTTPS через сервер работает. Системный туннель проверяется при подключении."
                }
                try Task.checkCancellation()
                append(checkResult ?? "Проверка завершена."); state = .idle
            } catch {
                if Task.isCancelled { state = .idle } else { fail(error) }
            }
        }
    }

    func connect(profile: VPNProfile, secrets: ProfileSecrets) {
        guard !locked else { return }
        activeProfile = profile.id; statusProfile = profile.id; kind = profile.kind; receivedConnected = false
        errorMessage = nil; checkResult = nil; connectedAt = nil
        configureRedaction(profile: profile, secrets: secrets)
        state = profile.kind == .openConnect ? .authorizing : .checking
        operation = Task {
            do {
                try runtime.check(profile.kind)
                var request = TunnelRequest(userID: getuid(), parentPID: getpid(), profile: profile, secrets: secrets)
                switch profile.kind {
                case .openConnect:
                    guard !secrets.password.isEmpty else { throw VPNError("Введите пароль VPN-пользователя.") }
                    let session = try PrivateSession(); defer { session.remove() }
                    let config = try OpenConnectConfiguration.make(profile: profile, secrets: secrets)
                    let file = session.directory.appendingPathComponent("auth.conf")
                    try PrivateSession.write(Data(config.utf8), to: file)
                    append("OpenConnect: отправляем начальный URL с camouflage, проверка сертификата включена.")
                    let logRedactor = redactor
                    let output = try await process.run(runtime.openconnect!, ["--config", file.path, "--cookieonly", "--passwd-on-stdin"], input: secrets.password) { [weak self] line in
                        let safe = logRedactor.redact(line)
                        Task { @MainActor in self?.append(safe) }
                    }
                    guard output.status == 0 else { throw VPNError("Авторизация OpenConnect не пройдена. Проверьте журнал, логин и пароль.") }
                    let cookies = output.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    guard cookies.count == 1, cookies[0].utf8.count <= 64_000 else { throw VPNError("OpenConnect не вернул cookie авторизации.") }
                    request.cookie = cookies[0]; request.secrets.password = ""
                    configureRedaction(profile: profile, secrets: secrets, cookie: request.cookie)
                    append("Авторизация успешна. Переходим к настройке VPN.")
                case .amneziaWG: _ = try AmneziaConfiguration(secrets.configuration)
                case .xray: _ = try XrayConfiguration(secrets.configuration)
                }
                try Task.checkCancellation()
                let session = try PrivateSession()
                try session.save(request); privateSession = session
                startMonitoring(session)
                state = .permission
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TunnelDeckHelper").path
                guard FileManager.default.isExecutableFile(atPath: helper) else { throw VPNError("В сборке отсутствует модуль настройки сети.") }
                func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let command = quote(helper) + " --session " + quote(session.directory.path) + " --uid " + String(getuid()) + " >/dev/null 2>&1 &"
                let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let script = "do shell script \"\(escaped)\" with administrator privileges"
                let result = try await process.run("/usr/bin/osascript", ["-e", script], timeout: 180)
                guard result.status == 0 else { throw VPNError("Разрешение macOS на настройку VPN не получено.") }
                if state == .permission { state = .configuring }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self, self.state == .configuring || self.state == .permission else { return }
                    self.errorMessage = "Настройка ещё не завершена. Проверьте системный запрос и журнал."
                }
            } catch {
                if let privateSession { privateSession.stop() }
                if Task.isCancelled && privateSession == nil { state = .idle; activeProfile = nil }
                else { fail(error); if state == .failed { finishSession() } }
            }
        }
    }

    func disconnect() {
        operation?.cancel(); process.cancel()
        if let privateSession { state = .disconnecting; privateSession.stop(); append("Завершаем VPN и восстанавливаем сеть…") }
        else { state = .idle; activeProfile = nil }
    }
    private func startMonitoring(_ session: PrivateSession) {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            guard let file = try? FileHandle(forReadingFrom: session.eventFile) else { return }
            defer { try? file.close() }
            var pending = Data()
            while !Task.isCancelled {
                if let data = try? file.read(upToCount: 128_000), !data.isEmpty { pending.append(data) }
                while let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end]); pending.removeSubrange(...end)
                    if let event = try? JSONDecoder().decode(TunnelEvent.self, from: line) { self?.receive(event) }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    private func receive(_ event: TunnelEvent) {
        append(event.message)
        switch event.kind {
        case .log: break
        case .configuring: if state != .disconnecting { state = .configuring }
        case .networkReady:
            if state != .disconnecting { state = .waiting; verifyTraffic() }
        case .connected:
            receivedConnected = true
            if state != .disconnecting { state = .connected; connectedAt = Date(); verifyTraffic() }
        case .error: errorMessage = redactor.redact(event.message); state = .failed
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
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 15; config.connectionProxyDictionary = [:]
                let client = URLSession(configuration: config); defer { client.invalidateAndCancel() }
                let (_, response) = try await client.data(from: URL(string: "https://example.com/")!)
                guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else { throw VPNError("Не получен успешный HTTPS-ответ.") }
                guard !Task.isCancelled, privateSession?.directory == sessionPath,
                      state == .waiting || state == .connected else { return }
                append("Проверка данных: HTTPS example.com доступен.")
                if kind == .xray && state == .waiting { state = .connected; connectedAt = Date(); receivedConnected = true }
            } catch {
                if !Task.isCancelled, privateSession?.directory == sessionPath,
                   state == .waiting || state == .connected {
                    append("Проверка данных: HTTPS example.com недоступен: \(error.localizedDescription)")
                    if kind == .xray && state == .waiting {
                        errorMessage = "Передача данных через Xray не подтверждена. Сеть восстанавливается; подробности в журнале."
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
    }
    private func fail(_ error: Error) {
        let message = redactor.redact(error.localizedDescription)
        errorMessage = message; state = .failed; append(message)
    }
}
