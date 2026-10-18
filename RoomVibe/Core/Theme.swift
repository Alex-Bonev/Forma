import SwiftUI
import CoreText

/// "forma" look from the Paper file: warm paper ground, one sage accent, Space Mono everywhere.
enum Theme {
    static let ground = Color(hex: 0xF6F0E8)
    static let ink = Color(hex: 0x26231F)
    static let muted = Color(hex: 0x6F6A62)
    static let hairline = Color(hex: 0xE9DFD2)
    static let sage = Color(hex: 0x8A9577)
    static let onSage = Color(hex: 0xFBF8F3)   // text/icons on sage: never dark
    static let sageDeep = Color(hex: 0x6F7F62)   // sparkle on the Make it real pill
    static let sand = Color(hex: 0xEFE6DA)       // Make it real pill fill
    static let wood = Color(hex: 0x4A3828)
    static let terracotta = Color(hex: 0x8A4B2A)   // avoid tags, errors, delete
    static let tiles = [Color(hex: 0xDADCCF), Color(hex: 0xE6DCCF), Color(hex: 0xE9DFD2)]

    /// Space Mono ships as two bundled files; registering at launch avoids an Info.plist edit.
    static func registerFonts() {
        for name in ["SpaceMono-Regular", "SpaceMono-Bold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

extension Font {
    /// `relativeTo` keeps Dynamic Type working with the custom face.
    static func forma(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(bold ? "SpaceMono-Bold" : "SpaceMono-Regular", size: size, relativeTo: style)
    }
}

/// Pill button from the design: filled sage, or a 1 pt ink outline.
struct PillButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.forma(14))
            .foregroundStyle(filled ? Theme.onSage : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(filled ? Theme.sage : .clear, in: Capsule())
            .overlay { if !filled { Capsule().strokeBorder(Theme.ink, lineWidth: 1) } }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.25, bounce: 0), value: configuration.isPressed)
    }
}

/// "Rooms ........ 02" section header.
struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack {
            Text(title).font(.forma(13, bold: true))
            Spacer()
            Text(String(format: "%02d", count)).font(.forma(12)).foregroundStyle(Theme.muted)
                .contentTransition(.numericText(value: Double(count)))
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
