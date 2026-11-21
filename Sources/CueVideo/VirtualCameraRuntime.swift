import Foundation
import Combine
import CoreVideo

/// One running virtual camera: the capture picture in, the crop eased toward where the person
/// is, the cropped picture out over NDI.
///
/// Two clocks run side by side. Every captured frame (30 to 60 a second) moves the crop a step
/// along its spring and is cropped and sent. About ten times a second a small copy of the frame
/// goes to Vision to find people, which only moves the crop's goal. So the picture is as smooth
/// as the input however slowly the person is found.
final class VirtualCameraRuntime: @unchecked Sendable {
    /// The width detection looks at, whatever the input: 4K costs no more Vision time than 1080p.
    static let detectionWidth = 960
    /// The least time between detections.
    static let detectionGap = 0.08

    /// The setup for this camera. Updated while it runs for anything but the pipeline (see VirtualCamera.pipeline).
    private(set) var camera: VirtualCamera
    // The parts of it the capture thread reads: they never change while it runs.
    private let zoomOverride: Double?
    private let outputHeight: Int

    private let feed: VideoInput
    // Open and close the input: a capture device or an NDI source.
    private let acquire: () -> Void
    private let relinquish: () -> Void
    /// Why it isn't taking its input at all (it would be fed its own output), or nil.
    private let blocked: String?
    private let output: VirtualOutput
    private let motion: CropMotion
    private let vision = DispatchQueue(label: "cuevideo.virtual.vision", qos: .userInitiated)
    private let lock = NSLock()

    private var subscription: UUID?
    private var follow: VirtualFollow
    private var mode: VirtualMode = .follow
    private var framing: Framing
    private var geometry: (w: Int, h: Int)?
    private var detecting = false
    private var lastDetect = Date.distantPast
    private var started = false
    private let createdAt = Date()
    private var dropWindow = DropWindow()

    /// Seconds since this camera was set up: a picture that hasn't come yet is not a fault in the first moments.
    var age: TimeInterval { Date().timeIntervalSince(createdAt) }

    /// The shot the follow mode frames now (the setup's, until changed while running).
    private(set) var shot: ShotSize

    init(_ camera: VirtualCamera, config: CueConfig) {
        self.camera = camera
        mode = camera.initialMode
        zoomOverride = camera.maxZoom
        outputHeight = camera.output.height
        shot = camera.shot
        framing = Framing(camera.shot.standard.merged(config.framing[camera.shot.rawValue]))
        if let source = camera.inputSource {
            let f = NDIInputHub.shared.feed(source)
            feed = f
            acquire = { NDIInputHub.shared.retain(f) }
            relinquish = { NDIInputHub.shared.release(f) }
        } else {
            let f = CaptureFeedHub.shared.feed(camera.device, name: camera.deviceName, preferred: camera.inputFormat)
            feed = f
            acquire = { CaptureFeedHub.shared.retain(f) }
            relinquish = { CaptureFeedHub.shared.release(f) }
        }
        blocked = camera.inputIsOwnOutput ? "This camera is set to take its own NDI output as its input. Pick the source your switcher or vMix sends." : nil
        output = VirtualOutput(name: camera.ndiName, size: camera.output, groups: camera.ndiGroups)
        let planner = CropPlanner(maxZoom: camera.maxZoom ?? 1)
        motion = CropMotion(planner: planner)
        follow = VirtualFollow(planner: planner, framing: framing)
    }

    func start() {
        guard !started else { return }
        started = true
        // A camera fed by its own output would never settle: it stays closed and says why.
        guard blocked == nil else { return }
        acquire()
        subscription = feed.subscribe { [weak self] pixels in self?.handle(pixels) }
    }

    func stop() {
        guard started else { return }
        started = false
        if let subscription { feed.unsubscribe(subscription) }
        subscription = nil
        if blocked == nil { relinquish() }
        output.close()
    }

    // MARK: Steering

    /// Follow a person: the one nearest `point` (0 to 1, top left), or nearest the middle.
    func followPerson(at point: CGPoint? = nil) {
        lock.lock(); defer { lock.unlock() }
        follow.release(pick: point)
        mode = .follow
    }

