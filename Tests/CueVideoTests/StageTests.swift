import XCTest
import CueATEM
@testable import CueVideo

/// Telling people apart: which person in a new frame is the one being followed.
final class IdentityMatchTests: XCTestCase {
    typealias C = IdentityMatch.Candidate
    let learned = IdentityMatch.Model(own: 0.2, others: 0.9)

    /// Two people cross. The other person is now nearer to where the followed one was, but
    /// the followed one still looks like themselves: stay with them.
    func testCrossingKeepsThePersonWhoLooksRight() {
        let people = [C(position: 0.03, appearance: 0.9), C(position: 0.12, appearance: 0.2)]
        XCTAssertEqual(IdentityMatch.choose(people, reach: 0.4, gone: 0.1, model: learned), .take(1, sure: true))
    }

    /// Two people who look alike (a band in black): carry on by position while they're in
    /// sight, without learning from it, and don't guess after a gap.
    func testLookAlikesFallBackToPositionThenWait() {
        let people = [C(position: 0.05, appearance: 0.50), C(position: 0.2, appearance: 0.55)]
        XCTAssertEqual(IdentityMatch.choose(people, reach: 0.4, gone: 0.1, model: learned), .take(0, sure: false))
        XCTAssertEqual(IdentityMatch.choose(people, reach: 0.4, gone: 2, model: learned), .wait)
    }

    /// The followed person walked off and someone else is standing where they were.
    func testAStrangerInTheGapIsNotPickedUp() {
        XCTAssertEqual(IdentityMatch.choose([C(position: 0.05, appearance: 0.85)], reach: 0.5, gone: 3, model: learned), .wait)
    }

    func testTheRightPersonComingBackIsPickedUp() {
        XCTAssertEqual(IdentityMatch.choose([C(position: 0.3, appearance: 0.3)], reach: 0.5, gone: 3, model: learned), .take(0, sure: true))
    }

    /// Too small to tell apart, or nothing learned yet: the nearest person, as before.
    func testWithoutLooksItFollowsTheNearest() {
        let people = [C(position: 0.3, appearance: nil), C(position: 0.1, appearance: nil)]
        XCTAssertEqual(IdentityMatch.choose(people, reach: 0.4, gone: 0.1, model: .init()), .take(1, sure: false))
        XCTAssertEqual(IdentityMatch.choose([C(position: 0.1, appearance: 0.4)], reach: 0.4, gone: 3, model: .init()), .take(0, sure: false))
    }

    func testNobodyWithinReachWaits() {
        XCTAssertEqual(IdentityMatch.choose([C(position: 0.6, appearance: 0.1)], reach: 0.4, gone: 0.1, model: learned), .wait)
        XCTAssertEqual(IdentityMatch.choose([], reach: 0.4, gone: 0.1, model: learned), .wait)
    }

    /// Before the others' look is known the limit is generous; never tighter than the measured floor.
    func testLimit() {
        XCTAssertNil(IdentityMatch.Model().limit)
        XCTAssertEqual(IdentityMatch.Model(own: 0.1).limit!, 0.6, accuracy: 0.001)
        XCTAssertEqual(IdentityMatch.Model(own: 0.2, others: 0.9).limit!, 0.55, accuracy: 0.001)
    }

    /// Following by name: the best fit, only if clearly better than the next person.
    func testFindingANamedPerson() {
        XCTAssertEqual(IdentityMatch.find([0.8, 0.3, 0.9]), 1)
        XCTAssertNil(IdentityMatch.find([0.5, 0.52]))
        XCTAssertEqual(IdentityMatch.find([nil]), 0)       // the only person in the shot
        XCTAssertNil(IdentityMatch.find([nil, nil]))
        XCTAssertNil(IdentityMatch.find([0.9, nil]))       // one unknown, one who looks wrong
        XCTAssertNil(IdentityMatch.find([]))
    }
}

/// Stage scan geometry: a place in a wide shot becomes where to point the camera.
final class ShotMathTests: XCTestCase {
    let rad = Double.pi / 180

