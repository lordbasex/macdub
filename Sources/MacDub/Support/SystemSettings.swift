import AppKit

/// Deep links into System Settings panes the user needs to visit to grant permissions
/// or download on-device models.
enum SystemSettings {
    static let screenRecording = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    static let speechRecognition = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    static let dictation = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation"
    static let spokenContent = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"
    static let personalVoice = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?PersonalVoice"

    static func open(_ link: String) {
        guard let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}
