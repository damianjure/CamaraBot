import SwiftUI
import CoreGraphics
import CueNDI

/// A small live picture from an NDI source, such as CueScreens' graphics or its lower thirds.
/// It asks the sender for NDI's low-bandwidth preview stream (about 640 wide), so watching it
/// costs little network or processor time, and keeps the alpha channel when the source sends
/// one, so a lower third can be laid over a camera picture.
final class NDIFeed: ObservableObject, @unchecked Sendable {
    @Published private(set) var image: CGImage?
    @Published private(set) var live = false
    @Published private(set) var hasAlpha = false

    let source: String
    private let lock = NSLock()
    private var generation = 0

    init(source: String) { self.source = source }

    func start() {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let t = Thread { [weak self] in self?.receive(gen) }
        t.name = "NDI preview"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() {
        lock.lock(); generation += 1; lock.unlock()
        DispatchQueue.main.async { self.live = false }
    }

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    private func receive(_ gen: Int) {
        // The runtime may be missing, or the source not on the network yet: keep trying.
        while current(gen) {
            guard let recv = source.withCString({ ndi_recv_open_bw($0, true) }) else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            var lastShown = Date.distantPast, lastFrame = Date()
            while current(gen) {
                var data: UnsafePointer<UInt8>?
                var w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
                var alpha = false
                var frame: UnsafeMutableRawPointer?
                guard ndi_recv_frame_alpha(recv, 250, &data, &w, &h, &stride, &alpha, &frame), let data else {
                    if Date().timeIntervalSince(lastFrame) > 2 { DispatchQueue.main.async { if self.current(gen) { self.live = false } } }
                    continue
                }
                lastFrame = Date()
                // A preview doesn't need every frame: about 20 a second is plenty.
                if lastFrame.timeIntervalSince(lastShown) >= 0.05 {
                    lastShown = lastFrame
                    let img = Self.image(data, Int(w), Int(h), Int(stride), alpha)
                    DispatchQueue.main.async {
                        guard self.current(gen) else { return }
                        self.image = img
                        if !self.live { self.live = true }
                        if self.hasAlpha != alpha { self.hasAlpha = alpha }
                    }
                }
                ndi_recv_release(recv, frame)
            }
            ndi_recv_close(recv)
        }
    }

    /// NDI's BGRA is straight (not premultiplied) alpha; BGRX has none.
    static func image(_ src: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int, _ alpha: Bool) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        let data = Data(bytes: src, count: stride * h)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | (alpha ? CGImageAlphaInfo.first.rawValue : CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// One receiver per NDI source, shared by everything showing it, running only while shown.
final class NDIFeedHub {
    static let shared = NDIFeedHub()
    private var feeds: [String: NDIFeed] = [:]
    private var users: [String: Int] = [:]

    func feed(_ source: String) -> NDIFeed {
        if let f = feeds[source] { return f }
        let f = NDIFeed(source: source)
        feeds[source] = f
        return f
    }

    func retain(_ source: String) {
        users[source, default: 0] += 1
        if users[source] == 1 { feed(source).start() }
    }

    func release(_ source: String) {
        guard let n = users[source] else { return }
        if n <= 1 { users[source] = nil; feeds[source]?.stop() } else { users[source] = n - 1 }
    }

    /// For status: whether a source's picture is coming in (nil when nothing is showing it).
    func isLive(_ source: String) -> Bool? { users[source] == nil ? nil : feeds[source]?.live }
}

/// An NDI source's picture, fitted to its frame. With `overlay`, nothing is drawn behind it
/// and no waiting message shows, so it can sit on top of another picture.
struct NDIVideo: View {
    let source: String
    var overlay = false
    @ObservedObject private var feed: NDIFeed

    init(source: String, overlay: Bool = false) {
        self.source = source
        self.overlay = overlay
        feed = NDIFeedHub.shared.feed(source)
    }

    var body: some View {
        ZStack {
            if !overlay { Color.black }
            if let img = feed.image, !overlay || feed.live {
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
            if !overlay, !feed.live {
                VStack(spacing: T.s1) {
                    ProgressView().controlSize(.small)
                    Text(feed.image == nil ? "Waiting for \(NDIMonitor.shortName(source))" : "Picture stopped")
                        .font(.sans(11)).foregroundStyle(T.inkMuted).lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(T.s2)
                .background(RoundedRectangle(cornerRadius: T.rMD).fill(Color.black.opacity(0.6)))
            }
        }
        .allowsHitTesting(false)
        .onAppear { NDIFeedHub.shared.retain(source) }
        .onDisappear { NDIFeedHub.shared.release(source) }
    }
}
