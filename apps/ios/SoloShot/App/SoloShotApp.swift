import SwiftUI

@main
struct SoloShotApp: App {
    @StateObject private var flow = AppFlowModel()

    var body: some Scene {
        WindowGroup {
            FoundationView(flow: flow)
                .task {
                    await flow.start()
                }
                .onOpenURL { url in
                    flow.receive(url)
                }
        }
    }
}
