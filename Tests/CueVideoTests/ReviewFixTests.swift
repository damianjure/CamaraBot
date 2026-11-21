import XCTest
@testable import CueVideo

final class ReviewFixTests: XCTestCase {
    func testNegativeContentLengthIsNotARequestAndDoesNotTrap() {
        let raw = Data("GET /cameras HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
        XCTAssertEqual(ControlServer.parse(raw)?.method, "")
    }

    func testHugeContentLengthIsRejected() {
        let raw = Data("POST /x HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n".utf8)
        XCTAssertEqual(ControlServer.parse(raw)?.method, "")
    }

    func testTallyMatchesTheExactNameNotASubstring() {
        let state = VMixState(inputs: [.init(number: 1, title: "PC (Cam 2)"), .init(number: 2, title: "PC (Cam)")],
                              active: 1, preview: nil)
        XCTAssertEqual(state.tally(ndiName: "Cam 2"), .program)
        XCTAssertNotEqual(state.tally(ndiName: "Cam"), .program)
    }

    func testOverlayCountsAsOnAir() {
        var state = VMixState(inputs: [.init(number: 1, title: "PC (Pulpit)"), .init(number: 2, title: "Slides")],
                              active: 2, preview: nil)
        state.overlays = [1]
        XCTAssertEqual(state.tally(ndiName: "Pulpit"), .program)
    }

    func testMaxZoomIsNotPartOfThePipeline() {
        var a = VirtualCamera(device: "d", ndiName: "n")
        let before = a.pipeline
        a.maxZoom = 3
        XCTAssertEqual(a.pipeline, before)
    }
}
