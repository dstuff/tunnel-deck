import SwiftUI
import AppKit

struct LogView: View {
    @Bindable var connection: ConnectionController
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Журнал соединения").font(.callout.weight(.medium))
                Text("Секреты скрыты").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(connection.exportedLog, forType: .string) }
                    label: { Image(systemName: "doc.on.doc") }.help("Копировать журнал")
                Button { connection.clearLog() } label: { Image(systemName: "trash") }.help("Очистить журнал")
            }.buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 12)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if connection.logs.isEmpty {
                            Text("События появятся после проверки или подключения.").foregroundStyle(.tertiary)
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
