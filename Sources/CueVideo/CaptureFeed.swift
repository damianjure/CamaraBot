import Foundation
import AVFoundation
import CoreImage

/// A capture device the Mac can see, such as a Blackmagic HDMI to USB capture box, with the
/// formats macOS offers for it. Many capture boxes take 4K in over HDMI but only give 1080p
/// over USB, so this is the list to check before relying on 4K.
struct CaptureDeviceInfo: Equatable {
    let id: String
    let name: String
    let formats: [String]
}

/// The live picture of one USB capture device (an `AVCaptureSession`). Full resolution frames go
/// to whoever subscribed, straight from the capture thread; nothing here copies or converts them.
/// It reconnects by itself when the device is unplugged and plugged back in.
final class CaptureFeed: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    @Published private(set) var live = false
    /// Why there is no picture, when there isn't one (no permission, device missing).
    @Published private(set) var problem: String?
    /// The input as it arrives, for Status: "3840x2160 @ 29.97".
    @Published private(set) var shape = ""

    let deviceID: String
    /// Which format to ask for, as "3840x2160". Nil takes the largest the device offers.
    let preferred: String?

    typealias Handler = (CVPixelBuffer) -> Void

    private let control = DispatchQueue(label: "cuevideo.capture.control")
    private let frames = DispatchQueue(label: "cuevideo.capture.frames", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let lock = NSLock()
    private var subscribers: [UUID: Handler] = [:]
    private var wanted = false
    private var lastFrame = Date.distantPast
    private var lastConfigure = Date.distantPast
    private var size = (w: 0, h: 0)
    private var duration = CMTime(value: 1001, timescale: 30000)
    private var watchdog: DispatchSourceTimer?

    init(deviceID: String, preferred: String? = nil) {
        self.deviceID = deviceID
        self.preferred = preferred
    }

    /// Frame size and rate, for the output and the zoom limit.
    var frameSize: (w: Int, h: Int) { lock.lock(); defer { lock.unlock() }; return size }
    /// Frame rate as the fraction NDI wants (30000 / 1001 for 29.97).
    var frameRate: (n: Int32, d: Int32) {
        lock.lock(); defer { lock.unlock() }
        return (Int32(truncatingIfNeeded: duration.timescale), Int32(truncatingIfNeeded: duration.value))
    }

    /// Every frame, on the capture thread. Keep the work short; hand anything slow to another queue.
    func subscribe(_ handler: @escaping Handler) -> UUID {
        let id = UUID()
        lock.lock(); subscribers[id] = handler; lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) { lock.lock(); subscribers[id] = nil; lock.unlock() }

    func start() {
        control.async { [weak self] in
            guard let self, !self.wanted else { return }
            self.wanted = true
            self.configureAndRun()
            let t = DispatchSource.makeTimerSource(queue: self.control)
            t.schedule(deadline: .now() + 2, repeating: 2)
            t.setEventHandler { [weak self] in self?.check() }
            t.resume()
            self.watchdog = t
        }
    }

    func stop() {
        control.async {
            self.wanted = false
            self.watchdog?.cancel(); self.watchdog = nil
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.live = false }
        }
    }

    // MARK: Devices and formats

    /// Every external video capture device now (USB capture boxes, webcams). The Mac's own
    /// camera is left out on purpose: a setup file or a Claude tool must not be able to put it
    /// on the network as an NDI source.
    static func devices() -> [CaptureDeviceInfo] {
        discovery().devices.map { d in
            CaptureDeviceInfo(id: d.uniqueID, name: d.localizedName, formats: describe(d.formats))
        }
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
    }

    /// Only an external device, even when given the ID of the built-in camera.
    private static func device(_ id: String) -> AVCaptureDevice? {
        discovery().devices.first { $0.uniqueID == id }
    }

    private static func dims(_ f: AVCaptureDevice.Format) -> (w: Int, h: Int) {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return (Int(d.width), Int(d.height))
    }

    private static func fastest(_ f: AVCaptureDevice.Format) -> AVFrameRateRange? {
        f.videoSupportedFrameRateRanges.max { $0.maxFrameRate < $1.maxFrameRate }
    }

    /// "3840x2160 @ 60", one line per distinct size and top rate.
    static func describe(_ formats: [AVCaptureDevice.Format]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for f in formats {
            let d = dims(f), r = fastest(f)?.maxFrameRate ?? 0
            let line = "\(d.w)x\(d.h) @ \(r.rounded() == r ? String(Int(r)) : String(format: "%.2f", r))"
            if seen.insert(line).inserted { out.append(line) }
        }
        return out
    }

    /// The format to use: the one asked for ("3840x2160"), else the largest, at its highest rate.
    static func pick(_ formats: [AVCaptureDevice.Format], preferred: String?) -> AVCaptureDevice.Format? {
        var pool = formats
        if let want = preferred?.split(separator: " ").first.map(String.init),
           case let match = formats.filter({ "\(dims($0).w)x\(dims($0).h)" == want }), !match.isEmpty {
            pool = match
        }
        return pool.max { a, b in
            let (da, db) = (dims(a), dims(b))
            if da.w * da.h != db.w * db.h { return da.w * da.h < db.w * db.h }
            return (fastest(a)?.maxFrameRate ?? 0) < (fastest(b)?.maxFrameRate ?? 0)
        }
    }

    // MARK: Running

    private func fail(_ why: String?) {
        DispatchQueue.main.async { if self.problem != why { self.problem = why }; if why != nil { self.live = false } }
    }

    private func configureAndRun() {
        lastConfigure = Date()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                guard let self else { return }
                if ok { self.control.async { self.configureAndRun() } } else { self.fail("Camera access was refused. Allow it in System Settings > Privacy & Security > Camera.") }
            }
            return
        case .denied, .restricted:
            fail("Camera access is off. Allow it in System Settings > Privacy & Security > Camera.")
            return
        default: break
        }
        guard let device = Self.device(deviceID) else { fail("The capture device isn't connected, or isn't an external one."); return }
        guard let format = Self.pick(device.formats, preferred: preferred) else { fail("The capture device offers no video format."); return }

        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { session.commitConfiguration(); fail("The capture device can't be used."); return }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            fail("The capture device can't be opened: \(error.localizedDescription)")
            return
        }
        let output = AVCaptureVideoDataOutput()
        // BGRA is what Core Image crops and NDI sends; the device's own format is converted for us.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // Late frames are dropped, never queued: a virtual camera is always as live as it can be.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        guard session.canAddOutput(output) else { session.commitConfiguration(); fail("The capture device can't be used."); return }
        session.addOutput(output)
        session.commitConfiguration()

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            if let r = Self.fastest(format) {
                device.activeVideoMinFrameDuration = r.minFrameDuration
                device.activeVideoMaxFrameDuration = r.minFrameDuration
            }
            device.unlockForConfiguration()
        } catch {
            fail("The capture format can't be set: \(error.localizedDescription)")
        }
        let d = Self.dims(format)
        lock.lock()
        size = (d.w, d.h)
        if let r = Self.fastest(format) { duration = r.minFrameDuration }
        lock.unlock()
        session.startRunning()
    }

    /// Every two seconds: say the picture stopped when frames stop, and open the device again
    /// when it has been gone for a while (unplugged and plugged back in). A device that is there
    /// but sends nothing (nothing plugged into the box) is not reopened over and over: it gets a
    /// plain explanation and a slower retry.
    private func check() {
        guard wanted else { return }
        let now = Date()
        let quiet = now.timeIntervalSince(lastFrame)
        if quiet > 2, live { DispatchQueue.main.async { self.live = false } }
        guard quiet > 3 else { return }
        let present = Self.device(deviceID) != nil
        if present { fail("The capture device is connected but sends no picture. Check that the camera is on and plugged into it.") }
        if now.timeIntervalSince(lastConfigure) > (present ? 10 : 3) { configureAndRun() }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let now = Date()
        lock.lock()
        lastFrame = now
        let changed = size.w != w || size.h != h
        if changed { size = (w, h) }
        let handlers = Array(subscribers.values)
        let fps = duration
        lock.unlock()
        if !live || changed {
            DispatchQueue.main.async { if self.problem != nil { self.problem = nil } }
            let rate = Double(fps.timescale) / Double(max(1, fps.value))
            let line = String(format: "%dx%d @ %.2f", w, h, rate)
            DispatchQueue.main.async {
                if self.shape != line { self.shape = line }
                if !self.live { self.live = true }
            }
        }
        for h in handlers { h(pixels) }
    }
}