    /// Frames the follow mode as this shot (shoulders, waist or full length), or as the one it
    /// already has when none is given, with the setup's current framing rules.
    /// Takes a changed setup that doesn't need the pipeline reopened: saved shots, the name, the shot size.
    /// Never changes the mode or the crop it is in now.
    func update(_ cam: VirtualCamera, config: CueConfig) {
        let sizeChanged = cam.shotSize != camera.shotSize
        // A name learned while running (see CaptureFeedHub.feed).
        if cam.inputSource == nil, cam.deviceName != camera.deviceName { _ = CaptureFeedHub.shared.feed(cam.device, name: cam.deviceName, preferred: cam.inputFormat) }
        // The capture thread reads the setup too (the start mode), so it changes under the lock.
        lock.lock(); camera = cam; lock.unlock()
        frame(as: sizeChanged ? cam.shot : nil, config: config)
    }

    func frame(as size: ShotSize? = nil, config: CueConfig) {
        lock.lock(); defer { lock.unlock() }
        if let size { shot = size }
        framing = Framing(shot.standard.merged(config.framing[shot.rawValue]))
        follow.framing = framing
    }

    func hold() {
        lock.lock(); defer { lock.unlock() }
        mode = .hold
        motion.setGoal(motion.advance(to: ProcessInfo.processInfo.systemUptime))
    }

    func wide(cut: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        mode = .wide
        motion.setGoal(planner().fullRect, cut: cut)
    }

    /// Go to a saved crop, easing or cutting.
    func go(to shot: CropShot, cut: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        mode = .shot(shot.crop)
        motion.setGoal(shot.crop, cut: cut)
    }

    /// The crop as it is now, saved as a shot.
    func currentCrop() -> CropRect { motion.advance(to: ProcessInfo.processInfo.systemUptime) }

    private func planner() -> CropPlanner { follow.planner }

    // MARK: Status

    struct Status {
        var name: String
        var ndiName: String
        var input: String
        var captureLive: Bool
        var problem: String?
        var outputLive: Bool
        var sent: Int
        var dropped: Int
        /// Within the last half minute (see DropWindow).
        var recentSent = 0
        var recentDropped = 0
        var runtimeMissing: Bool
        var mode: String
        var shot: String
        var phase: String
        var zoomLimited: Bool
        var maxZoom: Double?
        var crop: CropRect
    }

    /// Read from the main thread: it touches the feed's published values.
    func status() -> Status {
        let o = output.stats
        lock.lock()
        let m: String
        switch mode { case .follow: m = "follow"; case .hold: m = "hold"; case .wide: m = "wide"; case .shot: m = "shot" }
        let phase = follow.phase.rawValue, limited = follow.zoomLimited, zoom = geometry == nil ? nil : follow.planner.maxZoom
        let shot = self.shot.rawValue
        let recent = dropWindow.add(now: Date(), sent: o.sent, dropped: o.dropped)
        lock.unlock()
        return Status(name: camera.name, ndiName: camera.ndiName, input: feed.shape, captureLive: blocked == nil && feed.live, problem: blocked ?? feed.problem,
                      outputLive: o.live, sent: o.sent, dropped: o.dropped, recentSent: recent.sent, recentDropped: recent.dropped,
                      runtimeMissing: o.runtimeMissing,
                      mode: m, shot: shot, phase: mode == .follow ? phase : "-", zoomLimited: limited, maxZoom: zoom, crop: motion.currentGoal)
    }

    // MARK: Frames (capture thread)

    private func handle(_ pixels: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        ensureGeometry(w, h)
        let crop = motion.advance(to: ProcessInfo.processInfo.systemUptime)
        output.submit(pixels, crop: crop, fps: feed.frameRate)
        detectIfDue(pixels)
        previewIfWanted(pixels)
    }

    // MARK: Preview (for the operator panel)

    /// The width of the preview picture.
    static let previewWidth = 480
    private var previewImage: CGImage?
    private var previewAsked = Date.distantPast
    private var previewMade = Date.distantPast