    /// Where a point seen in `from` lands in the picture of `to`, and how big it is there.
    func project(_ p: CGPoint, from: ShotMath.View, to: ShotMath.View) -> CGPoint {
        let (right, up) = ShotMath.angles(p, fov: from.fov)
        let t = tan(to.fov / 2 * rad)
        return CGPoint(x: 0.5 + tan((right - (to.pan - from.pan)) * rad) / (2 * t),
                       y: 0.5 - tan((up - (to.tilt - from.tilt)) * rad) / (2 * t * 9 / 16))
    }

    func testThePersonLandsOnTheFramingMark() {
        let wide = ShotMath.View(pan: -3, tilt: 0, fov: 63.4)
        for eye in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.82, y: 0.61), CGPoint(x: 0.12, y: 0.4)] {
            let shot = ShotMath.shot(eye: eye, scale: 0.02, from: wide, eyeLine: 0.29, wantScale: 0.21)
            let landed = project(eye, from: wide, to: shot)
            XCTAssertEqual(landed.x, 0.5, accuracy: 0.02, "eyes should be centred left to right")
            XCTAssertEqual(landed.y, 0.29, accuracy: 0.02, "eyes should sit on the eye line")
            // Ten and a half times bigger: 0.02 of the frame becomes 0.21.
            XCTAssertEqual(0.02 * tan(wide.fov / 2 * rad) / tan(shot.fov / 2 * rad), 0.21, accuracy: 0.002)
        }
    }

    func testRightOfCentreMeansPanRightAndBelowMeansTiltDown() {
        let wide = ShotMath.View(pan: 0, tilt: 0, fov: 60)
        let shot = ShotMath.shot(eye: CGPoint(x: 0.75, y: 0.9), scale: 0.05, from: wide, eyeLine: 0.29, wantScale: 0.21)
        XCTAssertGreaterThan(shot.pan, 5)
        XCTAssertLessThan(shot.tilt, -5)
    }

    func testItStaysInsideWhatTheCameraCanDo() {
        let limits = ShotMath.Limits(fov: 5.7...73, pan: -170...170, tilt: -30...90)
        let far = ShotMath.shot(eye: CGPoint(x: 0.5, y: 0.5), scale: 0.004, from: .init(pan: 0, tilt: 0, fov: 73), eyeLine: 0.29, wantScale: 0.36, limits: limits)
        XCTAssertEqual(far.fov, 5.7, accuracy: 0.001, "can't zoom in past the lens")
        let low = ShotMath.shot(eye: CGPoint(x: 0.5, y: 0.99), scale: 0.05, from: .init(pan: 0, tilt: -25, fov: 73), eyeLine: 0.29, wantScale: 0.21, limits: limits)
        XCTAssertGreaterThanOrEqual(low.tilt, -30)
    }

    /// The camera's own report, as the booth's CR-N500 gives it.
    func testReadingACanonReport() throws {
        let text = "timestamp=267132.104\nc.1.zoom:=1962\nc.1.zoom.status:=0\nc.1.zoom.mode:=off\nc.1.zoom.limit.min:=570\nc.1.zoom.limit.max:=7300\nc.1.pan==-298\nc.1.pan.limit.min:=-17000\nc.1.pan.limit.max:=17000\nc.1.tilt:=-223\nc.1.tilt.limit.min:=-3000\nc.1.tilt.limit.max:=9000\n"
        let s = try XCTUnwrap(CanonState.parse(text))
        XCTAssertEqual(s.position, PTZPosition(pan: -298, tilt: -223, zoom: 1962))
        XCTAssertEqual(s.view.fov, 19.62, accuracy: 0.001)
        XCTAssertEqual(s.limits.fov, 5.7...73)
        XCTAssertEqual(s.limits.tilt, -30...90)
        XCTAssertNil(CanonState.parse("Error\n"))
    }

    /// A shot made by a scan is marked in the setup file; one made by hand isn't.
    func testScanShotsAreMarked() throws {
        var shot = PTZShot(name: "Keys", PTZPosition(pan: 1, tilt: 2, zoom: 3))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(shot), as: UTF8.self).contains("auto"))
        shot.auto = true
        let back = try JSONDecoder().decode(PTZShot.self, from: JSONEncoder().encode(shot))
        XCTAssertTrue(back.auto)
        XCTAssertEqual(back.position, shot.position)
    }
}

