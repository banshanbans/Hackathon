import SwiftUI

@main
struct SoloShotApp: App {
    @StateObject private var flow = AppFlowModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FoundationView(flow: flow)
                .task {
                    await flow.start()
                }
                .onOpenURL { url in
                    flow.receive(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        flow.handleSceneBecameActive()
                    } else {
                        flow.handleSceneBecameInactive()
                    }
                }
        }
    }
}
