import SwiftUI
import TunnelCore

struct RoutingCheckView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var result: RoutingAddressInspector.Result?
    @State private var error: String?
    @State private var checking = false
    @State private var operation: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Проверить адрес").font(.title2.weight(.semibold))
            Text("Проверяется схема в редакторе. Сайт не открывается; при необходимости запрашиваются его IP-адреса.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Сайт или IP-адрес", text: $address).textFieldStyle(.roundedBorder).onSubmit(check)
                    .onChange(of: address) { _, _ in result = nil; error = nil; operation?.cancel(); checking = false }
                Button("Проверить", action: check).disabled(checking || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if checking { ProgressView("Определяем маршрут…") }
            if let result {
                Label(result.action.title, systemImage: result.action.symbol).font(.headline)
                Text(result.explanation).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !result.addresses.isEmpty { Text(result.addresses.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Это проверка выбора правила, а не подтверждение подключения или передачи данных через VPN.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 570).controlSize(.large)
            .onDisappear { operation?.cancel() }
    }
    private func check() {
        guard !checking, !address.isEmpty else { return }
        checking = true; error = nil; result = nil
        let input = address, policy = model.routing, runtime = model.connection.runtime, session = model.connection.routingRuntime
        operation = Task { @MainActor in
            do {
                let value = try await RoutingAddressInspector.check(input, policy: policy, runtime: runtime, session: session)
                guard !Task.isCancelled else { return }; result = value
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { checking = false }
        }
    }
}
