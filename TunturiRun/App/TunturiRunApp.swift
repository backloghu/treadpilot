import SwiftData
import SwiftUI

@main
struct TunturiRunApp: App {
    @StateObject private var client = FitShowTreadmillClient()
    @StateObject private var runner = ProgramRunner()
    @StateObject private var recorder = SessionRecorder()
    @StateObject private var profileStore = ProfileStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(runner)
                .environmentObject(recorder)
                .environmentObject(profileStore)
        }
        .modelContainer(for: [WorkoutSessionRecord.self, WorkoutSampleRecord.self,
                              CustomProgram.self, CustomSegmentRecord.self])
    }
}
