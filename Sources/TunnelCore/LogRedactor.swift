import TunnelLocalization
import Foundation
import TunnelLocalization

public struct LogRedactor: Sendable {
    private var secrets: [String]
    public init(values: [String] = []) {
        secrets = values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }
    public init(request: TunnelRequest) {
        var values = [request.cookie, request.secrets.password, request.secrets.camouflage]
        if let endpoint = try? VPNEndpoint(server: request.profile.server, camouflage: request.secrets.camouflage) {
            values += [endpoint.url, endpoint.secret]
        }
        for line in request.secrets.configuration.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && ["privatekey", "presharedkey", "headerprotectionkey"].contains(parts[0].trimmingCharacters(in: .whitespaces).lowercased()) {
                values.append(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        if let data = request.secrets.configuration.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) {
            func collect(_ value: Any) {
                if let object = value as? [String: Any] {
                    for (key, child) in object {
                        if ["id", "password", "privatekey", "publickey", "shortid", "token"].contains(key.lowercased()), let secret = child as? String {
                            values.append(secret)
                        }
                        collect(child)
                    }
                } else if let array = value as? [Any] { array.forEach(collect) }
            }
            collect(json)
        } else if let uri = URLComponents(string: request.secrets.configuration), ["vless", "trojan"].contains(uri.scheme ?? ""), let identity = uri.user {
            values.append(identity)
        }
        self.init(values: values)
    }
    public func redact(_ text: String) -> String {
        var result = text
        for secret in secrets { result = result.replacingOccurrences(of: secret, with: "<redacted>") }
        for (pattern, replacement) in [
            (#"(?i)(https?://[^\s?\"']+)\?[^\s\"']*"#, "$1?<redacted>"),
            (#"(?i)(?:vless|vmess|trojan|ss)://[^\s]+"#, "<redacted URI>"),
            (#"(?i)((?:cookie|authorization|privatekey|presharedkey|headerprotectionkey|password)\s*[:=]\s*)[^\r\n]+"#, "$1<redacted>")
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            }
        }
        return result
    }
    public func redact(_ message: LocalizedMessage) -> LocalizedMessage {
        message.mapText { redact($0) }
    }
}
