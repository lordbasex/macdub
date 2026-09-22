import AppKit
import SwiftUI
import Combine

/// Menu bar item. Left click: preview panel (`MenuBarPanelView`). Right click: context menu.
@MainActor
final class StatusBarController: NSObject {
    private let state: AppState
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "MacDub")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = L("MacDub — click for status, right-click for options")
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPanelView(dismiss: { [weak self] in self?.popover.performClose(nil) })
                .environmentObject(state)
        )

        state.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in self?.updateIcon(phase: phase) }
            .store(in: &cancellables)
        // The composed (non-template) icon bakes in the menu bar's text colour; redraw when the
        // bar switches between light and dark.
        appearanceObservation = item.button?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateIcon(phase: self.state.phase)
            }
        }
    }

    private var appearanceObservation: NSKeyValueObservation?

    /// Idle: plain template glyph. Starting: amber dot. Running: green dot — "transcribing".
    private func updateIcon(phase: AppState.Phase) {
        guard let button = item.button else { return }
        let dot: NSColor?
        switch phase {
        case .idle, .stopping: dot = nil
        case .starting: dot = .systemOrange
        case .running: dot = .systemGreen
        }
        guard let dot else {
            let image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "MacDub")
            image?.isTemplate = true
            button.image = image
            button.toolTip = L("MacDub — click for status, right-click for options")
            return
        }

        // Resolve the glyph colour for the bar's current appearance, then draw glyph + dot.
        var glyphColor = NSColor.labelColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            glyphColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [glyphColor]))
        guard let glyph = NSImage(systemSymbolName: "captions.bubble.fill", accessibilityDescription: "MacDub")?
            .withSymbolConfiguration(config) else { return }

        let size = NSSize(width: glyph.size.width + 4, height: max(glyph.size.height, 18))
        let composed = NSImage(size: size, flipped: false) { rect in
            let glyphRect = NSRect(x: 0, y: (rect.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: glyphRect)
            let d: CGFloat = 7
            let dotRect = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            // Halo in the bar colour so the dot reads on top of the glyph's edge.
            NSColor.windowBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            dot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        composed.isTemplate = false
        button.image = composed
        button.toolTip = phase == .running
            ? L("MacDub is dubbing — click for status")
            : L("MacDub — click for status, right-click for options")
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let running = state.phase == .running
        menu.addItem(withTitle: running ? L("Stop Dubbing") : L("Start Dubbing"), action: #selector(toggleDubbing), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: state.isSubtitleBarVisible ? L("Hide Subtitle Bar") : L("Show Subtitle Bar"),
                     action: #selector(toggleSubtitleBar), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("MacDub Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("Session History…"), action: #selector(openHistory), keyEquivalent: "y").target = self
        menu.addItem(withTitle: L("About MacDub"), action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit MacDub"), action: #selector(quit), keyEquivalent: "q").target = self

        // Attach the menu only for this click so left clicks keep opening the popover.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleDubbing() { state.toggle() }
    @objc private func toggleSubtitleBar() { state.toggleSubtitleBar() }
    @objc private func openSettings() { state.showMainWindow() }
    @objc private func openHistory() { state.showHistory() }
    @objc private func showAbout() { state.showAbout() }
    @objc private func quit() { NSApp.terminate(nil) }
}
