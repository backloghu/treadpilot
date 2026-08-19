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
}
