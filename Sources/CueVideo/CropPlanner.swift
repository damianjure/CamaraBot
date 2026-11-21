import Foundation
import CoreGraphics

// The virtual PTZ: a fixed camera is "steered" by choosing which part of its picture to send out.
// Everything here is plain math on normalized rectangles (no pictures, no cameras), so it can be
// tested on its own. The framing rules are the same ones the PTZ auto tracker uses (ShotSize).

/// The size a virtual camera sends out over NDI. Always 16:9.
enum OutputSize: String, Codable, CaseIterable, Hashable {
    case p1080, p720
    var width: Int { self == .p1080 ? 1920 : 1280 }
    var height: Int { self == .p1080 ? 1080 : 720 }
}

/// A part of the captured picture, 0 to 1 across and down, origin top left.
struct CropRect: Codable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    static let full = CropRect(x: 0, y: 0, w: 1, h: 1)
}

/// A framing rule with every number filled in (see ShotSize and FramingRule).
struct Framing: Equatable {
    /// Where the eyes sit, down from the top of the crop.
    var eyeLine: Double
    /// Eyes to shoulders as a share of the crop's height.
    var scale: Double
    /// How far off center a person facing or walking one way sits.
    var leadRoom: Double
    /// How far they can drift across or up and down before the crop moves.
    var deadX: Double
    var deadY: Double
}

extension Framing {
    /// The same defaults ShotSize uses when a rule leaves a number out.
    init(_ r: FramingRule) {
        self.init(eyeLine: r.eyeLine ?? 0.3, scale: r.scale ?? 0.2, leadRoom: r.leadRoom ?? 0.1,
                  deadX: r.deadX ?? 0.07, deadY: r.deadY ?? 0.08)
    }
}

/// The geometry of one virtual camera: how the captured picture and the output relate.
struct CropPlanner: Equatable {
    /// Width ÷ height of the captured picture, and of what is sent out.
    var sourceAspect = 16.0 / 9
    var outputAspect = 16.0 / 9
    /// The most it zooms in (2 means the crop is half the height of the picture).
    var maxZoom = 2.5

    /// How far a crop can zoom before the picture goes soft: input height ÷ output height, with
    /// a little headroom (`quality`) since a slight upscale is still acceptable.
    /// 4K to 1080p gives 2.5, 1080p to 1080p gives 1.25.
    static func maxZoom(inputHeight: Int, outputHeight: Int, quality: Double = 1.25) -> Double {
        guard inputHeight > 0, outputHeight > 0 else { return 1 }
        return max(1, Double(inputHeight) / Double(outputHeight) * quality)
    }

    /// The tallest crop: the whole picture, or less when the picture is narrower than the output.
    var fullHeight: Double { min(1, sourceAspect / outputAspect) }
    /// The shortest crop (the tightest shot).
    var minHeight: Double { min(fullHeight, 1 / max(1, maxZoom)) }

    func width(forHeight h: Double) -> Double { h * outputAspect / sourceAspect }
    func clampHeight(_ h: Double) -> Double { min(fullHeight, max(minHeight, h)) }

    /// A crop with this top left and height, kept inside the picture and the zoom limit.
    func rect(x: Double, y: Double, height: Double) -> CropRect {
        let h = clampHeight(height), w = width(forHeight: h)
        return CropRect(x: min(max(0, x), 1 - w), y: min(max(0, y), 1 - h), w: w, h: h)
    }

    /// The widest shot: everything the camera sees, centered.
    var fullRect: CropRect {
        let h = fullHeight, w = width(forHeight: h)
        return CropRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
    }

    /// The same crop with its height taken from the zoom limit and frame, whatever its source.
    func fitted(_ r: CropRect) -> CropRect { rect(x: r.x, y: r.y, height: r.h) }

    /// The crop height that makes a person look the size the rule asks for, and whether the
    /// zoom limit stopped it getting there ("zoom limit").
    func idealHeight(scale: Double, rule: Double) -> (height: Double, limited: Bool) {
        let want = scale / max(0.01, rule)
        return (clampHeight(want), want < minHeight - 1e-9)
    }

    /// Where the crop's top left goes so the eyes land on the marks: `markX` across (0.5 is the
    /// middle, less leaves room on the right) and `eyeLine` down.
    func position(eye: CGPoint, markX: Double, eyeLine: Double, height h: Double) -> CGPoint {
        CGPoint(x: Double(eye.x) - markX * width(forHeight: h), y: Double(eye.y) - eyeLine * h)
    }
}

/// Where the crop wants to be for the person being followed. It doesn't chase small moves:
/// the crop stays put while the eyes are inside the dead zone, moves once they leave it, and
/// settles again when they're back near the mark. Size works the same way, so breathing,
/// nodding or a step toward the camera never sets the zoom hunting.
struct CropFollow {
    /// Set when the size asked for is tighter than the zoom limit.
    private(set) var limited = false
    private(set) var goal: CropRect
    private var movingX = false, movingY = false
    /// How wrong the size must look (a log ratio, 0.15 is about a seventh) before it changes.
    var sizeThreshold = 0.15