/// The Vision plumbing, on a drawn picture (no people): looks can be taken and compared,
/// and finding people in an empty picture finds none.
final class AppearanceTests: XCTestCase {
    func picture() -> CGImage {
        let w = 640, h = 360
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Left: red and white stripes. Right: a blue block with a yellow circle.
        for i in 0..<10 {
            ctx.setFillColor(i % 2 == 0 ? CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1) : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 60 + i * 12, y: 60, width: 12, height: 240))
        }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 420, y: 60, width: 120, height: 240))
        ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.1, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 440, y: 120, width: 80, height: 80))
        return ctx.makeImage()!
    }

    func testLooksCompare() throws {
        let img = picture()
        let left = CGRect(x: 60.0 / 640, y: 60.0 / 360, width: 120.0 / 640, height: 240.0 / 360)
        let right = CGRect(x: 420.0 / 640, y: 60.0 / 360, width: 120.0 / 640, height: 240.0 / 360)
        let a = try XCTUnwrap(Appearance.of(img, box: left))
        let nudged = try XCTUnwrap(Appearance.of(img, box: left.offsetBy(dx: 0.01, dy: 0.01)))
        let b = try XCTUnwrap(Appearance.of(img, box: right))
        let same = try XCTUnwrap(a.distance(to: nudged)), other = try XCTUnwrap(a.distance(to: b))
        XCTAssertLessThan(same, other * 0.8, "the same thing nudged should look far more alike than a different thing")
        XCTAssertNil(Appearance.of(img, box: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01)), "too small to tell")
    }

    func testNoPeopleInAnEmptyPicture() {
        XCTAssertTrue(AutoTracker.detect(picture()).isEmpty)
        XCTAssertNotNil(StageScan.thumb(picture(), CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.5)))
    }
}

/// Gestures don't move the camera: the edge alarm goes by head and torso, never an arm.
final class EdgeAlarmTests: XCTestCase {
    /// Standing in the middle with an arm stretched out to the side of the frame: the whole
    /// body's box reaches the edge, the head and torso don't.
    func testAnOutstretchedArmIsNotNearTheEdge() {
        let torso = CGRect(x: 0.42, y: 0.2, width: 0.16, height: 0.5)
        XCTAssertEqual(AutoTracker.edgeUrgency(core: torso, eyeX: 0.5, right: true), 0)
        let withArm = CGRect(x: 0.42, y: 0.2, width: 0.47, height: 0.5)
        XCTAssertGreaterThan(AutoTracker.edgeUrgency(core: withArm, eyeX: 0.5, right: true), 0)
    }

    func testATorsoNearTheEdgeStillAlarms() {
        let torso = CGRect(x: 0.78, y: 0.2, width: 0.16, height: 0.5)
        XCTAssertGreaterThan(AutoTracker.edgeUrgency(core: torso, eyeX: 0.86, right: true), 0.5)
        XCTAssertEqual(AutoTracker.edgeUrgency(core: torso, eyeX: 0.86, right: false), 0)
    }

    /// Walking right: the full lead, with them left of the middle and room ahead on the right.
    func testWalkingGetsTheFullLeadAhead() {
        XCTAssertEqual(AutoTracker.leadTarget(walkVX: 0.3, facing: 1, leadRoom: 0.11), -0.11, accuracy: 1e-9)
        XCTAssertEqual(AutoTracker.leadTarget(walkVX: -0.3, facing: 1, leadRoom: 0.11), 0.11, accuracy: 1e-9)
    }

