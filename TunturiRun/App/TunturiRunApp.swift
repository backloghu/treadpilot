import SwiftUI

@main
struct TunturiRunApp: App {
    @StateObject private var client = FitShowTreadmillClient()
    @StateObject private var runner = ProgramRunner()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(runner)
        }
    }
}
