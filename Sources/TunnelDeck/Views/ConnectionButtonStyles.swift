import SwiftUI

struct PrimaryConnectionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 18).frame(height: 36)
            .foregroundStyle(.white)
            .background(.blue.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct SecondaryConnectionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 15).frame(height: 34)
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.25)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
