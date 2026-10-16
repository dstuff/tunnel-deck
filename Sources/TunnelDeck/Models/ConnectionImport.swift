import Foundation
import TunnelCore

/// Local parsing only: importing does not authenticate or establish a tunnel.
struct ConnectionImport {
    let kind: VPNProtocol
    let suggestedName: String
    let server: String
    let secrets: ProfileSecrets

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VPNError("Вставьте ссылку, адрес сервера или конфигурацию.") }
        guard text.utf8.count < 256_000 else { throw VPNError("Конфигурация слишком большая.") }
        let firstContentLine = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        var secrets = ProfileSecrets()
        if firstContentLine?.hasPrefix("[") == true {
            _ = try AmneziaConfiguration(text)
            kind = .amneziaWG
            suggestedName = "AmneziaWG"
            server = ""
            secrets.configuration = text
        } else if text.hasPrefix("{") || text.hasPrefix("vless://") || text.hasPrefix("trojan://") {
            let configuration = try XrayConfiguration(text)
            kind = .xray
            suggestedName = configuration.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "Xray"
            server = ""
            secrets.configuration = text
        } else {
            let endpoint = try VPNEndpoint(server: text)
            kind = .openConnect
            suggestedName = endpoint.host
            server = endpoint.baseURL
            secrets.camouflage = endpoint.secret
        }
        self.secrets = secrets
    }
}
