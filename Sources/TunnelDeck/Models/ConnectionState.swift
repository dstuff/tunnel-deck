import TunnelLocalization
import Foundation

enum ConnectionState: String {
    case idle, checking, authorizing, permission, configuring, waiting, connected, disconnecting, failed
    var title: String {
        switch self {
        case .idle: return L10n.text("connection.state.idle")
        case .checking: return L10n.text("connection.state.checking")
        case .authorizing: return L10n.text("connection.state.authorizing")
        case .permission: return L10n.text("connection.state.permission")
        case .configuring: return L10n.text("connection.state.configuring")
        case .waiting: return L10n.text("connection.state.waiting")
        case .connected: return L10n.text("connection.state.connected")
        case .disconnecting: return L10n.text("connection.state.disconnecting")
        case .failed: return L10n.text("connection.state.failed")
        }
    }
    var busy: Bool { ![.idle, .failed, .connected].contains(self) }
    var menuBarSymbol: String {
        switch self {
        case .connected: return "link.circle.fill"
        case .idle, .failed: return "link"
        default: return "link.circle"
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let content: LocalizedMessage
    var message: String { content.resolve() }
    init(_ message: LocalizedMessage, date: Date = Date()) { self.content = message; self.date = date }
    init(_ message: String, date: Date = Date()) { self.init(.verbatim(message), date: date) }
}
