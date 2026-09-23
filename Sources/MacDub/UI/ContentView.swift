import AppKit
import SwiftUI

/// Root of the main window.
struct ContentView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        MainView()
            .background(MainWindowBehavior())
            .onAppear { state.ensureTranslationSession() }
    }
}

/// Makes the main window *hide* instead of closing.
///
/// `TranslationHostView` lives in this window and `TranslationSession` only exists while that
/// view is alive: closing the window (⌘W, the red button) cancelled the session — dubbing kept
/// running from the menu bar but nothing was translated — and reopening the window did not
/// restart it (verified: `.translationTask` does not re-run on re-appearance). Ordering the
/// window out keeps the view, and the session, alive; `AppState.showMainWindow` brings it back.
private struct MainWindowBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HookView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HookView: NSView {
        private var interceptor: CloseInterceptor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, interceptor == nil else { return }
            let interceptor = CloseInterceptor(original: window.delegate)
            self.interceptor = interceptor
            window.delegate = interceptor
        }
    }
}

/// Answers `windowShouldClose` with "hide it" and forwards every other delegate message to
/// SwiftUI's own delegate, so the scene keeps working as before.
private final class CloseInterceptor: NSObject, NSWindowDelegate {
    private let original: NSWindowDelegate?

    init(original: NSWindowDelegate?) {
        self.original = original
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}
