import Foundation
import AVFoundation
import CoreVideo

/// A recorded clip played in a loop as a camera's picture, so tracking can be tuned and tested
/// without the camera. Frames come out at the clip's own pace as BGRA pixel buffers, like the
/// capture and NDI inputs give them.
final class VideoFileFeed: VideoInput, @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var subscribers: [UUID: (CVPixelBuffer) -> Void] = [:]
    private var generation = 0
    private var _live = false
    private var _problem: String?
    private var _shape = ""
    private var _rate: (n: Int32, d: Int32) = (30, 1)

    init(path: String) { self.path = path }

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
        let t = Thread { [weak self] in self?.play(gen) }
        t.name = "Video file input"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() { lock.lock(); generation += 1; _live = false; lock.unlock() }

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    private func fail(_ text: String) {
        lock.lock(); _live = false; _problem = text; lock.unlock()
    }

    /// The loop: open the clip, hand out its frames on time, start over at the end.
    private func play(_ gen: Int) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("The video file \"\((path as NSString).lastPathComponent)\" isn't there.")
            return
        }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            fail("\"\((path as NSString).lastPathComponent)\" has no video that can be read.")
            return
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        let w = Int(abs(size.width)), h = Int(abs(size.height))
        let fps = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30
        lock.lock()
        _rate = (Int32((fps * 1000).rounded()), 1000)
        _shape = String(format: "%dx%d @ %.2f (file)", w, h, fps)
        lock.unlock()

        while current(gen) {
            guard let reader = try? AVAssetReader(asset: asset) else { fail("The video file can't be opened."); return }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ])
            out.alwaysCopiesSampleData = false
            guard reader.canAdd(out) else { fail("The video file can't be read."); return }
            reader.add(out)
            guard reader.startReading() else { fail("The video file can't be read."); return }

            let began = DispatchTime.now().uptimeNanoseconds
            var first: Double?
            while current(gen), let sample = out.copyNextSampleBuffer() {
                let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let base = first ?? t
                first = base
                // Wait for this frame's moment in the clip, so it plays at its own speed.
                let due = began + UInt64(max(0, t - base) * 1_000_000_000)
                let now = DispatchTime.now().uptimeNanoseconds
                if due > now { Thread.sleep(forTimeInterval: Double(due - now) / 1e9) }
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                lock.lock()
                _live = true
                _problem = nil
                let handlers = Array(subscribers.values)
                lock.unlock()
                for handler in handlers { handler(pixels) }
            }
            reader.cancelReading()
            // An empty clip would spin: stop with a reason instead.
            if first == nil, current(gen) { fail("The video file has no frames."); return }
        }
    }
}
