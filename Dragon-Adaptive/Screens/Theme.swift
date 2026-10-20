//  Theme.swift
//  The design file's phone mockups as SwiftUI pieces: the device colours
//  (black screen, phosphor green, amber, muted grey, hairline borders), the
//  condensed display face for big numbers, mono labels, and the recurring
//  blocks: the DRAGON brand mark, a bordered field with a small caps label,
//  a segmented row, small stat tiles and the full-width call to action.

import SwiftUI
import DragonEngine

enum Theme {
    static let screen = Color.black
    static let ink = Color(red: 0xE4 / 255, green: 0xEA / 255, blue: 0xE6 / 255)
    static let muted = Color(red: 0x86 / 255, green: 0x93 / 255, blue: 0x8C / 255)
    static let line = Color(red: 0x23 / 255, green: 0x2A / 255, blue: 0x26 / 255)
    static let phos = Color(red: 0x39 / 255, green: 0xE2 / 255, blue: 0x7A / 255)
    static let amber = Color(red: 1, green: 0x8A / 255, blue: 0x3D / 255)
    static let segOn = Color(red: 0x16 / 255, green: 0x20 / 255, blue: 0x1B / 255)
    static let segOnLine = Color(red: 0x2A / 255, green: 0x4A / 255, blue: 0x37 / 255)
    static let ctaInk = Color(red: 0x04 / 255, green: 0x14 / 255, blue: 0x0A / 255)
    static let danger = Color(red: 1, green: 0.42, blue: 0.38)

    /// Big Shoulders Display stand-in: heavy, condensed, uppercase-friendly.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.condensed)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// "DRAGON" in a hairline box, as on every mockup's top bar.
struct BrandMark: View {
    var body: some View {
        Text("DRAGON")
            .font(Theme.mono(12, weight: .semibold)).tracking(1)
            .foregroundColor(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.24)))
    }
}

/// The top bar: brand (or anything) on the left, a mono caption on the right.
struct TopBar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            leading
            Spacer()
            trailing.font(Theme.mono(11)).foregroundColor(Theme.muted)
        }
    }
}

/// Small caps label over content, in a hairline box (the mockups' `.field`).
struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(Theme.mono(10)).tracking(1).foregroundColor(Theme.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

/// A row of equal options, one on (the mockups' `.seg`).
struct Segmented<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    var idPrefix = "seg"

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.1) { title, value in
                let on = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(Theme.mono(11)).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .foregroundColor(on ? Theme.phos : Theme.muted)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.segOn : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Theme.segOnLine : Theme.line))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(idPrefix).\(value)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// A small stat: caption over a display-face number (the mockups' `.stat-s`).
struct StatTile: View {
    let label: String
    let value: String
    var color: Color = Theme.ink
    var id: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(Theme.mono(9)).tracking(1).foregroundColor(Theme.muted)
            Text(value).font(Theme.display(23)).monospacedDigit().foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityIdentifier(id ?? "stat.\(label)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
    }
}

/// Full-width call to action: solid phosphor, or a hairline ghost.
struct CTAButtonStyle: ButtonStyle {
    var ghost = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(13, weight: ghost ? .medium : .semibold)).tracking(0.8)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .foregroundColor(ghost ? Theme.ink : Theme.ctaInk)
            .background(RoundedRectangle(cornerRadius: 8).fill(ghost ? Color.clear : Theme.phos))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ghost ? Theme.line : .clear))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}

/// A glasses mirror in the mockups' glowing frame.
struct HUDPanel: View {
    let frame: HUDFrame

    var body: some View {
        MirrorView(frame: frame)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.008, green: 0.02, blue: 0.012)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
    }
}

/// Text input styled for the device screen.
struct PlainInput: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var big = false
    var color: Color = Theme.ink
    var id: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Color(white: 0.3)))
            .font(big ? Theme.display(28) : .system(size: 15, weight: .semibold))
            .foregroundColor(color)
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .accessibilityIdentifier(id)
    }
}

extension View {
    /// Black behind the status bar, so scrolled content doesn't run under the clock.
    func statusBarScrim() -> some View {
        overlay(alignment: .top) {
            Color.clear.frame(height: 0).background(Theme.screen.ignoresSafeArea(edges: .top))
        }
    }
}
