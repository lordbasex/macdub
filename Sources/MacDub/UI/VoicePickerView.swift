import SwiftUI
import AVFAudio

/// Voice picker isolated from the rest of the app state.
///
/// A SwiftUI `Picker` menu runs its own event-tracking loop while open; if the view that owns
/// it is re-rendered meanwhile (level meter, partial text…) the menu is rebuilt under the
/// tracking loop and the app appears frozen. This view is `Equatable` on the only inputs that
/// matter, so nothing else that happens while dubbing touches the open menu.
struct VoicePickerView: View, Equatable {
    var title: LocalizedStringKey = "System voice"
    let voices: [AVSpeechSynthesisVoice]
    @Binding var selection: String

    static func == (lhs: VoicePickerView, rhs: VoicePickerView) -> Bool {
        lhs.selection == rhs.selection
            && lhs.voices.map(\.identifier) == rhs.voices.map(\.identifier)
    }

    var body: some View {
        Picker(title, selection: $selection) {
            if voices.isEmpty {
                Text("No voice installed for this language").tag("")
            }
            ForEach(voices, id: \.identifier) { v in
                Text(VoiceSynthesisManager.menuTitle(for: v)).tag(v.identifier)
            }
        }
    }
}

/// Publishes the audio level on its own so meters can redraw 20×/s without invalidating the
/// forms that host them.
@MainActor
final class LiveMeter: ObservableObject {
    @Published var level: Float = 0
}

struct LiveLevelMeter: View {
    @ObservedObject var meter: LiveMeter

    var body: some View {
        LevelMeter(level: meter.level)
    }
}
