import Foundation
import CoreGraphics

/// How a virtual camera is being steered.
enum VirtualMode: Equatable {
    /// Follow a person around the picture.
    case follow
    /// Keep the crop where it is.
    case hold
    /// The whole picture.
    case wide
    /// Go to a saved crop.
    case shot(CropRect)
}

/// Following one person with a crop: the virtual camera's counterpart of AutoTracker's pan and
/// tilt. People come in from detection (AutoTracker.detect, the same Vision code the PTZ tracker
/// uses); what goes out is the crop to aim for. It keeps hold of the same person by position and
/// by what they look like (IdentityMatch), and it frames them with the same broadcast rules
/// (Framing, from ShotSize). There is no motor to steer, so no latency or speed to learn.
///
/// This is deliberately a smaller copy of the selection part of AutoTracker.update, so that
/// the PTZ tracker stays untouched. If the two ever need to move together, extract the shared
/// part into one core that both call.
struct VirtualFollow {
    enum Phase: String { case idle, following, searching, lost }

    var framing: Framing
    var planner: CropPlanner
    /// Where the operator picked the person to follow (0 to 1, top left); nil means nearest the middle.
    var pick: CGPoint?
    /// Seconds without seeing them before the crop eases out to the whole picture.
    var holdLost = 4.0

    private(set) var phase: Phase = .idle
    private(set) var target: TrackedPerson?
    private(set) var follow: CropFollow

    private var eye: CGPoint?        // smoothed
    private var scale: Double?       // smoothed
    private var lead = 0.0           // smoothed lead-room offset
    private var lastSeen = Date.distantPast
    private var lastUpdate: Date?
    private var lastEyeX: CGFloat?
    private var vx = 0.0             // sideways speed in the picture, widths a second
    private var walkDir = 0, walkSince = Date()
    private var gallery: [Appearance] = []
    private var galleryAt = Date.distantPast
    private var aloneSince: Date?

    init(planner: CropPlanner, framing: Framing) {
        self.planner = planner
        self.framing = framing
        follow = CropFollow(planner: planner)
    }

    /// The crop to aim for now.
    var goal: CropRect { phase == .lost ? planner.fullRect : follow.goal }
    /// True when the shot asked for is tighter than the zoom limit allows.
    var zoomLimited: Bool { follow.limited }

    /// Forget who was being followed (to pick someone new).
    mutating func release(pick: CGPoint? = nil) {
        target = nil; eye = nil; scale = nil; gallery = []; aloneSince = nil
        lastEyeX = nil; vx = 0; walkDir = 0
        phase = .idle
        self.pick = pick
    }

    /// Takes the people found in a new detection frame; returns the crop to aim for.
    @discardableResult
    mutating func update(people: [TrackedPerson], now: Date) -> CropRect {
        let dt = lastUpdate.map { min(0.5, max(0.02, now.timeIntervalSince($0))) } ?? 0.1
        lastUpdate = now

        guard let last = target else {
            let p = pick ?? CGPoint(x: 0.5, y: 0.5)
            let first = people.first { $0.box.contains(p) } ?? people.min { dist($0.box.center, p) < dist($1.box.center, p) }
            guard let first else { return goal }
            target = first
            eye = first.eye
            scale = first.scale
            lastSeen = now
            phase = .following
            if let look = first.appearance { gallery = [look]; galleryAt = now }
            frame(first, now: now, dt: dt)
            return goal
        }

        let gone = now.timeIntervalSince(lastSeen)
        let reach = min(0.5, 0.2 + max(last.box.width, last.box.height) * 0.6 + gone * 0.15)
        let candidates = people.map { p in
            IdentityMatch.Candidate(position: dist(p.box.center, last.box.center),
                                    appearance: gallery.isEmpty ? nil : p.appearance?.distance(to: gallery))
        }
        guard case let .take(i, sure) = IdentityMatch.choose(candidates, reach: reach, gone: gone, model: .init()) else {
            phase = gone > holdLost ? .lost : .searching
            return goal
        }
        let next = people[i]
        learn(next, candidates, i, sure: sure, reach: reach, gone: gone, now: now)
        target = next
        lastSeen = now
        phase = .following
        // Smoothed over a few detection frames (the picture is steady, the detection is not).
        let o = eye ?? next.eye
        let a = 1 - exp(-dt / 0.12)
        eye = CGPoint(x: o.x + (next.eye.x - o.x) * a, y: o.y + (next.eye.y - o.y) * a)
        if let n = next.scale { let b = 1 - exp(-dt / 1.2); scale = scale.map { $0 + (n - $0) * b } ?? n }
        frame(next, now: now, dt: dt)
        return goal
    }

    private mutating func frame(_ person: TrackedPerson, now: Date, dt: Double) {
        guard let eye else { return }
        // Walking one way (steadily, for 0.7 s) wins over which way they face. Eased so the
        // frame doesn't jump when they turn.
        if let lastX = lastEyeX, dt > 0.02 {
            let v = Double(person.eye.x - lastX) / dt
            vx += (v - vx) * (1 - exp(-dt / 0.5))
        }
        lastEyeX = person.eye.x
        let d = vx > 0.03 ? 1 : (vx < -0.03 ? -1 : 0)
        if d != walkDir { walkDir = d; walkSince = now }
        let dir = walkDir != 0 && now.timeIntervalSince(walkSince) > 0.7 ? walkDir : person.facing
        lead += (Double(-dir) * framing.leadRoom - lead) * (1 - exp(-dt / 1.5))
        follow.update(eye: eye, scale: scale, lead: lead, framing: framing, planner: planner)
    }

    /// Learns what the followed person looks like, only from frames where it's certain who they
    /// are: their look confirmed it, or they've been the only person around for a second. Two
    /// people crossing never teaches it the wrong one.
    private mutating func learn(_ next: TrackedPerson, _ candidates: [IdentityMatch.Candidate], _ i: Int,
                                sure: Bool, reach: Double, gone: Double, now: Date) {
        let alone = candidates.filter { $0.position < reach * 1.5 }.count == 1
        if !alone { aloneSince = nil } else if aloneSince == nil { aloneSince = now }
        let settled = gone < 0.7 && (aloneSince.map { now.timeIntervalSince($0) > 1 } ?? false)
        guard sure || settled, let look = next.appearance else { return }
        guard now.timeIntervalSince(galleryAt) > 0.7 else { return }
        galleryAt = now
        if gallery.count >= 6 { gallery.remove(at: 1) }  // keep the first sight for good
        gallery.append(look)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}
