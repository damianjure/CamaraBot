import XCTest
import NDIBridge
import CoreGraphics
import AVFoundation
import CoreVideo
@testable import CueVideo

/// The virtual PTZ: where the crop goes for a person, how it moves, and how it is set up.
final class CropPlannerTests: XCTestCase {
    let waist = Framing(ShotSize.waist.standard)

    // MARK: Zoom limit by resolution

    func testMaxZoomFollowsInputAndOutputResolution() {
        XCTAssertEqual(CropPlanner.maxZoom(inputHeight: 2160, outputHeight: 1080), 2.5, accuracy: 1e-9)
        XCTAssertEqual(CropPlanner.maxZoom(inputHeight: 2160, outputHeight: 720), 3.75, accuracy: 1e-9)
        XCTAssertEqual(CropPlanner.maxZoom(inputHeight: 1080, outputHeight: 1080), 1.25, accuracy: 1e-9)
        XCTAssertEqual(CropPlanner.maxZoom(inputHeight: 1080, outputHeight: 720), 1.875, accuracy: 1e-9)
        XCTAssertEqual(CropPlanner.maxZoom(inputHeight: 0, outputHeight: 1080), 1)
    }

    // MARK: Framing

    /// A waist shot from a 4K picture: the crop height makes the head the size the rule asks for,
    /// the eyes sit on the eye line, and the person is centered.
    func testWaistShotPutsEyesOnTheLineAndCentersThem() {
        let p = CropPlanner(maxZoom: 2.5)
        var f = CropFollow(planner: p)
        f.update(eye: CGPoint(x: 0.5, y: 0.4), scale: 0.12, lead: 0, framing: waist, planner: p)
        let g = f.goal
        XCTAssertEqual(g.h, 0.12 / 0.21, accuracy: 1e-9)
        XCTAssertEqual(g.w, g.h, accuracy: 1e-9)                       // 16:9 crop of a 16:9 picture
        XCTAssertEqual((0.4 - g.y) / g.h, waist.eyeLine, accuracy: 1e-9)
        XCTAssertEqual((0.5 - g.x) / g.w, 0.5, accuracy: 1e-9)
        XCTAssertFalse(f.limited)
    }

    func testCropStaysInsideThePicture() {
        let p = CropPlanner(maxZoom: 2.5)
        var f = CropFollow(planner: p)
        f.update(eye: CGPoint(x: 0.04, y: 0.1), scale: 0.12, lead: 0, framing: waist, planner: p)
        XCTAssertEqual(f.goal.x, 0, accuracy: 1e-9)
        XCTAssertEqual(f.goal.y, 0, accuracy: 1e-9)
        f = CropFollow(planner: p)
        f.update(eye: CGPoint(x: 0.97, y: 0.95), scale: 0.12, lead: 0, framing: waist, planner: p)
        XCTAssertEqual(f.goal.x + f.goal.w, 1, accuracy: 1e-9)
        XCTAssertEqual(f.goal.y + f.goal.h, 1, accuracy: 1e-9)
    }

    /// Asked for a tighter shot than the picture can give: hold the tightest allowed and say so.
    func testZoomLimitHoldsTheTightestCropAndFlagsIt() {
        let p = CropPlanner(maxZoom: 2.5)
        var f = CropFollow(planner: p)
        f.update(eye: CGPoint(x: 0.5, y: 0.4), scale: 0.05, lead: 0, framing: waist, planner: p)
        XCTAssertEqual(f.goal.h, 0.4, accuracy: 1e-9)
        XCTAssertTrue(f.limited)
    }

    /// 1080p in and out has almost no room: the same person is held at the tighter limit sooner.
    func testALowResolutionInputLimitsTheZoomMoreThanA4KInput() {
        let k4 = CropPlanner(maxZoom: CropPlanner.maxZoom(inputHeight: 2160, outputHeight: 1080))
        let hd = CropPlanner(maxZoom: CropPlanner.maxZoom(inputHeight: 1080, outputHeight: 1080))
        XCTAssertLessThan(k4.minHeight, hd.minHeight)
        XCTAssertEqual(hd.minHeight, 0.8, accuracy: 1e-9)
    }

    /// Facing right leaves room on the right: the eyes sit left of the middle of the crop.
    func testLeadRoomLeavesSpaceWhereTheyAreLooking() {
        let p = CropPlanner(maxZoom: 2.5)
        var f = CropFollow(planner: p)
        f.update(eye: CGPoint(x: 0.5, y: 0.4), scale: 0.12, lead: -0.11, framing: waist, planner: p)
        let across = (0.5 - f.goal.x) / f.goal.w
        XCTAssertEqual(across, 0.39, accuracy: 1e-9)
    }

    func testANarrowerPictureThanTheOutputNeverCropsWiderThanItself() {
        let p = CropPlanner(sourceAspect: 4.0 / 3, maxZoom: 2)
        XCTAssertEqual(p.fullRect.w, 1, accuracy: 1e-9)
        XCTAssertEqual(p.fullRect.h, 0.75, accuracy: 1e-9)
        XCTAssertEqual(p.rect(x: 0, y: 0, height: 1).h, 0.75, accuracy: 1e-9)
    }

    // MARK: Dead zone

    func testTheCropStaysPutWhileThePersonStaysInTheDeadZone() {
        let p = CropPlanner(maxZoom: 2.5)
        var f = CropFollow(planner: p)
        f.update(eye: CGPoint(x: 0.5, y: 0.4), scale: 0.12, lead: 0, framing: waist, planner: p)
        let held = f.goal
        // A shift of weight: well inside the dead zone (7% of the crop's width).
        f.update(eye: CGPoint(x: 0.5 + held.w * 0.03, y: 0.4), scale: 0.12, lead: 0, framing: waist, planner: p)
        XCTAssertEqual(f.goal, held)
        // A real step: outside it. The crop re-centers on them, then holds again.
        f.update(eye: CGPoint(x: 0.5 + held.w * 0.2, y: 0.4), scale: 0.12, lead: 0, framing: waist, planner: p)
        XCTAssertNotEqual(f.goal, held)
        XCTAssertEqual((0.5 + held.w * 0.2 - f.goal.x) / f.goal.w, 0.5, accuracy: 1e-9)
    }

