import Foundation

/// Every user-facing failure of the pipeline. `recoverySuggestion` is shown in the UI
/// next to the error so the user knows what to do (download a model, grant a permission…).
enum MacDubError: LocalizedError {
    case screenRecordingDenied
    case speechRecognitionDenied
    case speechRecognitionRestricted
    case speechLocaleUnsupported(String)
    case onDeviceRecognitionUnavailable(String)
    case speechRecognizerUnavailable(String)
    case targetAppNotRunning(String)
    case noDisplay
    case translationUnsupported(source: String, target: String)
    case translationNotReady
    case translationFailed(String)
    case noVoiceForLanguage(String)
    case captureStopped(String)
    case targetNotPlayingAudio(String)
    case audioTapFailed(String)

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return L("Screen Recording permission is required to capture application audio.")
        case .speechRecognitionDenied:
            return L("Speech Recognition permission was denied.")
        case .speechRecognitionRestricted:
            return L("Speech Recognition is restricted on this Mac.")
        case .speechLocaleUnsupported(let id):
            return LF("Speech recognition does not support the language “%@”.", id)
        case .onDeviceRecognitionUnavailable(let id):
            return LF("On-device speech recognition is not available for “%@”.", id)
        case .speechRecognizerUnavailable(let id):
            return LF("The speech recognizer for “%@” is temporarily unavailable.", id)
        case .targetAppNotRunning(let name):
            return LF("“%@” is no longer running.", name)
        case .noDisplay:
            return L("No display found to attach the capture stream to.")
        case .translationUnsupported(let s, let t):
            return LF("Translation from “%@” to “%@” is not supported.", s, t)
        case .translationNotReady:
            return L("The translation model is not ready yet.")
        case .translationFailed(let msg):
            return LF("Translation failed: %@", msg)
        case .noVoiceForLanguage(let id):
            return LF("No system voice installed for “%@”.", id)
        case .captureStopped(let msg):
            return LF("Audio capture stopped: %@", msg)
        case .targetNotPlayingAudio(let name):
            return LF("“%@” has not produced any audio yet.", name)
        case .audioTapFailed(let msg):
            return LF("Could not tap the application's audio: %@", msg)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .screenRecordingDenied:
            return L("Open System Settings › Privacy & Security › Screen & System Audio Recording and enable MacDub, then relaunch the app.")
        case .speechRecognitionDenied:
            return L("Open System Settings › Privacy & Security › Speech Recognition and enable MacDub.")
        case .onDeviceRecognitionUnavailable:
            return L("Open System Settings › Keyboard › Dictation and add the language so macOS downloads the on-device model.")
        case .translationUnsupported:
            return L("Pick a different language pair.")
        case .translationNotReady:
            return L("Press “Prepare translation” and accept the model download (one time, requires internet).")
        case .noVoiceForLanguage:
            return L("Open System Settings › Accessibility › Spoken Content › System Voice › Manage Voices and download a voice.")
        case .targetNotPlayingAudio:
            return L("Play something in that app first, then press Start — or switch the capture engine to ScreenCaptureKit.")
        case .audioTapFailed:
            return L("Switch the capture engine to ScreenCaptureKit (the original audio can't be lowered in that mode).")
        default:
            return nil
        }
    }
}