    init(planner: CropPlanner) { goal = planner.fullRect }

    mutating func update(eye: CGPoint, scale: Double?, lead: Double, framing f: Framing, planner: CropPlanner) {
        var h = goal.h
        var resizing = false
        if let scale {
            let ideal = planner.idealHeight(scale: scale, rule: f.scale)
            limited = ideal.limited
            // Once it's off by more than the threshold the goal takes the right size at once; the
            // spring in CropMotion makes that a slow zoom. Afterwards it is on size again.
            if abs(log(ideal.height / max(0.001, h))) > sizeThreshold { resizing = true; h = ideal.height }
        }
        let markX = 0.5 + lead
        // Where the eyes are against the marks, in the crop as it is now.
        let ex = (Double(eye.x) - goal.x) / max(0.001, goal.w) - markX
        let ey = (Double(eye.y) - goal.y) / max(0.001, goal.h) - f.eyeLine
        if abs(ex) > f.deadX { movingX = true } else if abs(ex) < f.deadX * 0.5 { movingX = false }
        if abs(ey) > f.deadY { movingY = true } else if abs(ey) < f.deadY * 0.5 { movingY = false }
        let want = planner.position(eye: eye, markX: markX, eyeLine: f.eyeLine, height: h)
        // A new size moves the marks too, so it re-anchors both ways.
        let x = movingX || resizing ? Double(want.x) : goal.x
        let y = movingY || resizing ? Double(want.y) : goal.y
        goal = planner.rect(x: x, y: y, height: h)
    }

    /// Forget the held position, e.g. after a cut to another crop.
    mutating func reset(to r: CropRect) { goal = r; movingX = false; movingY = false; limited = false }
}

/// A critically damped spring per axis: eases into a move and settles with no overshoot. It is
/// evaluated on every output frame (30 to 60 a second) while detection runs at about 10, so the
/// crop moves smoothly however slowly the goal is updated. (The same curve as Unity's SmoothDamp.)
struct SmoothDamp {
    var value: Double
    var velocity = 0.0

    mutating func step(to target: Double, smoothTime: Double, dt: Double) {
        let omega = 2 / max(0.0001, smoothTime)
        let x = omega * dt
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let change = value - target
        let temp = (velocity + omega * change) * dt
        velocity = (velocity - omega * temp) * decay
        value = target + (change + temp) * decay
    }
}

/// The crop being sent right now, easing toward a goal. Thread safe: the goal is set from the
/// detection thread and the crop read on every output frame from the capture thread.
final class CropMotion: @unchecked Sendable {
    private let lock = NSLock()
    private var planner: CropPlanner
    private var goal: CropRect
    private var x: SmoothDamp, y: SmoothDamp, h: SmoothDamp
    private var lastAt: TimeInterval?
    /// Seconds to settle: sideways and up and down, and for a size change (slower, so it feels like a zoom).
    var moveTime = 0.45
    var zoomTime = 0.8

    init(planner: CropPlanner) {
        self.planner = planner
        goal = planner.fullRect
        x = SmoothDamp(value: goal.x); y = SmoothDamp(value: goal.y); h = SmoothDamp(value: goal.h)
    }

    /// The geometry changed (a new input format): start again from the widest shot.
    func reset(_ planner: CropPlanner) {
        lock.lock(); defer { lock.unlock() }
        self.planner = planner
        goal = planner.fullRect
        x = SmoothDamp(value: goal.x); y = SmoothDamp(value: goal.y); h = SmoothDamp(value: goal.h)
        lastAt = nil
    }

    /// A new zoom limit with the crop kept as it is: only a crop the new limit doesn't allow moves (at once).
    func retarget(_ planner: CropPlanner) {
        lock.lock(); defer { lock.unlock() }
        self.planner = planner
        let fitted = planner.fitted(goal)
        if fitted != goal {
            goal = fitted
            x = SmoothDamp(value: goal.x); y = SmoothDamp(value: goal.y); h = SmoothDamp(value: goal.h)
        }
    }

    /// `cut` jumps there at once instead of easing.
    func setGoal(_ r: CropRect, cut: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        goal = planner.fitted(r)
        if cut {
            x = SmoothDamp(value: goal.x); y = SmoothDamp(value: goal.y); h = SmoothDamp(value: goal.h)
        }
    }

    var currentGoal: CropRect { lock.lock(); defer { lock.unlock() }; return goal }

    /// The crop for the frame at `now` (seconds, any steady clock).
    func advance(to now: TimeInterval) -> CropRect {
        lock.lock(); defer { lock.unlock() }
        // A stall (the app paused, the picture dropped out) must not make the crop jump.
        let dt = min(0.1, max(0, lastAt.map { now - $0 } ?? 0))
        lastAt = now
        if dt > 0 {
            x.step(to: goal.x, smoothTime: moveTime, dt: dt)
            y.step(to: goal.y, smoothTime: moveTime, dt: dt)
            h.step(to: goal.h, smoothTime: zoomTime, dt: dt)
        }
        return planner.rect(x: x.value, y: y.value, height: h.value)
    }
}