    /// Breathing and nodding change the measured size a little: the zoom doesn't move.
    func testSmallSizeChangesDoNotZoom() {
        let p = CropPlanner(maxZoom: 2.5)
        var f = CropFollow(planner: p)
        f.update(eye: CGPoint(x: 0.5, y: 0.4), scale: 0.12, lead: 0, framing: waist, planner: p)
        let h = f.goal.h
        f.update(eye: CGPoint(x: 0.5, y: 0.4), scale: 0.12 * 1.08, lead: 0, framing: waist, planner: p)
        XCTAssertEqual(f.goal.h, h, accuracy: 1e-9)
        f.update(eye: CGPoint(x: 0.5, y: 0.4), scale: 0.12 * 1.5, lead: 0, framing: waist, planner: p)
        XCTAssertNotEqual(f.goal.h, h)
    }

    // MARK: Motion

    func testTheSpringArrivesWithoutOvershootingAndIsSmoothBetweenDetections() {
        let p = CropPlanner(maxZoom: 2.5)
        let m = CropMotion(planner: p)
        _ = m.advance(to: 0)
        m.setGoal(CropRect(x: 0.4, y: 0.2, w: 0.5, h: 0.5))
        var last = 0.0, t = 0.0
        var steps: [Double] = []
        for _ in 0..<300 {                        // five seconds at 60 frames a second (a zoom takes about three)
            t += 1.0 / 60
            let r = m.advance(to: t)
            XCTAssertLessThanOrEqual(r.x, 0.4 + 1e-9, "never passes the goal")
            XCTAssertGreaterThanOrEqual(r.x, last - 1e-12, "never goes back")
            steps.append(r.x - last)
            last = r.x
        }
        XCTAssertEqual(last, 0.4, accuracy: 0.001)
        XCTAssertEqual(m.advance(to: t + 0.016).h, 0.5, accuracy: 0.001)
        // No jump: the biggest step is a small share of the whole move.
        XCTAssertLessThan(steps.max()!, 0.4 * 0.05)
    }

    func testACutJumpsAtOnceAndAStallDoesNotMakeTheCropJump() {
        let p = CropPlanner(maxZoom: 2.5)
        let m = CropMotion(planner: p)
        _ = m.advance(to: 0)
        m.setGoal(CropRect(x: 0.3, y: 0.3, w: 0.4, h: 0.4), cut: true)
        XCTAssertEqual(m.advance(to: 0.001).x, 0.3, accuracy: 1e-3)
        m.setGoal(CropRect(x: 0.6, y: 0.3, w: 0.4, h: 0.4))
        // The picture dropped out for ten seconds: it moves as one short step, not all the way.
        XCTAssertLessThan(m.advance(to: 10.0).x, 0.45)
    }

    // MARK: Picking and keeping the person

    func testTheCropFollowsThePersonNearestTheMiddleThenLeavesThemWhenTheyAreGoneAWhile() {
        let p = CropPlanner(maxZoom: 2.5)
        var v = VirtualFollow(planner: p, framing: waist)
        func person(_ x: Double) -> TrackedPerson {
            TrackedPerson(box: CGRect(x: x - 0.03, y: 0.3, width: 0.06, height: 0.3), eye: CGPoint(x: x, y: 0.35), scale: 0.06)
        }
        let t0 = Date()
        // Two people: the one nearest the middle is picked.
        v.update(people: [person(0.15), person(0.55)], now: t0)
        XCTAssertEqual(v.phase, .following)
        XCTAssertEqual(v.target?.eye.x ?? 0, 0.55, accuracy: 1e-9)
        // They are followed and the crop is a close shot around them, not the whole picture.
        XCTAssertLessThan(v.goal.h, 1)
        XCTAssertEqual(v.goal.x + v.goal.w / 2, 0.55, accuracy: 0.05)
        // No one in the picture: it holds, then eases out to the whole picture.
        let held = v.goal
        v.update(people: [], now: t0.addingTimeInterval(1))
        XCTAssertEqual(v.phase, .searching)
        XCTAssertEqual(v.goal, held)
        v.update(people: [], now: t0.addingTimeInterval(5))
        XCTAssertEqual(v.phase, .lost)
        XCTAssertEqual(v.goal, p.fullRect)
        // They come back: followed again.
        v.update(people: [person(0.6)], now: t0.addingTimeInterval(6))
        XCTAssertEqual(v.phase, .following)
        XCTAssertLessThan(v.goal.h, 1)
    }
}

