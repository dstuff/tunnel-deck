import TunnelLocalization
import SwiftUI
import AppKit

struct LogView: View {
    @Bindable var connection: ConnectionController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("logview.connection_log")).font(.callout.weight(.medium))
                Text(L10n.text("logview.secrets_hidden")).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(connection.exportedLog, forType: .string) }
                    label: { Image(systemName: "doc.on.doc") }.help(L10n.text("logview.copy_log"))
                    .accessibilityLabel(L10n.text("logview.copy_log"))
                Button { connection.clearLog() } label: { Image(systemName: "trash") }.help(L10n.text("logview.clear_log"))
                    .accessibilityLabel(L10n.text("logview.clear_log"))
            }.buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 12)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if connection.logs.isEmpty {
                            Text(L10n.text("logview.events_will_appear_after_checking_or_connecting")).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(connection.logs) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.date.formatted(date: .omitted, time: .standard)).foregroundStyle(.tertiary)
                                Text(entry.message).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }.id(entry.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 22).padding(.bottom, 14)
                }
                .onChange(of: connection.logs.last?.id) { _, _ in
                    if let last = connection.logs.last { scroll.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}
