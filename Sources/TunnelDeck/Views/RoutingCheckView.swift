import TunnelLocalization
import SwiftUI
import TunnelCore

struct RoutingCheckView: View {
    let model: AppModel
    var width: CGFloat = 570
    var height: CGFloat = 500
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var result: RoutingAddressInspector.Result?
    @State private var errorContent: LocalizedMessage?
    private var error: String? { errorContent?.resolve() }
    @State private var checking = false
    @State private var operation: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
          ScrollView {
           VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("routingcheckview.check_address")).font(.title2.weight(.semibold))
            Text(L10n.text("routingcheckview.checks_the_policy_in_the_editor_the_website_is"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(L10n.text("routingcheckview.website_or_ip_address"), text: $address).textFieldStyle(.roundedBorder).onSubmit(check)
                    .onChange(of: address) { _, _ in result = nil; errorContent = nil; operation?.cancel(); checking = false }
                Button(L10n.text("action.check"), action: check).disabled(checking || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if checking { ProgressView(L10n.text("routingcheckview.determining_route")) }
            if let result {
                Label(result.action.title, systemImage: result.action.symbol).font(.headline)
                Text(result.explanation).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !result.addresses.isEmpty { Text(result.addresses.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Text(L10n.text("routingcheckview.this_checks_rule_selection_it_does_not_confirm_a"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
           }.frame(maxWidth: .infinity, alignment: .leading).padding(26)
          }
          HStack { Spacer(); Button(L10n.text("action.done")) { dismiss() }.keyboardShortcut(.cancelAction) }
              .padding(.horizontal, 26).padding(.bottom, 20)
        }.frame(width: width, height: height).controlSize(.regular)
            .onDisappear { operation?.cancel() }
    }
    private func check() {
        guard !checking, !address.isEmpty else { return }
        checking = true; errorContent = nil; result = nil
        let input = address, policy = model.routing, runtime = model.connection.runtime, session = model.connection.routingRuntime
        operation = Task { @MainActor in
            do {
                let value = try await RoutingAddressInspector.check(input, policy: policy, runtime: runtime, session: session)
                guard !Task.isCancelled else { return }; result = value
            } catch { if !Task.isCancelled { self.errorContent = error.localizedMessage } }
            if !Task.isCancelled { checking = false }
        }
    }
}
