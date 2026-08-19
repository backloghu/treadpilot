import SwiftUI

@main
struct TunturiRunWatchApp: App {
    @StateObject private var workout = WatchWorkoutManager()

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(workout)
        }
    }
}
