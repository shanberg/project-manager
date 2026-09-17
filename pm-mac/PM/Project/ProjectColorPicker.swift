import AppKit
import PmLib
import SwiftUI

extension ProjectColor {
    /// What the colour looks like here. A name is the system's own colour, so it follows light and dark
    /// and the increased-contrast setting; a custom colour is exactly what was picked.
    var nsColor: NSColor {
        switch self {
        case .named(let name):
            switch name {
            case .red: return .systemRed
            case .orange: return .systemOrange
            case .yellow: return .systemYellow
            case .green: return .systemGreen
            case .mint: return .systemMint
            case .teal: return .systemTeal
            case .cyan: return .systemCyan
            case .blue: return .systemBlue
            case .indigo: return .systemIndigo
            case .purple: return .systemPurple
            case .pink: return .systemPink
            case .brown: return .systemBrown
            }
        case .custom:
            let rgb = rgb ?? (0, 0, 0)
            return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }

    var swiftUIColor: Color { Color(nsColor: nsColor) }

    /// "Blue", or "Custom" — for a tooltip and for VoiceOver.
    var displayName: String {
        switch self {
        case .named(let name): return name.rawValue.capitalized
        case .custom: return "Custom"
        }
    }
}

/// A row of the named colours, None first, and a well for any other — Project Settings' Color row.
struct ProjectColorPicker: View {
    @Binding var color: ProjectColor?

    private static let swatch: CGFloat = 16

    var body: some View {
        HStack(spacing: 4) {
            button(for: nil)
            ForEach(ProjectColor.Name.allCases, id: \.self) { button(for: .named($0)) }
            ColorPicker("Other", selection: custom, supportsOpacity: false)
                .labelsHidden()
                .help("Other Color")
        }
    }

    /// The well shows the custom colour when there is one, and otherwise the chosen named colour, so
    /// opening it starts from where you are.
    private var custom: Binding<Color> {
        Binding {
            color?.swiftUIColor ?? .gray
        } set: { picked in
            guard let rgb = NSColor(picked).usingColorSpace(.sRGB) else { return }
            let chosen = ProjectColor.custom(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            // The well reports the colour it was opened on as a pick; a named colour stays named.
            if case .named = color, chosen == Self.custom(of: color) { return }
            color = chosen
        }
    }

    private static func custom(of color: ProjectColor?) -> ProjectColor? {
        guard let rgb = color?.nsColor.usingColorSpace(.sRGB) else { return nil }
        return .custom(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }

    private func button(for option: ProjectColor?) -> some View {
        let selected = option == color
        return Button {
            color = option
        } label: {
            ZStack {
                if let option {
                    Circle().fill(option.swiftUIColor)
                } else {
                    Circle().strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
                    Rectangle()
                        .fill(Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 1, height: Self.swatch)
                        .rotationEffect(.degrees(45))
                }
            }
            .frame(width: Self.swatch, height: Self.swatch)
            .padding(2)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(option?.displayName ?? "None")
        .accessibilityLabel(Text(option?.displayName ?? "No Color"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
