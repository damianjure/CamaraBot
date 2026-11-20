import XCTest
import CoreGraphics
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
                                    outputLive: out, sent: sent, dropped: dropped, runtimeMissing: missing, mode: "follow",
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
