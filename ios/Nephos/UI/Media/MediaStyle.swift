import SwiftUI
import UIKit

enum MediaStyle {
    static let background = color(0xFFFFFF, 0x101318)
    static let surface = color(0xF4F5F8, 0x1C2028)
    static let text = color(0x191D27, 0xF3F5F8)
    static let secondary = color(0x525D6D, 0xB4BBC8)
    static let accent = color(0x3157C8, 0xA9BAFA)
    static let selected = color(0xE8EDFC, 0x252E43)
    static let uploadGreen = color(0x15803D, 0x5CDA8B)

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
