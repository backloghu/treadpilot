import SwiftData
import SwiftUI

@main
struct TunturiRunApp: App {
    @StateObject private var client = FitShowTreadmillClient()
    @StateObject private var runner = ProgramRunner()
    @StateObject private var recorder = SessionRecorder()
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var exporter = HealthKitExporter()
    @StateObject private var watchHeartRate = WatchHeartRateManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(runner)
                .environmentObject(recorder)
                .environmentObject(profileStore)
                .environmentObject(exporter)
                .environmentObject(watchHeartRate)
        }
        .modelContainer(for: [WorkoutSessionRecord.self, WorkoutSampleRecord.self,
                              CustomProgram.self, CustomSegmentRecord.self])
    }
}
