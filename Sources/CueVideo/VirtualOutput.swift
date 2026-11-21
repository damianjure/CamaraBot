import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import VideoToolbox
import NDIBridge

/// Sends one virtual camera's picture out over NDI: each captured frame is cropped to the
/// current crop rectangle, scaled to 1080p or 720p, and sent. Rendering runs on its own queue and
/// never blocks capture or the interface; when it's behind, the newest frame waits for nothing
/// and the one that couldn't be rendered in time is dropped, never queued.
final class VirtualOutput: @unchecked Sendable {
    let name: String
    let size: OutputSize
    /// The NDI groups the source is announced in (see VirtualCamera.ndiGroups), or nil for the public one.
    let groups: String?
    /// Sends UYVY (4:2:2) instead of BGRA: half the data to move, and what NDI works in anyway.
    let uyvy: Bool

    private let queue = DispatchQueue(label: "cuevideo.virtual.output", qos: .userInteractive)
    private let lock = NSLock()
    private var busy = false
    private var sender: UnsafeMutableRawPointer?
    private var pool: CVPixelBufferPool?
    // UYVY only: the picture is composed as BGRA, then converted (Core Image, set up for untouched video, won't write YUV).
    private var bgraPool: CVPixelBufferPool?
    private var transfer: VTPixelTransferSession?
    private var triedAt = Date.distantPast
    private var sentCount = 0, droppedCount = 0
    private var lastSent = Date.distantPast
    private var runtimeMissing = false
    /// Once closed it never sends again: a frame still in flight must not reopen the NDI source.
    private var closed = false

    init(name: String, size: OutputSize, groups: String? = nil, uyvy: Bool = false) {
        self.name = name
        self.size = size
        self.groups = groups
        self.uyvy = uyvy
    }

    struct Stats {
        var sent = 0, dropped = 0
        /// A frame went out in the last second.
        var live = false
        /// The NDI runtime couldn't be loaded (NDI Tools isn't installed).
        var runtimeMissing = false
    }

    var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(sent: sentCount, dropped: droppedCount, live: Date().timeIntervalSince(lastSent) < 1, runtimeMissing: runtimeMissing)
    }

    /// Crop, scale and send this frame. Returns at once. `fps` is the input's rate as a fraction.
    func submit(_ frame: CVPixelBuffer, crop: CropRect, fps: (n: Int32, d: Int32)) {
        lock.lock()
        if busy { droppedCount += 1; lock.unlock(); return }
        busy = true
        lock.unlock()
        queue.async { [self] in
            render(frame, crop, fps)
            lock.lock(); busy = false; lock.unlock()
        }
    }

    /// Closes the NDI sender once whatever is rendering has finished.
    func close() {
        queue.async { [self] in
            closed = true
            if let s = sender { ndi_send_close(s); sender = nil }
            pool = nil
            bgraPool = nil
            if let t = transfer { VTPixelTransferSessionInvalidate(t); transfer = nil }
        }
    }

    // MARK: Rendering (on `queue`)

    private func openSender() -> UnsafeMutableRawPointer? {
        if closed { return nil }
        if let sender { return sender }
        // The NDI runtime may be missing: try again now and then, not on every frame.
        guard Date().timeIntervalSince(triedAt) > 5 else { return nil }
        triedAt = Date()
        let s = name.withCString { n in (groups ?? "").withCString { ndi_send_open_groups(n, $0) } }
        lock.lock(); runtimeMissing = s == nil; lock.unlock()
        sender = s
        return s
    }

    private func nextBuffer(yuv: Bool = false) -> CVPixelBuffer? {
        if yuv { return makeBuffer(&pool, kCVPixelFormatType_422YpCbCr8) }
        if uyvy { return makeBuffer(&bgraPool, kCVPixelFormatType_32BGRA) }
        return makeBuffer(&pool, kCVPixelFormatType_32BGRA)
    }

    private func makeBuffer(_ pool: inout CVPixelBufferPool?, _ format: OSType) -> CVPixelBuffer? {
        if pool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }

    private func render(_ frame: CVPixelBuffer, _ crop: CropRect, _ fps: (n: Int32, d: Int32)) {
        guard let sender = openSender(), let out = compose(frame, crop) else { return }
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(out) else { return }
        ndi_send_frame_format(sender, base.assumingMemoryBound(to: UInt8.self), Int32(size.width), Int32(size.height),
                              Int32(CVPixelBufferGetBytesPerRow(out)), fps.n, fps.d, uyvy ? 1 : 0)
        lock.lock(); sentCount += 1; lastSent = Date(); lock.unlock()
    }

    /// The picture to send: `crop` of the captured frame, scaled to the output size. Apart from
    /// `render` so it can be tested without NDI.
    func compose(_ frame: CVPixelBuffer, _ crop: CropRect) -> CVPixelBuffer? {
        guard let out = nextBuffer() else { return nil }
        let w = Double(CVPixelBufferGetWidth(frame)), h = Double(CVPixelBufferGetHeight(frame))
        // Whole pixels (a fraction of a pixel would blur the edge), and Core Image counts up from the bottom.
        let box = CGRect(x: (crop.x * w).rounded(), y: ((1 - crop.y - crop.h) * h).rounded(),
                         width: max(16, (crop.w * w).rounded()), height: max(16, (crop.h * h).rounded()))
        var image = CIImage(cvPixelBuffer: frame).cropped(to: box)
            .transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
        let sx = Double(size.width) / Double(box.width), sy = Double(size.height) / Double(box.height)
        if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
            // Lanczos keeps a 4K picture sharp at 1080p, and a tight crop as clean as it can be.
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image
            f.scale = Float(sy)
            f.aspectRatio = Float(sx / sy)
            image = f.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        FrameTools.context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), colorSpace: nil)
        return uyvy ? convertToUYVY(out) : out
    }

    /// The BGRA picture as UYVY, with the colour matrix HD video uses (Rec. 709) written on the result.
    private func convertToUYVY(_ bgra: CVPixelBuffer) -> CVPixelBuffer? {
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        guard let transfer, let yuv = nextBuffer(yuv: true) else { return nil }
        CVBufferSetAttachment(yuv, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(yuv, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(yuv, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        guard VTPixelTransferSessionTransferImage(transfer, from: bgra, to: yuv) == noErr else { return nil }
        return yuv
    }
}
