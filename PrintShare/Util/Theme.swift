import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

/// Colors of the Expo app (`theme.ts`), light and dark.
enum Theme {
    static let radius: CGFloat = 14
    static let space: CGFloat = 16

    static let bg = Color.dynamic(light: 0xF2F2F7, dark: 0x000000)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
    static let text = Color.dynamic(light: 0x111114, dark: 0xF2F2F7)
    static let sub = Color.dynamic(light: 0x6B6B73, dark: 0x9A9AA2)
    static let line = Color.dynamic(light: 0xE2E2E8, dark: 0x2C2C30)
    static let accent = Color.dynamic(light: 0x2F6FED, dark: 0x5B8DF6)
    static let accentText = Color.white
    static let accentSoft = Color.dynamic(light: 0xE4ECFD, dark: 0x17243F)
    static let ok = Color.dynamic(light: 0x1E8E3E, dark: 0x4CC06A)
    static let okSoft = Color.dynamic(light: 0xE3F4E8, dark: 0x16301D)
    static let warn = Color.dynamic(light: 0xB25E00, dark: 0xF0A33A)
    static let warnSoft = Color.dynamic(light: 0xFFF3DC, dark: 0x33260F)
    static let danger = Color.dynamic(light: 0xD12F2F, dark: 0xFF5C5C)
    static let dangerSoft = Color.dynamic(light: 0xFDE6E6, dark: 0x3A1717)
    static let input = Color.dynamic(light: 0xF2F2F7, dark: 0x2C2C2E)
    static let track = Color.dynamic(light: 0xE5E5EA, dark: 0x3A3A3C)
}
