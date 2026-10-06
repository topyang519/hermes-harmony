import SwiftUI

@main
struct HermesHarmonyApp: App {
    @StateObject private var gateway = GatewayClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(gateway)
                .preferredColorScheme(.dark)
        }
    }
}
