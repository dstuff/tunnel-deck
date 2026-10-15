import Foundation

enum ConnectionState: String {
    case idle, checking, authorizing, permission, configuring, waiting, connected, disconnecting, failed
    var title: String {
        switch self {
        case .idle: return "Не подключено"
        case .checking: return "Проверяем конфигурацию"
        case .authorizing: return "Авторизация"
        case .permission: return "Ожидаем разрешение macOS"
        case .configuring: return "Настраиваем сеть"
        case .waiting: return "Проверяем соединение"
        case .connected: return "Подключено"
        case .disconnecting: return "Отключаем"
        case .failed: return "Не удалось подключиться"
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
    let message: String
    init(_ message: String, date: Date = Date()) { self.message = message; self.date = date }
}