/// One capture session per device, shared by every virtual camera that uses it, running only
/// while something needs it (the same pattern as NDIFeedHub).
final class CaptureFeedHub {
    static let shared = CaptureFeedHub()
    private var feeds: [String: CaptureFeed] = [:]
    private var users: [String: Int] = [:]

    /// The feed for a device. `preferred` is used only when the feed is first made.
    func feed(_ id: String, preferred: String? = nil) -> CaptureFeed {
        if let f = feeds[id] { return f }
        let f = CaptureFeed(deviceID: id, preferred: preferred)
        feeds[id] = f
        return f
    }

    func retain(_ id: String, preferred: String? = nil) -> CaptureFeed {
        let f = feed(id, preferred: preferred)
        users[id, default: 0] += 1
        if users[id] == 1 { f.start() }
        return f
    }

    func release(_ id: String) {
        guard let n = users[id] else { return }
        if n <= 1 { users[id] = nil; feeds[id]?.stop(); feeds[id] = nil } else { users[id] = n - 1 }
    }

    /// For status: whether a device's picture is coming in (nil when nothing is using it).
    func isLive(_ id: String) -> Bool? { users[id] == nil ? nil : feeds[id]?.live }
}

/// Turning full-size captured frames into small pictures for detection and previews.
enum FrameTools {
    /// No color management: pictures pass through untouched, as video should.
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// A copy of a captured frame about `width` pixels across. Tracking looks at this, so a 4K
    /// picture costs no more detection time than a 1080p one.
    static func thumbnail(_ pixels: CVPixelBuffer, width: Int) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        let full = image.extent.width
        guard full > 0 else { return nil }
        let scale = min(1, Double(width) / Double(full))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