    /// Standing at a music stand and turning to each side of the room only nudges the mark,
    /// so the shot doesn't swing a fifth of the frame every time they look the other way.
    func testStandingAndTurningOnlyNudges() {
        let left = AutoTracker.leadTarget(walkVX: 0, facing: -1, leadRoom: 0.11)
        let right = AutoTracker.leadTarget(walkVX: 0, facing: 1, leadRoom: 0.11)
        XCTAssertLessThan(abs(left - right), 0.08)
        XCTAssertEqual(AutoTracker.leadTarget(walkVX: 0, facing: 0, leadRoom: 0.11), 0)
    }

    /// Looking to one side with the shoulders still square to the camera is not a body turn.
    func testAHeadTurnAloneIsNotABodyTurn() {
        XCTAssertEqual(AutoTracker.bodyTurn(facing: 1, span: 1.7, square: 1.8), 0)
    }

    /// Shoulders narrowed and the head the same way: turned that way.
    func testNarrowShouldersAndHeadTogetherAreABodyTurn() {
        XCTAssertEqual(AutoTracker.bodyTurn(facing: -1, span: 1.0, square: 1.8), -1)
        // Narrow shoulders with no clear head direction (straight on, or away): unclear.
        XCTAssertEqual(AutoTracker.bodyTurn(facing: 0, span: 1.0, square: 1.8), 0)
        XCTAssertEqual(AutoTracker.bodyTurn(facing: 1, span: nil, square: 1.8), 0)
    }

    /// A move the way they're turned is confirmed sooner; against it, or square on, the usual wait.
    func testWalksTheWayTheyAreTurnedConfirmSooner() {
        XCTAssertEqual(AutoTracker.walkConfirm(direction: 1, bodyTurn: 1), 0.25)
        XCTAssertEqual(AutoTracker.walkConfirm(direction: -1, bodyTurn: 1), 0.5)
        XCTAssertEqual(AutoTracker.walkConfirm(direction: 1, bodyTurn: 0), 0.5)
    }

    /// Sureness of a walk builds over the rise time, and a moment's dip only dents it, so the
    /// camera doesn't drop speed every time the measured speed wobbles.
    func testABriefDipDoesNotEndAWalk() {
        var w = 0.0
        for _ in 0..<8 { w = AutoTracker.walkWeight(w, moving: 1, dt: 0.07, rise: 0.5) }
        XCTAssertEqual(w, 1, accuracy: 1e-9)
        w = AutoTracker.walkWeight(w, moving: 0, dt: 0.07, rise: 0.5)
        XCTAssertGreaterThan(w, 0.8)
        // Moving the other way first fades the old walk to nothing, never flips straight over.
        for _ in 0..<20 { w = AutoTracker.walkWeight(w, moving: -1, dt: 0.07, rise: 0.5) }
        XCTAssertLessThanOrEqual(w, 0)
    }

    /// Asked to go from slow to fast at once, the camera eases up over several frames.
    func testSpeedUpsAreEased() {
        var r = 0.1
        r = AutoTracker.easeRate(from: r, to: 0.8, dt: 0.07, urgent: false, speed: 0.5)
        XCTAssertLessThan(r, 0.25)
        for _ in 0..<15 { r = AutoTracker.easeRate(from: r, to: 0.8, dt: 0.07, urgent: false, speed: 0.5) }
        XCTAssertEqual(r, 0.8, accuracy: 0.05)
    }

    /// Zoomed in tight, a small correction still moves the camera at its slowest speed;
    /// settled, the same small amount is no move at all.
    func testSmallCorrectionsStillMoveWhenCorrecting() {
        XCTAssertEqual(AutoTracker.cameraSpeed(raw: 8, correcting: true), 20)
        XCTAssertEqual(AutoTracker.cameraSpeed(raw: -8, correcting: true), -20)
        XCTAssertEqual(AutoTracker.cameraSpeed(raw: 8, correcting: false), 0)
        XCTAssertEqual(AutoTracker.cameraSpeed(raw: 0.4, correcting: true), 0)
        XCTAssertEqual(AutoTracker.cameraSpeed(raw: 1234, correcting: false), 1230)
    }
}
