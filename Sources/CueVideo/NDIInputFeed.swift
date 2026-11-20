import Foundation
import CoreVideo
import NDIBridge

/// A picture a virtual camera can be made from: a USB capture device or an NDI source.
protocol VideoInput: AnyObject {
    var live: Bool { get }
    /// Why there is no picture, when there isn't one.
    var problem: String? { get }
    /// The input as it arrives, for Status: "1920x1080 @ 50.00".
    var shape: String { get }
    var frameRate: (n: Int32, d: Int32) { get }
    func subscribe(_ handler: @escaping (CVPixelBuffer) -> Void) -> UUID
    func unsubscribe(_ id: UUID)
}

/// The full-size picture of an NDI source (the camera as vMix or a switcher sends it), handed to
/// whoever subscribed as BGRA pixel buffers, like `CaptureFeed` does for a USB device. This asks
/// for the sender's full stream, unlike `NDIFeed`, which takes the small preview for monitors.
final class NDIInputFeed: VideoInput, @unchecked Sendable {
    let source: String
    private let lock = NSLock()
    private var subscribers: [UUID: (CVPixelBuffer) -> Void] = [:]
    private var generation = 0
    private var _live = false
    private var _problem: String?
    private var _shape = ""
    private var _rate: (n: Int32, d: Int32) = (30000, 1001)
    private var pool: (w: Int, h: Int, pool: CVPixelBufferPool)?

    init(source: String) { self.source = source }

    var live: Bool { lock.lock(); defer { lock.unlock() }; return _live }
    var problem: String? { lock.lock(); defer { lock.unlock() }; return _problem }
    var shape: String { lock.lock(); defer { lock.unlock() }; return _shape }
    var frameRate: (n: Int32, d: Int32) { lock.lock(); defer { lock.unlock() }; return _rate }

    func subscribe(_ handler: @escaping (CVPixelBuffer) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); subscribers[id] = handler; lock.unlock()
        return id
    }

    func unsubscribe(_ id: UUID) { lock.lock(); subscribers[id] = nil; lock.unlock() }

    func start() {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let t = Thread { [weak self] in self?.receive(gen) }
        t.name = "NDI input"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() {
        lock.lock(); generation += 1; _live = false; lock.unlock()
    }

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    private func set(live: Bool? = nil, problem: String?? = nil) {
        lock.lock()
        if let live { _live = live }
        if let problem { _problem = problem }
        lock.unlock()
    }

    private func receive(_ gen: Int) {
        while current(gen) {
            guard ndi_load() != nil else {
                set(live: false, problem: "NDI isn't installed on this Mac. Install NDI Tools.")
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            let opened = NDIFeed.resolve(source, wait: 800)
            guard let recv = opened.withCString({ ndi_recv_open($0) }) else {
                set(live: false, problem: "The NDI source \"\(source)\" can't be opened.")
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            var lastFrame = Date(), lastLook = Date()
            while current(gen) {
                var data: UnsafePointer<UInt8>?
                var w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
                var alpha = false
                var frame: UnsafeMutableRawPointer?
                guard ndi_recv_frame_alpha(recv, 250, &data, &w, &h, &stride, &alpha, &frame), let data else {
                    let quiet = Date().timeIntervalSince(lastFrame)
                    if quiet > 2 { set(live: false) }
                    if quiet > 3 { set(problem: "No picture from the NDI source \"\(source)\". Check that it is on the network and sending.") }
                    // The sender may be back under another computer name (see NDIFeed.resolve).
                    if quiet > 4, Date().timeIntervalSince(lastLook) > 3 {
                        lastLook = Date()
                        if NDIFeed.resolve(source, wait: 0) != opened { break }
                    }
                    continue
                }
                lastFrame = Date()
                var n: Int32 = 0, d: Int32 = 0
                ndi_frame_rate(frame, &n, &d)
                if let pixels = copy(data, Int(w), Int(h), Int(stride)) {
                    lock.lock()
                    if n > 0, d > 0 { _rate = (n, d) }
                    let line = String(format: "%dx%d @ %.2f", w, h, Double(_rate.n) / Double(max(1, _rate.d)))
                    if _shape != line { _shape = line }
                    _live = true
                    _problem = nil
                    let handlers = Array(subscribers.values)
                    lock.unlock()
                    for handler in handlers { handler(pixels) }
                }
                ndi_recv_release(recv, frame)
            }
            ndi_recv_close(recv)
        }
    }

    /// The frame copied into a pixel buffer of its own: the NDI frame goes back to the receiver
    /// at once, and every row is copied as far as the picture goes, whatever the stride.
    private func copy(_ src: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int) -> CVPixelBuffer? {
        lock.lock()
        if pool?.w != w || pool?.h != h {
            var p: CVPixelBufferPool?
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p.map { (w, h, $0) }
        }
        let pool = self.pool?.pool
        lock.unlock()
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let buffer = out else { return nil }
        return Self.fill(buffer, from: src, w, h, stride) ? buffer : nil
    }

    /// Row by row, since the buffer's rows and the NDI frame's rows can have different strides.
    static func fill(_ buffer: CVPixelBuffer, from src: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int) -> Bool {
        guard CVPixelBufferGetWidth(buffer) == w, CVPixelBufferGetHeight(buffer) == h, stride >= w * 4 else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<h { memcpy(dst + row * dstStride, src + row * stride, w * 4) }
        return true
    }
}

/// One receiver per NDI source, running only while a virtual camera uses it.
final class NDIInputHub {
    static let shared = NDIInputHub()
    private var feeds: [String: NDIInputFeed] = [:]
    private var users: [ObjectIdentifier: Int] = [:]

    func feed(_ source: String) -> NDIInputFeed {
        if let f = feeds[source] { return f }
        let f = NDIInputFeed(source: source)
        feeds[source] = f
        return f
    }

    func retain(_ feed: NDIInputFeed) {
        users[ObjectIdentifier(feed), default: 0] += 1
        if users[ObjectIdentifier(feed)] == 1 { feed.start() }
    }

    func release(_ feed: NDIInputFeed) {
        let k = ObjectIdentifier(feed)
        guard let n = users[k] else { return }
        if n > 1 { users[k] = n - 1; return }
        users[k] = nil
        feed.stop()
        if let key = feeds.first(where: { $0.value === feed })?.key { feeds[key] = nil }
    }
}
