import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HSplitView {
            ControlPanelView()
                .frame(minWidth: 400, idealWidth: 420, maxWidth: 520)

            if state.settings.showSubtitles {
                SubtitlesView()
                    .frame(minWidth: 360, idealWidth: 520)
            }
        }
        .background(TranslationHostView(bridge: state.translation))
        .frame(minWidth: state.settings.showSubtitles ? 820 : 400)
        .onAppear {
            state.openWindowAction = openWindow
            state.dismissWindowAction = dismissWindow
        }
    }
}
