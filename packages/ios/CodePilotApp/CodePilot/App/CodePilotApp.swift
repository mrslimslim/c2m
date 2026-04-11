import SwiftUI

@main
struct CodePilotApp: App {
    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    @ViewBuilder
    private var rootView: some View {
#if DEBUG
        if let uiTestAppModel = AppModel.uiTestFixtureIfRequested(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            RootView(appModel: uiTestAppModel)
        } else {
            RootView()
        }
#else
        RootView()
#endif
    }
}
