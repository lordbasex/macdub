import SwiftUI

/// Visual language of the main window and menu bar panel: a deep gradient per section, glass
/// cards, glossy hero tiles and one big round action button — dark by design.
enum Theme {
    struct Palette {
        let top: Color
        let bottom: Color
        let accent: Color
        var gradient: LinearGradient {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    static let violet = Palette(top: Color(red: 0.36, green: 0.14, blue: 0.74), bottom: Color(red: 0.08, green: 0.05, blue: 0.24),
                                accent: Color(red: 0.78, green: 0.35, blue: 1.0))
    static let magenta = Palette(top: Color(red: 0.72, green: 0.12, blue: 0.55), bottom: Color(red: 0.22, green: 0.04, blue: 0.22),
                                 accent: Color(red: 1.0, green: 0.42, blue: 0.78))
    static let amber = Palette(top: Color(red: 0.80, green: 0.30, blue: 0.08), bottom: Color(red: 0.26, green: 0.07, blue: 0.04),
                               accent: Color(red: 1.0, green: 0.62, blue: 0.25))
    static let azure = Palette(top: Color(red: 0.10, green: 0.32, blue: 0.80), bottom: Color(red: 0.04, green: 0.08, blue: 0.28),
                               accent: Color(red: 0.35, green: 0.70, blue: 1.0))
    static let emerald = Palette(top: Color(red: 0.08, green: 0.48, blue: 0.40), bottom: Color(red: 0.03, green: 0.14, blue: 0.14),
                                 accent: Color(red: 0.35, green: 0.90, blue: 0.70))

    static let cardFill = Color.white.opacity(0.08)
    static let cardStroke = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.65)
    static let tertiaryText = Color.white.opacity(0.45)
}

/// Sections of the main window; each carries its own palette.
enum AppSection: String, CaseIterable, Identifiable {
    case dub, subtitles, history, ai

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .dub: return "Dubbing"
        case .subtitles: return "Subtitles"
        case .history: return "History"
        case .ai: return "AI & MCP"
        }
    }

    var symbol: String {
        switch self {
        case .dub: return "waveform.and.mic"
        case .subtitles: return "captions.bubble.fill"
        case .history: return "clock.arrow.circlepath"
        case .ai: return "sparkles"
        }
    }

    var palette: Theme.Palette {
        switch self {
        case .dub: return Theme.violet
        case .subtitles: return Theme.magenta
        case .history: return Theme.amber
        case .ai: return Theme.azure
        }
    }
}

// MARK: - Building blocks

/// Translucent rounded card used everywhere on the gradient.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

/// The large glossy tile with a symbol (or image) that headlines each section.
struct HeroTile: View {
    var symbol: String? = nil
    var image: NSImage? = nil
    var palette: Theme.Palette
    var size: CGFloat = 220

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [palette.accent.opacity(0.95), palette.top.opacity(0.9)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .shadow(color: palette.accent.opacity(0.55), radius: 40, y: 18)
            if let image {
                Image(nsImage: image)
                    .resizable().interpolation(.high)
                    .frame(width: size * 0.78, height: size * 0.78)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Bulleted feature line under a hero title.
struct FeatureRow: View {
    let symbol: String
    let text: LocalizedStringKey
    var palette: Theme.Palette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(palette.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(text).font(.body.weight(.medium)).foregroundStyle(.white)
        }
    }
}

/// The round primary action (Start / Stop) with a glow.
struct RoundActionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var palette: Theme.Palette
    var destructive = false
    var busy = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: symbol).font(.system(size: 20, weight: .bold))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 92, height: 92)
            .background(
                Circle().fill(
                    destructive
                        ? LinearGradient(colors: [Color(red: 1, green: 0.35, blue: 0.35), Color(red: 0.75, green: 0.1, blue: 0.2)], startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [palette.accent, palette.top], startPoint: .top, endPoint: .bottom)
                )
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
            .shadow(color: (destructive ? Color.red : palette.accent).opacity(0.7), radius: 24, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Sidebar entry.
struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? section.palette.accent : .white.opacity(0.8))
                    .frame(width: 24)
                Text(section.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(selected ? Color.white.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Plain buttons with an icon + text label get no accessible name of their own.
        .accessibilityLabel(Text(section.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A labelled row inside a glass card (label left, control right).
struct CardRow<Control: View>: View {
    let title: LocalizedStringKey
    /// Name the control after the title (VoiceOver). Off for rows that hold several controls —
    /// the outer label would override theirs — which then name their main control themselves.
    var labelsControl = true
    @ViewBuilder var control: Control

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Theme.secondaryText)
                .accessibilityHidden(labelsControl)  // then it is the control's name, not separate text
            Spacer()
            if labelsControl {
                control.accessibilityLabel(Text(title))
            } else {
                control
            }
        }
        .frame(minHeight: 28)
    }
}

/// Simple horizontal audio level bar.
struct LevelMeter: View {
    var level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(level > 0.8 ? Color.red : level > 0.5 ? Color.yellow : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, level)))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 6)
    }
}

extension Settings {
    /// Two-way binding into a `Settings` property for SwiftUI controls.
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

extension View {
    /// Tooltip and VoiceOver name for icon-only buttons, from one localized key so they stay in sync.
    func iconButtonHelp(_ key: LocalizedStringKey) -> some View {
        help(key).accessibilityLabel(Text(key))
    }
}