/// The setup file: virtual cameras are optional, so older files keep loading.
final class VirtualCameraConfigTests: XCTestCase {
    func testAnOldSetupFileWithoutVirtualCamerasLoads() throws {
        let c = try JSONDecoder().decode(CueConfig.self, from: Data(#"{"atemHost":"10.0.0.2"}"#.utf8))
        XCTAssertEqual(c.virtualCameras, [])
        XCTAssertEqual(c.atemHost, "10.0.0.2")
    }

    func testAVirtualCameraNeedsOnlyItsDeviceAndTheRestTakesDefaults() throws {
        let json = #"{"virtualCameras":[{"device":"0x1234","ndiName":"Pulpit Tracked"}]}"#
        let c = try JSONDecoder().decode(CueConfig.self, from: Data(json.utf8))
        XCTAssertEqual(c.virtualCameras.count, 1)
        let v = c.virtualCameras[0]
        XCTAssertEqual(v.device, "0x1234")
        XCTAssertEqual(v.ndiName, "Pulpit Tracked")
        XCTAssertEqual(v.output, .p1080)
        XCTAssertEqual(v.shot, .waist)
        XCTAssertNil(v.maxZoom)
        XCTAssertEqual(v.shots, [])
    }

    func testVirtualCamerasSurviveBeingWrittenBackToTheFile() throws {
        var c = CueConfig()
        var v = VirtualCamera(name: "Pulpit", device: "abc", ndiName: "Pulpit Tracked")
        v.output = .p720
        v.maxZoom = 3
        v.shots = [CropShot(name: "Lectern", crop: CropRect(x: 0.1, y: 0.1, w: 0.4, h: 0.4))]
        c.virtualCameras = [v]
        let back = try JSONDecoder().decode(CueConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.virtualCameras, [v])
    }
}

/// The picture itself: a crop of a 4K frame comes out as the right part, the right way up, at
/// the output size.
final class VirtualOutputTests: XCTestCase {
    /// A 4K frame in four colored quarters: red top left, green top right, blue bottom left, white bottom right.
    func quarters(_ w: Int = 3840, _ h: Int = 2160) -> CVPixelBuffer {
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buf)
        let b = buf!
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<h {
            for x in 0..<w {
                let top = y < h / 2, left = x < w / 2
                let (r, g, bl): (UInt8, UInt8, UInt8) = top ? (left ? (255, 0, 0) : (0, 255, 0)) : (left ? (0, 0, 255) : (255, 255, 255))
                let p = base + y * stride + x * 4
                p[0] = bl; p[1] = g; p[2] = r; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        return b
    }

    /// The color at a share of the way across and down a buffer, as (r, g, b).
    func pixel(_ b: CVPixelBuffer, _ fx: Double, _ fy: Double) -> (Int, Int, Int) {
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
        let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            + Int(fy * Double(h - 1)) * CVPixelBufferGetBytesPerRow(b) + Int(fx * Double(w - 1)) * 4
        return (Int(p[2]), Int(p[1]), Int(p[0]))
    }

    func testEachCornerOfTheFrameComesOutTheRightWayUp() {
        let out = VirtualOutput(name: "test", size: .p1080)
        let frame = quarters()
        // 0.4 x 0.4 crops (zoomed 2.5×) wholly inside each quarter.
        let cases: [(CropRect, (Int, Int, Int))] = [
            (CropRect(x: 0.05, y: 0.05, w: 0.4, h: 0.4), (255, 0, 0)),
            (CropRect(x: 0.55, y: 0.05, w: 0.4, h: 0.4), (0, 255, 0)),
            (CropRect(x: 0.05, y: 0.55, w: 0.4, h: 0.4), (0, 0, 255)),
            (CropRect(x: 0.55, y: 0.55, w: 0.4, h: 0.4), (255, 255, 255)),
        ]
        for (crop, color) in cases {
            guard let b = out.compose(frame, crop) else { return XCTFail("nothing rendered for \(crop)") }
            XCTAssertEqual(CVPixelBufferGetWidth(b), 1920)
            XCTAssertEqual(CVPixelBufferGetHeight(b), 1080)
            for (fx, fy) in [(0.1, 0.1), (0.9, 0.1), (0.5, 0.5), (0.1, 0.9), (0.9, 0.9)] {
                let p = pixel(b, fx, fy)
                XCTAssertEqual(p.0, color.0, accuracy: 3, "red at \(fx),\(fy) for \(crop)")
                XCTAssertEqual(p.1, color.1, accuracy: 3, "green at \(fx),\(fy) for \(crop)")
                XCTAssertEqual(p.2, color.2, accuracy: 3, "blue at \(fx),\(fy) for \(crop)")
            }
        }
    }

    /// A crop straddling the middle shows both halves, in their real places.
    func testACropAcrossTheMiddleKeepsTheLayout() {
        let out = VirtualOutput(name: "test", size: .p720)
        guard let b = out.compose(quarters(), CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)) else { return XCTFail("nothing rendered") }
        XCTAssertEqual(CVPixelBufferGetWidth(b), 1280)
        XCTAssertEqual(pixel(b, 0.25, 0.25).0, 255)                       // top left is red
        XCTAssertEqual(pixel(b, 0.75, 0.25).1, 255)                       // top right is green
        XCTAssertEqual(pixel(b, 0.25, 0.75).2, 255)                       // bottom left is blue
        XCTAssertEqual(pixel(b, 0.75, 0.75).0, 255); XCTAssertEqual(pixel(b, 0.75, 0.75).2, 255)  // bottom right is white
    }

    /// 1080p in, 1080p out, no crop: the picture passes through unchanged.
    func testTheWholeOfAnHDFrameIsNotScaled() {
        let out = VirtualOutput(name: "test", size: .p1080)
        guard let b = out.compose(quarters(1920, 1080), .full) else { return XCTFail("nothing rendered") }
        XCTAssertEqual(pixel(b, 0.25, 0.25).0, 255)
        XCTAssertEqual(pixel(b, 0.75, 0.75).1, 255)
    }
}

/// Saving a shot, renaming or reframing must never reopen the capture or the NDI output, which may be on air.
final class VirtualCameraPipelineTests: XCTestCase {
    func testOnlyWhatReopensTheCaptureOrOutputChangesThePipeline() {
        let base = VirtualCamera(name: "Pulpit", device: "abc", ndiName: "Pulpit Tracked")
        var same = base
        same.name = "Renamed"
        same.shotSize = "full"
        same.shots = [CropShot(name: "Lectern", crop: .full)]
        same.atemInput = 4
        XCTAssertEqual(same.pipeline, base.pipeline)
        for change: (inout VirtualCamera) -> Void in [
            { $0.device = "other" }, { $0.inputFormat = "1920x1080" }, { $0.output = .p720 }, { $0.ndiName = "Other" }, { $0.maxZoom = 2 },
        ] {
            var c = base
            change(&c)
            XCTAssertNotEqual(c.pipeline, base.pipeline)
        }
    }
}

/// The running virtual camera's steering, with no capture device and no NDI: it is never started.
final class VirtualCameraRuntimeTests: XCTestCase {
    func makeRuntime() -> VirtualCameraRuntime {
        VirtualCameraRuntime(VirtualCamera(name: "Pulpit", device: "none", ndiName: "Test Pulpit"), config: CueConfig())
    }

    /// Steered before the first frame arrives (the size isn't known yet): the first frame doesn't undo it.
    func testTheFirstFrameKeepsAModeSetBeforeIt() {
        let r = makeRuntime()
        r.wide()
        r.ensureGeometry(3840, 2160)
        XCTAssertEqual(r.currentMode, .wide)
        let crop = CropRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4)
        let r2 = makeRuntime()
        r2.go(to: CropShot(name: "Lectern", crop: crop))
        r2.ensureGeometry(3840, 2160)
        XCTAssertEqual(r2.currentMode, .shot(crop))
    }

    /// A new input format (a different cable, a different camera setting) starts again from following.
    func testANewInputFormatStartsAgainFromFollowing() {
        let r = makeRuntime()
        r.ensureGeometry(3840, 2160)
        r.hold()
        XCTAssertEqual(r.currentMode, .hold)
        r.ensureGeometry(1920, 1080)
        XCTAssertEqual(r.currentMode, .follow)
    }

    /// The zoom limit comes from the real picture size: 4K gives more room than 1080p.
    func testTheZoomLimitComesFromTheRealPictureSize() {
        let r = makeRuntime()
        r.ensureGeometry(3840, 2160)
        XCTAssertEqual(r.status().maxZoom ?? 0, 2.5, accuracy: 1e-9)
        r.ensureGeometry(1920, 1080)
        XCTAssertEqual(r.status().maxZoom ?? 0, 1.25, accuracy: 1e-9)
    }

    /// Saving a shot or reframing changes the setup but not the mode or the crop it is in.
    func testASetupUpdateKeepsTheModeAndTheCrop() {
        let r = makeRuntime()
        r.ensureGeometry(3840, 2160)
        r.wide()
        var cam = r.camera
        cam.shots = [CropShot(name: "Lectern", crop: CropRect(x: 0.1, y: 0.1, w: 0.4, h: 0.4))]
        cam.shotSize = "full"
        let before = r.status().crop
        r.update(cam, config: CueConfig())
        XCTAssertEqual(r.currentMode, .wide)
        XCTAssertEqual(r.status().crop, before)
        XCTAssertEqual(r.camera.shots.count, 1)
        XCTAssertEqual(r.shot, .full)
    }
}

/// The on and off switch in Setup.
final class VirtualCameraSwitchTests: XCTestCase {
    func testAVirtualCameraIsOnUnlessTheFileSaysOff() throws {
        let on = try JSONDecoder().decode(VirtualCamera.self, from: Data(#"{"device":"a","ndiName":"A"}"#.utf8))
        XCTAssertTrue(on.enabled)
        let off = try JSONDecoder().decode(VirtualCamera.self, from: Data(#"{"device":"a","ndiName":"A","enabled":false}"#.utf8))
        XCTAssertFalse(off.enabled)
        XCTAssertEqual(try JSONDecoder().decode(VirtualCamera.self, from: JSONEncoder().encode(off)), off)
    }
}

final class VirtualHealthTests: XCTestCase {
    private func status(live: Bool = true, problem: String? = nil, out: Bool = true, sent: Int = 1000, dropped: Int = 0,
                        missing: Bool = false) -> VirtualCameraRuntime.Status {
        VirtualCameraRuntime.Status(name: "A", ndiName: "A", input: "1920x1080 @ 50.00", captureLive: live, problem: problem,
                                    outputLive: out, sent: sent, dropped: dropped, recentSent: sent, recentDropped: dropped, runtimeMissing: missing, mode: "follow",
                                    shot: "waist", phase: "following", zoomLimited: false, maxZoom: 1.25, crop: .full)
    }

    func testHealthyCameraHasNoProblems() {
        XCTAssertEqual(VirtualHealth.problems(status(), age: 60), [])
    }

    func testNothingIsReportedDuringTheFirstMoments() {
        XCTAssertEqual(VirtualHealth.problems(status(live: false, out: false), age: 1), [])
    }

    func testALostPictureIsReportedWithItsReason() {
        XCTAssertEqual(VirtualHealth.problems(status(live: false, problem: "Device disconnected", out: false), age: 30), ["Device disconnected"])
        XCTAssertEqual(VirtualHealth.problems(status(live: false), age: 30), ["no picture from the capture device"])
    }

    func testNDIOutputProblems() {
        XCTAssertEqual(VirtualHealth.problems(status(out: false), age: 30), ["not sending over NDI"])
        XCTAssertEqual(VirtualHealth.problems(status(out: false, missing: true), age: 30), ["NDI isn't installed on this Mac"])
    }

    func testDroppedFramesAreReportedOnlyOnceEnoughHaveGoneOut() {
        XCTAssertEqual(VirtualHealth.problems(status(sent: 1000, dropped: 100), age: 30), ["dropping frames (10%)"])
        XCTAssertEqual(VirtualHealth.problems(status(sent: 100, dropped: 50), age: 30), [])
        XCTAssertEqual(VirtualHealth.problems(status(sent: 1000, dropped: 40), age: 30), [])
    }
}

final class CaptureDeviceMatchTests: XCTestCase {
    private let list = [(id: "0xA", name: "ZV-E10M2"), (id: "0xB", name: "Cam Link 4K")]

    func testTheSavedIDWins() {
        XCTAssertEqual(CaptureFeed.resolve(id: "0xA", name: "Cam Link 4K", among: list), "0xA")
    }

    func testAChangedIDFallsBackToTheOneDeviceWithThatName() {
        XCTAssertEqual(CaptureFeed.resolve(id: "0xZ", name: "ZV-E10M2", among: list), "0xA")
    }

    func testNothingIsGuessedWithoutAName() {
        XCTAssertNil(CaptureFeed.resolve(id: "0xZ", name: nil, among: list))
        XCTAssertNil(CaptureFeed.resolve(id: "0xZ", name: "", among: list))
        XCTAssertNil(CaptureFeed.resolve(id: "0xZ", name: "Unknown", among: list))
    }

    func testTwoDevicesWithTheSameNameAreNotGuessed() {
        let twins = [(id: "0xA", name: "Cam Link 4K"), (id: "0xB", name: "Cam Link 4K")]
        XCTAssertNil(CaptureFeed.resolve(id: "0xZ", name: "Cam Link 4K", among: twins))
    }

    func testTheDeviceNameIsKeptInTheSetup() throws {
        var cam = VirtualCamera(device: "0xA", ndiName: "n")
        cam.deviceName = "ZV-E10M2"
        let back = try JSONDecoder().decode(VirtualCamera.self, from: JSONEncoder().encode(cam))
        XCTAssertEqual(back.deviceName, "ZV-E10M2")
        XCTAssertNil(try JSONDecoder().decode(VirtualCamera.self, from: Data(#"{"device":"0xA","ndiName":"n"}"#.utf8)).deviceName)
    }
}

final class DropWindowTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testItCountsOnlyWhatHappenedWithinTheWindow() {
        var w = DropWindow()
        // A burst of drops at the start...
        _ = w.add(now: t0, sent: 0, dropped: 0)
        _ = w.add(now: t0.addingTimeInterval(5), sent: 300, dropped: 150)
        // ...then a long healthy run: once the window has moved past the burst it no longer counts.
        var last = (sent: 0, dropped: 0)
        for s in stride(from: 10, through: 120, by: 5) {
            last = w.add(now: t0.addingTimeInterval(Double(s)), sent: 300 + (s - 5) * 50, dropped: 150)
        }
        XCTAssertEqual(last.dropped, 0)
        XCTAssertGreaterThan(last.sent, 1000)
    }

    func testANewProblemShowsUpAfterALongHealthyRun() {
        var w = DropWindow()
        for s in 0...100 { _ = w.add(now: t0.addingTimeInterval(Double(s)), sent: s * 50, dropped: 0) }
        var last = (sent: 0, dropped: 0)
        for s in 101...130 { last = w.add(now: t0.addingTimeInterval(Double(s)), sent: s * 50, dropped: (s - 100) * 10) }
        XCTAssertGreaterThan(Double(last.dropped) / Double(last.sent), VirtualHealth.dropShare)
    }

    func testRestartedCountersStartAgain() {
        var w = DropWindow()
        _ = w.add(now: t0, sent: 5000, dropped: 400)
        let r = w.add(now: t0.addingTimeInterval(1), sent: 10, dropped: 0)
        XCTAssertEqual(r.sent, 0)
        XCTAssertEqual(r.dropped, 0)
    }
}

final class CaptureFeedHubTests: XCTestCase {
    func testTheSameDeviceSharesOneFeedAndLearnsItsName() {
        let hub = CaptureFeedHub()
        let a = hub.feed("no-such-device")
        let b = hub.feed("no-such-device", name: "ZV-E10M2")
        XCTAssertTrue(a === b)
        XCTAssertEqual(a.deviceName, "ZV-E10M2")
    }

    func testAnotherDeviceGetsItsOwnFeed() {
        let hub = CaptureFeedHub()
        XCTAssertFalse(hub.feed("no-such-device-1") === hub.feed("no-such-device-2"))
    }
}

final class VirtualCameraSmallPartsTests: XCTestCase {
    func testAShotNameIsReadInAnyCase() {
        XCTAssertEqual(ShotSize.named("Waist"), .waist)
        XCTAssertEqual(ShotSize.named(" SHOULDERS "), .shoulders)
        XCTAssertEqual(ShotSize.named("full"), .full)
        XCTAssertNil(ShotSize.named("closeup"))
    }

    func testFourKIsDecidedByTheHeightNotTheText() {
        XCTAssertEqual(CaptureFeed.height(of: "3840x2160"), 2160)
        XCTAssertEqual(CaptureFeed.height(of: "4096x2160"), 2160)
        XCTAssertEqual(CaptureFeed.height(of: "1920x1080"), 1080)
        XCTAssertEqual(CaptureFeed.height(of: "nonsense"), 0)
    }

    func testTheManualZoomStartsAtTheAutomaticFourKLimit() {
        XCTAssertEqual(VirtualCamera.manualZoomDefault, 2.5, accuracy: 0.001)
        XCTAssertTrue(VirtualCamera.manualZoomRange.contains(VirtualCamera.manualZoomDefault))
    }
}

final class NDIInputTests: XCTestCase {
    func testAnNDISourceNeedsNoDeviceInTheSetup() throws {
        let cam = try JSONDecoder().decode(VirtualCamera.self, from: Data(#"{"ndiSource":"PC (vMix - Cam)","ndiName":"Tracked"}"#.utf8))
        XCTAssertEqual(cam.inputSource, "PC (vMix - Cam)")
        XCTAssertEqual(cam.device, "")
        let back = try JSONDecoder().decode(VirtualCamera.self, from: JSONEncoder().encode(cam))
        XCTAssertEqual(back.ndiSource, "PC (vMix - Cam)")
    }

    func testAnEmptySourceMeansTheCaptureDevice() {
        var cam = VirtualCamera(device: "0xA", ndiName: "n")
        cam.ndiSource = ""
        XCTAssertNil(cam.inputSource)
    }

    func testChangingTheInputReopensThePipeline() {
        var a = VirtualCamera(device: "0xA", ndiName: "n")
        let before = a.pipeline
        a.ndiSource = "PC (vMix)"
        XCTAssertNotEqual(a.pipeline, before)
    }

    func testACameraTakingItsOwnOutputIsCaught() {
        var cam = VirtualCamera(device: "", ndiName: "Tracked")
        cam.ndiSource = "MAC (Tracked)"
        XCTAssertTrue(cam.inputIsOwnOutput)
        cam.ndiSource = "mac-2.local (tracked)"
        XCTAssertTrue(cam.inputIsOwnOutput)
        cam.ndiSource = "PC (vMix - Cam 1)"
        XCTAssertFalse(cam.inputIsOwnOutput)
        cam.ndiSource = "no channel"
        XCTAssertFalse(cam.inputIsOwnOutput)
    }

    func testARunningCameraFedByItsOwnOutputStaysClosedAndSaysWhy() {
        var cam = VirtualCamera(device: "", ndiName: "Tracked")
        cam.ndiSource = "MAC (Tracked)"
        let r = VirtualCameraRuntime(cam, config: CueConfig())
        r.start()
        let s = r.status()
        XCTAssertFalse(s.captureLive)
        XCTAssertTrue(s.problem?.contains("own NDI output") ?? false)
        r.stop()
    }

    func testFramesAreCopiedRowByRowWhateverTheStride() throws {
        // 3x2 pixels in rows of 16 bytes: 12 of picture and 4 of padding that must not come across.
        var src = [UInt8](repeating: 0xEE, count: 32)
        for row in 0..<2 { for i in 0..<12 { src[row * 16 + i] = UInt8(row * 12 + i + 1) } }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_32BGRA, nil, &buffer)
        let b = try XCTUnwrap(buffer)
        XCTAssertTrue(src.withUnsafeBufferPointer { NDIInputFeed.fill(b, from: $0.baseAddress!, 3, 2, 16) })
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(b)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(b)
        for row in 0..<2 { for i in 0..<12 { XCTAssertEqual(base[row * stride + i], UInt8(row * 12 + i + 1)) } }
    }

    func testAFrameWithATooSmallStrideIsRefused() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 1, kCVPixelFormatType_32BGRA, nil, &buffer)
        let src = [UInt8](repeating: 0, count: 16)
        XCTAssertFalse(src.withUnsafeBufferPointer { NDIInputFeed.fill(try! XCTUnwrap(buffer), from: $0.baseAddress!, 4, 1, 8) })
    }
}

/// Sends a picture over the real NDI runtime and takes it in again, when the runtime is installed.
final class NDIInputLoopbackTests: XCTestCase {
    func testAPictureSentOverNDIArrivesAsAFullSizePixelBuffer() throws {
        guard ndi_load() != nil else { throw XCTSkip("The NDI runtime isn't installed.") }
        let channel = "CueVideoLoopback\(Int.random(in: 1000...9999))"
        guard let send = ndi_send_open(channel) else { throw XCTSkip("NDI sender couldn't open.") }
        let w = 640, h = 360
        var frame = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: frame.count, by: 4) { frame[i] = 200; frame[i + 1] = 100; frame[i + 2] = 50; frame[i + 3] = 255 }
        let sending = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "loopback.send"))
        sending.schedule(deadline: .now(), repeating: .milliseconds(33))
        sending.setEventHandler { frame.withUnsafeBufferPointer { ndi_send_frame(send, $0.baseAddress, Int32(w), Int32(h), Int32(w * 4), 30, 1) } }
        // Closing the sender while a frame is still going out crashes inside the NDI runtime (and is
        // blamed on whatever test happens to be running), so wait for the timer to stop first.
        let stopped = DispatchSemaphore(value: 0)
        sending.setCancelHandler { stopped.signal() }
        sending.resume()
        defer { sending.cancel(); stopped.wait(); ndi_send_close(send) }

        let feed = NDIInputFeed(source: "ANY COMPUTER (\(channel))")
        let got = XCTestExpectation(description: "a frame arrives")
        let box = Box()
        let id = feed.subscribe { pixels in
            box.lock.lock(); defer { box.lock.unlock() }
            guard box.size == nil else { return }
            box.size = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) { box.first = [base[0], base[1], base[2]] }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            got.fulfill()
        }
        feed.start()
        defer { feed.unsubscribe(id); feed.stop() }
        wait(for: [got], timeout: 15)
        box.lock.lock(); defer { box.lock.unlock() }
        XCTAssertEqual(box.size?.0, w)
        XCTAssertEqual(box.size?.1, h)
        // NDI compresses, so the colour is close to what was sent, not identical.
        for (got, sent) in zip(box.first, [200, 100, 50]) { XCTAssertEqual(Int(got), sent, accuracy: 15) }
        XCTAssertEqual(box.first.count, 3)
        XCTAssertTrue(feed.live)
        XCTAssertEqual(feed.shape, "640x360 @ 30.00")
    }

    private final class Box { let lock = NSLock(); var size: (Int, Int)?; var first: [UInt8] = [] }
}

final class StartModeTests: XCTestCase {
    private let lectern = CropRect(x: 0.2, y: 0.2, w: 0.4, h: 0.4)

