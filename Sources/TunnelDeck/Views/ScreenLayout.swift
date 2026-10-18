import SwiftUI
import TunnelLocalization

struct ScreenHeader<Actions: View>: View {
    let title: String
    let backTitle: String
    let onBack: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) {
                heading
                Spacer(minLength: 0)
                actions().fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                heading
                actions()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 26).padding(.vertical, 16)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onBack) { Label(backTitle, systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(.tint)
            Text(title).font(.system(size: 25, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AdaptiveSettingRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                Text(title).fixedSize()
                Spacer(minLength: 0)
                control().fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                control()
            }
        }
    }
}
