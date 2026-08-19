import XCTest
@testable import TunturiRun

final class ProgramRunnerTests: XCTestCase {

    private let program = WorkoutProgram(name: "Teszt", segments: [
        WorkoutSegment(name: "Bemelegítés", duration: 180, targetSpeedKmh: 5.0, targetIncline: 0),
        WorkoutSegment(name: "Gyors", duration: 60, targetSpeedKmh: 9.0, targetIncline: 2),
        WorkoutSegment(name: "Levezetés", duration: 120, targetSpeedKmh: 4.0, targetIncline: 0),
    ])

    func testProgramRemainingSumsCurrentAndFutureSegments() {
        // Az első szakaszból 100 mp van hátra + 60 + 120 a további kettő.
        XCTAssertEqual(ProgramRunner.programRemainingSeconds(in: program, segmentIndex: 0,
                                                             segmentRemaining: 100), 280)
        // Az utolsó szakaszban csak a maradék számít.
        XCTAssertEqual(ProgramRunner.programRemainingSeconds(in: program, segmentIndex: 2,
                                                             segmentRemaining: 45), 45)
    }

    func testNextSegmentLookup() {
        XCTAssertEqual(ProgramRunner.nextSegment(in: program, after: 0)?.name, "Gyors")
        XCTAssertEqual(ProgramRunner.nextSegment(in: program, after: 1)?.name, "Levezetés")
        XCTAssertNil(ProgramRunner.nextSegment(in: program, after: 2))
    }

    func testProgramSummaryComputations() {
        // 600 mp @ 6 km/h @ 5% + 300 mp @ 12 km/h @ 0%:
        // táv: 1,0 + 1,0 = 2,0 km; szint: 600 × 1,6667 × 0,05 = 50 m;
        // átlag: 2,0 km / 0,25 h = 8,0 km/h.
        let program = WorkoutProgram(name: "Összesítés", segments: [
            WorkoutSegment(name: "A", duration: 600, targetSpeedKmh: 6.0, targetIncline: 5),
            WorkoutSegment(name: "B", duration: 300, targetSpeedKmh: 12.0, targetIncline: 0),
        ])
        XCTAssertEqual(program.totalDistanceKm, 2.0, accuracy: 0.001)
        XCTAssertEqual(program.totalElevationGainM, 50.0, accuracy: 0.1)
        XCTAssertEqual(program.averageSpeedKmh, 8.0, accuracy: 0.001)
        XCTAssertEqual(program.totalDuration, 900)
    }
}
