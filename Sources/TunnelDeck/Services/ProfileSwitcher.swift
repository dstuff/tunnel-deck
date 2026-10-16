import Foundation
import Observation
import TunnelCore

@MainActor protocol ConnectionLifecycle: AnyObject {
    var state: ConnectionState { get }
    var locked: Bool { get }
    func disconnect()
}

extension ConnectionController: ConnectionLifecycle {}

/// A new tunnel may start only after the previous helper confirms cleanup.
@MainActor @Observable final class ProfileSwitcher {
    private(set) var targetProfile: UUID?
    private(set) var errorMessage: String?
    private let connection: any ConnectionLifecycle
    private let timeout: Duration
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?

    var isSwitching: Bool { targetProfile != nil }

    init(connection: any ConnectionLifecycle, timeout: Duration = .seconds(30)) {
        self.connection = connection
        self.timeout = timeout
    }

    func start(to profile: UUID, connect: @escaping @MainActor () -> Void) {
        guard !isSwitching, connection.state == .connected else { return }
        errorMessage = nil
        targetProfile = profile
        let operationID = UUID()
        self.operationID = operationID
        connection.disconnect()
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: timeout)
            do {
                while connection.locked {
                    guard ContinuousClock.now < deadline else {
                        throw VPNError("Сеть ещё восстанавливается. Дождитесь отключения и повторите переключение.")
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard self.operationID == operationID else { return }
                guard connection.state == .idle else {
                    throw VPNError("Не удалось штатно завершить подключение. Проверьте диагностику перед повторной попыткой.")
                }
                targetProfile = nil
                operation = nil
                self.operationID = nil
                connect()
            } catch {
                guard self.operationID == operationID else { return }
                if !Task.isCancelled { errorMessage = error.localizedDescription }
                targetProfile = nil
                operation = nil
                self.operationID = nil
            }
        }
    }

    func cancel() {
        operation?.cancel()
        operation = nil
        operationID = nil
        targetProfile = nil
    }

    func clearError() { errorMessage = nil }
}
