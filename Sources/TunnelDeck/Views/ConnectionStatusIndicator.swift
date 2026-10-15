import SwiftUI

struct ConnectionStatusIndicator: View {
    let state: ConnectionState

    private var color: Color {
        switch state {
        case .connected: return .green
        case .failed: return .red
        case .idle: return .secondary
        default: return .orange
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .help(state.title)
            .accessibilityLabel(state.title)
    }
}