    /// The latest small copy of the full captured picture, or nil before the first one. Asking for
    /// it is what turns the preview on: nobody looking means no extra work on the capture thread.
    func preview() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        previewAsked = Date()
        return previewImage
    }

    /// About five times a second, and only while the preview is being looked at.
    private func previewIfWanted(_ pixels: CVPixelBuffer) {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(previewAsked) < 2 && now.timeIntervalSince(previewMade) >= 0.2
        if due { previewMade = now }
        lock.unlock()
        guard due, let image = FrameTools.thumbnail(pixels, width: Self.previewWidth) else { return }
        lock.lock(); previewImage = image; lock.unlock()
    }

    /// The first frame (or a new input format) tells the real picture size: set the zoom limit
    /// from it and start again from the widest shot. Only the capture path calls it in the app;
    /// it is internal, not private, so tests can feed it frame sizes.
    func ensureGeometry(_ w: Int, _ h: Int) {
        lock.lock(); defer { lock.unlock() }
        guard geometry?.w != w || geometry?.h != h else { return }
        let first = geometry == nil
        geometry = (w, h)
        let zoom = zoomOverride ?? CropPlanner.maxZoom(inputHeight: h, outputHeight: outputHeight)
        let planner = CropPlanner(sourceAspect: Double(w) / Double(h), outputAspect: 16.0 / 9, maxZoom: zoom)
        motion.reset(planner)
        follow = VirtualFollow(planner: planner, framing: framing)
        // Steered before the first frame (a shot, wide, hold): keep that. A new input format starts
        // again the way the setup says (following, the whole picture, or a saved shot).
        if !first { mode = camera.initialMode }
        if case .shot(let crop) = mode { motion.setGoal(crop, cut: true) }
    }

    /// For tests and status: how it is being steered.
    var currentMode: VirtualMode { lock.lock(); defer { lock.unlock() }; return mode }

    private func detectIfDue(_ pixels: CVPixelBuffer) {
        let now = Date()
        lock.lock()
        guard mode == .follow, !detecting, now.timeIntervalSince(lastDetect) >= Self.detectionGap else { lock.unlock(); return }
        detecting = true
        lastDetect = now
        lock.unlock()
        // The small copy is made here, so the capture buffer goes back to the device at once.
        guard let small = FrameTools.thumbnail(pixels, width: Self.detectionWidth) else {
            lock.lock(); detecting = false; lock.unlock()
            return
        }
        vision.async { [weak self] in
            let people = AutoTracker.detect(small)
            guard let self else { return }
            self.lock.lock()
            self.detecting = false
            if self.mode == .follow {
                let goal = self.follow.update(people: people, now: Date())
                self.motion.setGoal(goal)
            }
            self.lock.unlock()
        }
    }
}

/// Starts and stops the virtual cameras to match the setup file, so editing "virtualCameras"
/// (or Claude's update_config) takes effect within a second, with no restart.
final class VirtualCameras {
    static let shared = VirtualCameras()
    private var runtimes: [UUID: VirtualCameraRuntime] = [:]
    private var subscription: AnyCancellable?

    /// Called once at launch.
    func attach(_ store: ConfigStore) {
        subscription = store.$config
            .receive(on: DispatchQueue.main)
            .sink { [weak self] config in self?.apply(config) }
    }

    /// The running camera for a setup entry; nil while it is switched off.
    func runtime(for id: UUID) -> VirtualCameraRuntime? { runtimes[id] }

    var all: [VirtualCameraRuntime] { Array(runtimes.values).sorted { $0.camera.name < $1.camera.name } }

    /// A virtual camera by name or NDI name (any case), or the only one when none is named.
    func find(_ query: String?) -> VirtualCameraRuntime? {
        let q = (query ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return runtimes.count == 1 ? runtimes.values.first : nil }
        return all.first { $0.camera.name.lowercased() == q || $0.camera.ndiName.lowercased() == q }
            ?? all.first { $0.camera.name.lowercased().contains(q) || $0.camera.ndiName.lowercased().contains(q) }
    }

    private func apply(_ config: CueConfig) {
        let wanted = Dictionary(config.virtualCameras.filter(\.enabled).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, r) in runtimes where wanted[id]?.pipeline != r.camera.pipeline {
            r.stop()
            runtimes[id] = nil
        }
        for (id, cam) in wanted {
            if let r = runtimes[id] {
                r.update(cam, config: config)
            } else {
                let r = VirtualCameraRuntime(cam, config: config)
                runtimes[id] = r
                r.start()
            }
        }
    }

    func stopAll() {
        for r in runtimes.values { r.stop() }
        runtimes.removeAll()
    }
}
