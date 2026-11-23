import XCTest
@testable import CueVideo

final class ShotDeckTests: XCTestCase {
    let cell = CGSize(width: 100, height: 80)

    func testDraggingDownARowLandsFiveSlotsOn() {
        var d = ShotDrag(camera: UUID(), page: 0, from: 1, range: 0...9, cell: cell)
        d.moved = CGSize(width: 10, height: 75)
        XCTAssertEqual(d.to, 6)
    }

    func testADropStaysInsideItsRun() {
        var d = ShotDrag(camera: UUID(), page: 0, from: 0, range: 0...3, cell: cell)
        d.moved = CGSize(width: 400, height: 80)
        XCTAssertEqual(d.to, 3)
    }

    func testTilesItPassesStepBackAcrossTheRowEnd() {
        var d = ShotDrag(camera: UUID(), page: 0, from: 2, range: 0...9, cell: cell)
        d.moved = CGSize(width: 0, height: 80)  // to slot 7
        XCTAssertEqual(d.to, 7)
        // Slot 5 (bottom left) steps up to slot 4 (top right).
        XCTAssertEqual(d.shift(5), CGSize(width: 400, height: -80))
        XCTAssertEqual(d.shift(3), CGSize(width: -100, height: 0))
        XCTAssertEqual(d.shift(8), .zero)
    }
}

final class HeadroomStepperTests: XCTestCase {
    func testStepsCountFromTheStandard() {
        XCTAssertEqual(HeadroomStepper.steps(eyeLine: 0.29, standard: 0.29), 0)
        XCTAssertEqual(HeadroomStepper.steps(eyeLine: 0.25, standard: 0.29), -2)
        XCTAssertEqual(HeadroomStepper.steps(eyeLine: 0.31, standard: 0.29), 1)
        XCTAssertEqual(HeadroomStepper.label(0), "Std")
        XCTAssertEqual(HeadroomStepper.label(1), "+1")
        XCTAssertEqual(HeadroomStepper.label(-2), "\u{2212}2")
    }
}