    private func camera(_ mode: StartMode, shot: Bool = true, pickShot: Bool = true) -> VirtualCamera {
        var cam = VirtualCamera(name: "Pulpit", device: "none", ndiName: "Test Start")
        let s = CropShot(name: "Lectern", crop: lectern)
        if shot { cam.shots = [s] }
        cam.startMode = mode
        if pickShot { cam.startShot = s.id }
        return cam
    }

    func testItFollowsUnlessToldOtherwise() throws {
        XCTAssertEqual(VirtualCamera(device: "d", ndiName: "n").startMode, .follow)
        let cam = try JSONDecoder().decode(VirtualCamera.self, from: Data(#"{"device":"d","ndiName":"n"}"#.utf8))
        XCTAssertEqual(cam.startMode, .follow)
        XCTAssertNil(cam.startShot)
    }

    func testAnUnknownWordStartsFollowing() throws {
        let cam = try JSONDecoder().decode(VirtualCamera.self, from: Data(#"{"device":"d","ndiName":"n","startMode":"sideways"}"#.utf8))
        XCTAssertEqual(cam.startMode, .follow)
    }

    func testTheStartIsKeptInTheSetup() throws {
        let cam = camera(.shot)
        let back = try JSONDecoder().decode(VirtualCamera.self, from: JSONEncoder().encode(cam))
        XCTAssertEqual(back.startMode, .shot)
        XCTAssertEqual(back.startShot, cam.startShot)
    }

    func testTheInitialModeFollowsTheSetting() {
        XCTAssertEqual(camera(.follow).initialMode, .follow)
        XCTAssertEqual(camera(.wide).initialMode, .wide)
        XCTAssertEqual(camera(.shot).initialMode, .shot(lectern))
    }

    func testAMissingShotStartsFollowing() {
        XCTAssertEqual(camera(.shot, shot: false).initialMode, .follow)
        XCTAssertEqual(camera(.shot, pickShot: false).initialMode, .follow)
    }

    func testChangingTheStartDoesNotRestartTheCamera() {
        XCTAssertEqual(camera(.follow).pipeline, camera(.wide).pipeline)
    }

    func testAWideCameraOpensOnTheWholePictureAndStaysThere() {
        let r = VirtualCameraRuntime(camera(.wide), config: CueConfig())
        XCTAssertEqual(r.currentMode, .wide)
        r.ensureGeometry(1920, 1080)
        XCTAssertEqual(r.currentMode, .wide)
        XCTAssertEqual(r.status().crop, .full)
    }

    func testAShotCameraOpensOnThatShot() {
        let r = VirtualCameraRuntime(camera(.shot), config: CueConfig())
        r.ensureGeometry(3840, 2160)
        XCTAssertEqual(r.currentMode, .shot(lectern))
        XCTAssertEqual(r.status().crop, lectern)
    }

    func testANewInputFormatGoesBackToTheStartMode() {
        let r = VirtualCameraRuntime(camera(.wide), config: CueConfig())
        r.ensureGeometry(3840, 2160)
        r.followPerson()
        XCTAssertEqual(r.currentMode, .follow)
        r.ensureGeometry(1920, 1080)
        XCTAssertEqual(r.currentMode, .wide)
    }
}

final class NDIGroupTests: XCTestCase {
    func testGroupNamesAreCleaned() {
        XCTAssertEqual(VirtualCamera.cleanGroups(" Stage , Booth ,, "), "Stage,Booth")
        XCTAssertEqual(VirtualCamera.cleanGroups("Stage"), "Stage")
        XCTAssertNil(VirtualCamera.cleanGroups("  , "))
        XCTAssertNil(VirtualCamera.cleanGroups(""))
        XCTAssertNil(VirtualCamera.cleanGroups(nil))
    }

    func testTheGroupIsKeptAndTidiedFromTheSetupFile() throws {
        var cam = VirtualCamera(device: "d", ndiName: "n")
        cam.ndiGroups = "Stage"
        XCTAssertEqual(try JSONDecoder().decode(VirtualCamera.self, from: JSONEncoder().encode(cam)).ndiGroups, "Stage")
        let loose = try JSONDecoder().decode(VirtualCamera.self, from: Data(#"{"device":"d","ndiName":"n","ndiGroups":" A , B "}"#.utf8))
        XCTAssertEqual(loose.ndiGroups, "A,B")
        XCTAssertNil(try JSONDecoder().decode(VirtualCamera.self, from: Data(#"{"device":"d","ndiName":"n"}"#.utf8)).ndiGroups)
    }

    func testChangingTheGroupReopensTheOutput() {
        var a = VirtualCamera(device: "d", ndiName: "n"), b = a
        b.ndiGroups = "Stage"
        XCTAssertNotEqual(a.pipeline, b.pipeline)
        a.ndiGroups = "Stage"
        XCTAssertEqual(a.pipeline, b.pipeline)
    }

    /// With the real NDI runtime: a source in a group isn't in the public list, an ordinary one is.
    func testASourceInAGroupIsNotInThePublicList() throws {
        guard ndi_load() != nil else { throw XCTSkip("The NDI runtime isn't installed.") }
        let tag = Int.random(in: 1000...9999)
        let open = "CueVideoPublic\(tag)", hidden = "CueVideoHidden\(tag)"
        guard let a = ndi_send_open(open), let b = ndi_send_open_groups(hidden, "CueVideoPrivateGroup") else { throw XCTSkip("NDI sender couldn't open.") }
        defer { ndi_send_close(a); ndi_send_close(b) }
        func names() -> [String] {
            var buf = [CChar](repeating: 0, count: 256 * 64)
            let n = Int(ndi_sources(&buf, 64, 500))
            return (0..<n).map { i in buf.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * 256) } }
        }
        // The ordinary source is the control: until it shows up, discovery hasn't settled, so say nothing.
        var seen = false
        for _ in 0..<20 where !seen { seen = names().contains { $0.contains(open) } }
        guard seen else { throw XCTSkip("NDI discovery didn't show the control source in time.") }
        XCTAssertFalse(names().contains { $0.contains(hidden) })
    }
}

final class PictureGeometryTests: XCTestCase {
    func testAWidePictureInASquareBoxIsLetterboxed() {
        let r = PictureGeometry.fitted(CGSize(width: 1920, height: 1080), in: CGSize(width: 200, height: 200))
        XCTAssertEqual(r.width, 200, accuracy: 1e-9)
        XCTAssertEqual(r.height, 112.5, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 43.75, accuracy: 1e-9)
    }

    func testAClickMapsOntoThePictureWhateverItsShape() {
        let box = CGSize(width: 400, height: 225)
        let sixteenNine = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(PictureGeometry.normalized(CGPoint(x: 100, y: 56.25), image: sixteenNine, in: box)!.x, 0.25, accuracy: 1e-9)
        // A 4:3 picture leaves bars at the sides: the middle of the box is the middle of the picture,
        // and a click in a bar is no click on the picture.
        let fourThree = CGSize(width: 1600, height: 1200)
        let mid = PictureGeometry.normalized(CGPoint(x: 200, y: 112.5), image: fourThree, in: box)!
        XCTAssertEqual(mid.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.y, 0.5, accuracy: 1e-9)
        XCTAssertNil(PictureGeometry.normalized(CGPoint(x: 5, y: 100), image: fourThree, in: box))
    }

    func testAPickedPointChoosesThePersonUnderIt() {
        var follow = VirtualFollow(planner: CropPlanner(maxZoom: 2.5), framing: Framing(ShotSize.waist.standard))
        func person(_ x: CGFloat) -> TrackedPerson {
            TrackedPerson(box: CGRect(x: x - 0.05, y: 0.2, width: 0.1, height: 0.5), eye: CGPoint(x: x, y: 0.3), scale: 0.1)
        }
        follow.release(pick: CGPoint(x: 0.8, y: 0.4))
        follow.update(people: [person(0.2), person(0.5), person(0.8)], now: Date())
        XCTAssertEqual(follow.target?.eye.x ?? 0, 0.8, accuracy: 1e-9)
    }
}

final class ManualFramingTests: XCTestCase {
    private func runtime() -> VirtualCameraRuntime {
        let r = VirtualCameraRuntime(VirtualCamera(name: "Pulpit", device: "none", ndiName: "Test Manual"), config: CueConfig())
        r.ensureGeometry(3840, 2160)   // zoom limit 2.5: the crop is never shorter than 0.4
        return r
    }

    func testDraggingCentersTheCropAndHoldsIt() {
        let r = runtime()
        r.frameManually(centerX: 0.5, centerY: 0.5, height: 0.5)
        XCTAssertEqual(r.currentMode, .hold)
        let c = r.status().crop
        XCTAssertEqual(c.h, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.x + c.w / 2, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.y + c.h / 2, 0.5, accuracy: 1e-9)
    }

    func testTheCropNeverLeavesThePictureOrPassesTheZoomLimit() {
        let r = runtime()
        r.frameManually(centerX: 0, centerY: 1, height: 0.1)   // too tight, and in a corner
        let c = r.status().crop
        XCTAssertEqual(c.h, 0.4, accuracy: 1e-9)
        XCTAssertEqual(c.x, 0, accuracy: 1e-9)
        XCTAssertEqual(c.y + c.h, 1, accuracy: 1e-9)
    }

    func testZoomingKeepsTheCentre() {
        let r = runtime()
        r.frameManually(centerX: 0.4, centerY: 0.5, height: 0.8)
        r.zoomManually(by: 0.5)
        let c = r.status().crop
        XCTAssertEqual(c.h, 0.4, accuracy: 1e-9)
        XCTAssertEqual(c.x + c.w / 2, 0.4, accuracy: 1e-9)
    }

    func testSavedShotsGetTheNextFreeName() {
        var cam = VirtualCamera(device: "d", ndiName: "n")
        XCTAssertEqual(cam.nextShotName, "Shot 1")
        cam.shots = [CropShot(name: "Shot 1", crop: .full), CropShot(name: "shot 3", crop: .full)]
        XCTAssertEqual(cam.nextShotName, "Shot 2")
    }
}

final class VideoFileInputTests: XCTestCase {
    /// A tiny clip of `count` frames at 10 fps, written with AVAssetWriter into a temp folder.
    private func makeClip(count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cue-clip-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return url
    }

    func testPlaysTheClipInALoopAtItsOwnPace() throws {
        let url = try makeClip(count: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let feed = VideoFileFeed(path: url.path)
        var count = 0
        let lock = NSLock()
        let id = feed.subscribe { _ in lock.lock(); count += 1; lock.unlock() }
        feed.start()
        defer { feed.unsubscribe(id); feed.stop() }
        Thread.sleep(forTimeInterval: 1.6)   // 5 frames at 10 fps last 0.5 s: more than 5 frames means it looped
        lock.lock(); let n = count; lock.unlock()
        XCTAssertGreaterThan(n, 8)
        XCTAssertLessThan(n, 22)             // and not played flat out
        XCTAssertTrue(feed.live)
        XCTAssertTrue(feed.shape.hasPrefix("320x180"))
    }

    func testAMissingFileSaysSo() {
        let feed = VideoFileFeed(path: "/nonexistent/clip.mov")
        feed.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(feed.live)
        XCTAssertTrue(feed.problem?.contains("isn't there") ?? false)
    }

    func testTheFileIsPartOfThePipelineAndSurvivesTheSetupFile() throws {
        var cam = VirtualCamera(device: "d", ndiName: "n")
        let before = cam.pipeline
        cam.videoFile = "/tmp/a.mov"
        XCTAssertNotEqual(cam.pipeline, before)
        let back = try JSONDecoder().decode(VirtualCamera.self, from: JSONEncoder().encode(cam))
        XCTAssertEqual(back.videoFile, "/tmp/a.mov")
    }

    func testSmoothedAverageStartsAtTheFirstSample() {
        XCTAssertEqual(VirtualCameraRuntime.smoothed(0, 8), 8)
        XCTAssertEqual(VirtualCameraRuntime.smoothed(10, 20), 10.5, accuracy: 1e-9)
    }
}

final class UYVYOutputTests: XCTestCase {
    /// A solid BGRA frame of this colour, as a capture device would give it.
    private func solid(_ b: UInt8, _ g: UInt8, _ r: UInt8, w: Int = 1920, h: Int = 1080) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(CVPixelBufferGetBytesPerRow(buffer!) * h / 4) { base[i * 4] = b; base[i * 4 + 1] = g; base[i * 4 + 2] = r; base[i * 4 + 3] = 255 }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }

    func testTheComposedFrameIsTwoBytesAPixel() {
        let out = VirtualOutput(name: "UYVY compose", size: .p720, uyvy: true)
        let frame = out.compose(solid(50, 100, 200), .full)
        XCTAssertEqual(frame.map(CVPixelBufferGetPixelFormatType), kCVPixelFormatType_422YpCbCr8)
        XCTAssertEqual(frame.map(CVPixelBufferGetWidth), 1280)
        XCTAssertGreaterThanOrEqual(frame.map(CVPixelBufferGetBytesPerRow) ?? 0, 1280 * 2)
    }

    func testBGRAStaysTheDefault() {
        XCTAssertFalse(VirtualCamera(device: "d", ndiName: "n").sendUYVY)
        let out = VirtualOutput(name: "BGRA compose", size: .p720)
        XCTAssertEqual(out.compose(solid(50, 100, 200), .full).map(CVPixelBufferGetPixelFormatType), kCVPixelFormatType_32BGRA)
    }

    /// Sent as UYVY over a real NDI loopback and received as BGRA: the colour must come back as it went in.
    func testColourSurvivesTheTripOverNDI() throws {
        guard ndi_load() != nil else { throw XCTSkip("The NDI runtime isn't installed.") }
        let channel = "CueVideoUYVY\(Int.random(in: 1000...9999))"
        let out = VirtualOutput(name: channel, size: .p720, uyvy: true)
        let frame = solid(50, 100, 200)     // B 50, G 100, R 200
        let sending = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "uyvy.send"))
        sending.schedule(deadline: .now(), repeating: .milliseconds(33))
        sending.setEventHandler { out.submit(frame, crop: .full, fps: (30, 1)) }
        let stopped = DispatchSemaphore(value: 0)
        sending.setCancelHandler { stopped.signal() }
        sending.resume()
        defer { sending.cancel(); stopped.wait(); out.close(); Thread.sleep(forTimeInterval: 0.2) }

        let feed = NDIInputFeed(source: "ANY COMPUTER (\(channel))")
        let got = XCTestExpectation(description: "a frame arrives")
        let lock = NSLock()
        var pixel: [UInt8] = []
        let id = feed.subscribe { pixels in
            lock.lock(); defer { lock.unlock() }
            guard pixel.isEmpty else { return }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let mid = (CVPixelBufferGetHeight(pixels) / 2) * CVPixelBufferGetBytesPerRow(pixels) + (CVPixelBufferGetWidth(pixels) / 2) * 4
            if let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) { pixel = [base[mid], base[mid + 1], base[mid + 2]] }
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            got.fulfill()
        }
        feed.start()
        defer { feed.unsubscribe(id); feed.stop() }
        wait(for: [got], timeout: 15)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(pixel.count, 3)
        for (seen, sent) in zip(pixel, [50, 100, 200]) { XCTAssertEqual(Int(seen), sent, accuracy: 12, "got \(pixel)") }
    }
}
