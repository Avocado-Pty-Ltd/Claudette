import SwiftUI

enum Theme {
    enum Palette {
        static let accent = Color(hex: 0xC96442)
        static let accentSoft = Color(hex: 0xE0A48A)
        static let bgPrimary = Color("BgPrimary", fallback: .init(hex: 0xFAF7F2), dark: .init(hex: 0x14120F))
        static let bgSecondary = Color("BgSecondary", fallback: .init(hex: 0xF3EEE5), dark: .init(hex: 0x1B1815))
        static let bgSidebar = Color("BgSidebar", fallback: .init(hex: 0xEFE9DE), dark: .init(hex: 0x121110))
        static let bgElevated = Color("BgElevated", fallback: .init(hex: 0xFFFFFF), dark: .init(hex: 0x24211C))
        static let border = Color("Border", fallback: .init(hex: 0xE3DCCE), dark: .init(hex: 0x2F2B25))
        static let borderStrong = Color("BorderStrong", fallback: .init(hex: 0xC9BEA9), dark: .init(hex: 0x3D3830))
        static let textPrimary = Color("TextPrimary", fallback: .init(hex: 0x211E1B), dark: .init(hex: 0xF2ECE0))
        static let textSecondary = Color("TextSecondary", fallback: .init(hex: 0x6C6459), dark: .init(hex: 0xA69C8B))
        static let textTertiary = Color("TextTertiary", fallback: .init(hex: 0x968D7E), dark: .init(hex: 0x736A5C))
        static let userBubble = Color("UserBubble", fallback: .init(hex: 0xF5EDDF), dark: .init(hex: 0x2A241C))
        static let codeBg = Color("CodeBg", fallback: .init(hex: 0xF7F1E4), dark: .init(hex: 0x1F1C17))
        static let codeBorder = Color("CodeBorder", fallback: .init(hex: 0xE0D6C1), dark: .init(hex: 0x322D25))
        static let toolBg = Color("ToolBg", fallback: .init(hex: 0xEDE5D2), dark: .init(hex: 0x232019))
    }

    enum Font {
        static let display = SwiftUI.Font.system(size: 28, weight: .semibold, design: .serif)
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold, design: .default)
        static let heading = SwiftUI.Font.system(size: 15, weight: .semibold, design: .default)
        static let body = SwiftUI.Font.system(size: 14, weight: .regular, design: .default)
        static let bodySerif = SwiftUI.Font.system(size: 15, weight: .regular, design: .serif)
        static let caption = SwiftUI.Font.system(size: 12, weight: .regular, design: .default)
        static let micro = SwiftUI.Font.system(size: 11, weight: .medium, design: .default)
        static let mono = SwiftUI.Font.system(size: 13, weight: .regular, design: .monospaced)
        static let monoSmall = SwiftUI.Font.system(size: 12, weight: .regular, design: .monospaced)

        // "Cinema" — used inside expanded action cards so the code reads big while it plays.
        static let cinemaMono = SwiftUI.Font.system(size: 16, weight: .regular, design: .monospaced)
        static let cinemaMonoBold = SwiftUI.Font.system(size: 16, weight: .semibold, design: .monospaced)
        static let cinemaBody = SwiftUI.Font.system(size: 17, weight: .regular, design: .serif)
        static let cinemaLabel = SwiftUI.Font.system(size: 13, weight: .semibold, design: .monospaced)
    }

    enum Metric {
        static let cornerSm: CGFloat = 6
        static let cornerMd: CGFloat = 10
        static let cornerLg: CGFloat = 14
        static let cornerXl: CGFloat = 20
        static let sidebarWidth: CGFloat = 240
        static let messageMaxWidth: CGFloat = 720
        static let contentPadding: CGFloat = 28
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    init(_ name: String, fallback: Color, dark: Color) {
        self.init(nsColor: NSColor(name: NSColor.Name(name), dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(dark) : NSColor(fallback)
        }))
    }
}
