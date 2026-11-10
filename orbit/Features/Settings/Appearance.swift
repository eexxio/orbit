import SwiftUI

/// Device-only look settings, saved in `UserDefaults` under these keys via `@AppStorage`.
enum AppearanceKey {
    static let accent = "hermes.accent"
    static let theme = "hermes.theme"
}

/// The tint for buttons, links and your own chat bubbles. `mono` follows the grayscale brand.
enum Accent: String, CaseIterable, Identifiable {
    case mono, blue, indigo, purple, pink, red, orange, green, teal

    var id: Self { self }

    var color: Color {
        switch self {
        case .mono: .primary
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        }
    }

    /// Text drawn on top of `color`: mono flips with the appearance, so its text does too.
    var onColor: Color { self == .mono ? Color(.systemBackground) : .white }

    var name: String { self == .mono ? "Mono" : rawValue.capitalized }
}

enum Theme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var name: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A row of color swatches; the selected one gets a ring.
struct AccentPicker: View {

    @Binding var selection: Accent

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Accent.allCases) { accent in
                Button {
                    selection = accent
                } label: {
                    Circle()
                        .fill(accent.color)
                        .frame(width: 26, height: 26)
                        .padding(3)
                        .overlay {
                            if accent == selection {
                                Circle().strokeBorder(accent.color, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(accent.name)
                .accessibilityAddTraits(accent == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
