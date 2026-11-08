import SwiftUI
import UIKit

enum SignInStyle {
    static let background = color(0xFFFFFF, 0x111318)
    static let surface = color(0xF4F5F8, 0x1C2028)
    static let text = color(0x191D27, 0xF3F5F8)
    static let secondary = color(0x525D6D, 0xB4BBC8)
    static let action = color(0x3157C8, 0xA9BAFA)
    static let onAction = color(0xFFFFFF, 0x191D27)

    private static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(
            uiColor: UIColor { traits in
                let hex = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: Double((hex >> 16) & 255) / 255,
                    green: Double((hex >> 8) & 255) / 255,
                    blue: Double(hex & 255) / 255, alpha: 1)
            })
    }
}

struct SignInButtonStyle: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(primary ? SignInStyle.onAction : SignInStyle.action)
            .background(primary ? SignInStyle.action : .clear, in: RoundedRectangle(cornerRadius: 12))
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.75 : 1)
    }
}
