import AppKit
import CoreVideo
import CueNDI
import SwiftUI

/// The preview monitor: any NDI source, usually the ATEM's multiview.
/// The NDI runtime is loaded when first needed, from NDI Tools.
final class NDIMonitor: ObservableObject, @unchecked Sendable {
    static let shared = NDIMonitor()

    @Published private(set) var sources: [String] = []
    @Published private(set) var source: String?
    @Published private(set) var hasRuntime = true
    @Published private(set) var receiving = false

    private let lock = NSLock()
    private var last: CVPixelBuffer?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var generation = 0
    private var lastFrameAt = Date.distantPast

    func scan() {
        DispatchQueue.global(qos: .utility).async {
            guard ndi_load() != nil else {
                DispatchQueue.main.async { self.hasRuntime = false }
                return
            }
            var buf = [CChar](repeating: 0, count: 256 * 64)
            let n = Int(ndi_sources(&buf, 64, 1500))
            let names = (0..<n).map { i in buf.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * 256) } }
            DispatchQueue.main.async { self.hasRuntime = true; self.sources = names.sorted() }
        }
    }

    /// "BOOTH-MAC.LOCAL (ATEM Multiview)" reads as "ATEM Multiview · booth-mac".
    static func shortName(_ full: String) -> String {
        guard let open = full.firstIndex(of: "("), full.hasSuffix(")") else { return full }
        let host = full[..<open].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".local", with: "")
        return "\(full[full.index(after: open)..<full.index(before: full.endIndex)]) · \(host)"
    }

    func start(_ name: String?) {
        lock.lock()
        generation += 1
        let gen = generation
        last = nil
        lock.unlock()
        source = name
        UserDefaults.standard.set(name, forKey: "ndiSource")
        receiving = false
        guard let name else { return }
        let t = Thread { [weak self] in self?.receive(name, gen) }
        t.name = "NDI receive"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func current(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == gen }

    private func receive(_ name: String, _ gen: Int) {
        guard let recv = name.withCString({ ndi_recv_open($0) }) else {
            DispatchQueue.main.async { self.hasRuntime = false }
            return
        }
        defer { ndi_recv_close(recv) }
        while current(gen) {
            var data: UnsafePointer<UInt8>?
            var w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
            var frame: UnsafeMutableRawPointer?
            guard ndi_recv_frame(recv, 250, &data, &w, &h, &stride, &frame), let data else {
                if Date().timeIntervalSince(lastFrameAt) > 2 { DispatchQueue.main.async { if self.current(gen) { self.receiving = false } } }
                continue
            }
            if let pb = copy(data, Int(w), Int(h), Int(stride)) {
                lock.lock(); last = pb; lock.unlock()
                if Date().timeIntervalSince(lastFrameAt) > 1 { DispatchQueue.main.async { if self.current(gen) { self.receiving = true } } }
                lastFrameAt = Date()
            }
            ndi_recv_release(recv, frame)
        }
    }

    private func copy(_ src: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p; poolSize = (w, h)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let dst = CVPixelBufferGetBaseAddress(pb) {
            let dstStride = CVPixelBufferGetBytesPerRow(pb)
            let rowBytes = min(stride, dstStride)
            for y in 0..<h { memcpy(dst + y * dstStride, src + y * stride, rowBytes) }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    func frame() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return last }
}

/// Draws the newest monitor frame thirty times a second, letterboxed.
struct NDIVideoView: NSViewRepresentable {
    final class FrameView: NSView {
        private var timer: Timer?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspect
            layer?.backgroundColor = NSColor.black.cgColor
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.layer?.contents = NDIMonitor.shared.frame().flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
            }
        }
        required init?(coder: NSCoder) { nil }
        deinit { timer?.invalidate() }
    }
    func makeNSView(context: Context) -> FrameView { FrameView(frame: .zero) }
    func updateNSView(_ nsView: FrameView, context: Context) {}
}
