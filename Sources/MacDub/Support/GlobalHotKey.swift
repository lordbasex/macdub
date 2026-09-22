import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts through Carbon's `RegisterEventHotKey`, which — unlike
/// `NSEvent.addGlobalMonitorForEvents` — needs no Accessibility permission.
///
/// Defaults: ⌃⌥D toggles dubbing, ⌃⌥S toggles the subtitle bar.
@MainActor
final class GlobalHotKeys {
    enum Action: UInt32, CaseIterable {
        case toggleDubbing = 1
        case toggleSubtitleBar = 2

        var keyCode: UInt32 {
            switch self {
            case .toggleDubbing: return UInt32(kVK_ANSI_D)
            case .toggleSubtitleBar: return UInt32(kVK_ANSI_S)
            }
        }
        var modifiers: UInt32 { UInt32(controlKey | optionKey) }
        var display: String {
            switch self {
            case .toggleDubbing: return "⌃⌥D"
            case .toggleSubtitleBar: return "⌃⌥S"
            }
        }
    }

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private let signature = OSType(0x4D444248) // 'MDBH'
    var onAction: ((Action) -> Void)?

    func register() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let hotKeys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            if let action = Action(rawValue: hotKeyID.id) {
                Task { @MainActor in hotKeys.onAction?(action) }
            }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: action.rawValue)
            let status = RegisterEventHotKey(action.keyCode, action.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[action] = ref } else { Log.app.error("Hot key \(action.display, privacy: .public) failed (\(status))") }
        }
        Log.app.info("Global hot keys registered")
    }

    func unregister() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}
