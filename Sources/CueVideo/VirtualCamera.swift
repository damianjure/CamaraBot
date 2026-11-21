import Foundation

extension ShotSize {
    /// A shot named by a person or a tool: any case, spaces around it ignored. Nil when unknown.
    static func named(_ name: String) -> ShotSize? {
        ShotSize(rawValue: name.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// A saved framing of a virtual camera, like a PTZ shot: a crop of the captured picture.
struct CropShot: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var crop: CropRect

    init(id: UUID = UUID(), name: String, crop: CropRect) {
        self.id = id
        self.name = name
        self.crop = crop
    }

    private enum Keys: String, CodingKey { case id, name, crop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Shot"
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop) ?? .full
    }
}

/// How a virtual camera starts: following a person, the whole picture (a fixed general shot),
/// or a saved shot.
enum StartMode: String, Codable, CaseIterable, Hashable {
    case follow, wide, shot
}

/// A fixed camera captured over USB and "steered" by cropping its picture, sent out over NDI for
/// vMix, Zoom and the like. It lives in the setup file under "virtualCameras", and every key but
/// `device` and `ndiName` is optional.
struct VirtualCamera: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = "Virtual camera"
    /// Off: it isn't captured or sent, and the setup is kept.
    var enabled = true
    /// The capture device's unique ID (see the capture devices list in Engineer).
    var device: String
    /// The device's name when it was chosen: if its ID changes (another USB port) the one device with this name is used.
    var deviceName: String?
    /// An NDI source to take the picture from instead of a capture device, such as the camera as
    /// vMix or a switcher sends it: "COMPUTER (Channel)". Nil (or empty) uses the capture device.
    var ndiSource: String?
    /// A recorded clip played in a loop as the picture, to test and tune tracking without the camera.
    var videoFile: String?
    /// Which format to ask the device for, as "3840x2160". Nil takes the largest it offers.
    var inputFormat: String?
    var output: OutputSize = .p1080
    /// The NDI source name: other computers see "<this Mac> (<ndiName>)".
    var ndiName: String
    /// NDI groups (comma separated) to announce the source in. Receivers only see a source in a
    /// group they look in, so this keeps it out of the public list. Nil is the public group.
    /// A group is a filter for who sees the source, not a password or encryption.
    var ndiGroups: String?
    /// Send UYVY over NDI instead of BGRA (lighter on the wire; BGRA stays the default).
    var sendUYVY = false
    /// The tightest zoom. Nil works it out from the input and output sizes.
    var maxZoom: Double?
    /// The shot the follow mode frames: "shoulders", "waist" or "full".
    var shotSize = "waist"
    /// Saved framings to go to by name.
    var shots: [CropShot] = []
    /// Set when this output also feeds an ATEM input (through an NDI converter), for reference.
    var atemInput: Int?
    /// How it starts when the app opens (and again after the input's picture size changes).
    var startMode: StartMode = .follow
    /// The saved shot to open on, when `startMode` is `.shot`.
    var startShot: UUID?

    init(id: UUID = UUID(), name: String = "Virtual camera", device: String, ndiName: String) {
        self.id = id
        self.name = name
        self.device = device
        self.ndiName = ndiName
    }

    private enum Keys: String, CodingKey { case id, name, enabled, device, deviceName, ndiSource, videoFile, inputFormat, output, ndiName, ndiGroups, sendUYVY, maxZoom, shotSize, shots, atemInput, startMode, startShot }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Virtual camera"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        ndiSource = try c.decodeIfPresent(String.self, forKey: .ndiSource)
        videoFile = try c.decodeIfPresent(String.self, forKey: .videoFile)
        inputFormat = try c.decodeIfPresent(String.self, forKey: .inputFormat)
        output = try c.decodeIfPresent(OutputSize.self, forKey: .output) ?? .p1080
        ndiName = try c.decodeIfPresent(String.self, forKey: .ndiName) ?? name
        sendUYVY = try c.decodeIfPresent(Bool.self, forKey: .sendUYVY) ?? false
        ndiGroups = Self.cleanGroups(try c.decodeIfPresent(String.self, forKey: .ndiGroups))
        maxZoom = try c.decodeIfPresent(Double.self, forKey: .maxZoom)
        shotSize = try c.decodeIfPresent(String.self, forKey: .shotSize) ?? "waist"
        shots = try c.decodeIfPresent([CropShot].self, forKey: .shots) ?? []
        atemInput = try c.decodeIfPresent(Int.self, forKey: .atemInput)
        // An unknown word in the setup file starts it following, like leaving it out.
        startMode = ((try? c.decodeIfPresent(StartMode.self, forKey: .startMode)) ?? nil) ?? .follow
        startShot = try c.decodeIfPresent(UUID.self, forKey: .startShot)
    }

    /// The NDI source in use, when the picture comes over NDI.
    var inputSource: String? { ndiSource.flatMap { $0.isEmpty ? nil : $0 } }

    /// Taking its own output as its input would feed it back on itself: the picture it sends is
    /// the channel it would receive. Compared by channel, since the computer half of an NDI name varies.
    var inputIsOwnOutput: Bool {
        guard let source = inputSource, let channel = NDIFeed.channel(source) else { return false }
        return channel.lowercased() == ndiName.lowercased()
    }

    var shot: ShotSize { ShotSize(rawValue: shotSize) ?? .waist }

    /// "Shot 1", "Shot 2"…: the first name not already used by a saved shot.
    var nextShotName: String {
        let used = Set(shots.map { $0.name.lowercased() })
        return (1...).lazy.map { "Shot \($0)" }.first { !used.contains($0.lowercased()) } ?? "Shot"
    }

    /// Group names as NDI wants them: comma separated, no spaces or empty names around them. Nil when none.
    static func cleanGroups(_ text: String?) -> String? {
        let names = (text ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return names.isEmpty ? nil : names.joined(separator: ",")
    }

    /// What the runtime does at the start: follow, hold the whole picture, or open on a saved
    /// shot (following when that shot is gone).
    var initialMode: VirtualMode {
        switch startMode {
        case .follow: return .follow
        case .wide: return .wide
        case .shot: return shots.first { $0.id == startShot }.map { .shot($0.crop) } ?? .follow
        }
    }

    /// The manual zoom limit the setup starts from: what the automatic limit gives for a 4K input
    /// sent out at 1080p (see CropPlanner.maxZoom).
    static let manualZoomDefault = CropPlanner.maxZoom(inputHeight: 2160, outputHeight: 1080)
    /// What the manual zoom slider allows: 1x is the whole picture, and 4x is just past the
    /// automatic limit for a 4K input sent out at 720p (3.75x).
    static let manualZoomRange = 1.0...4.0

    /// Whatever can only change by reopening the capture and the NDI output. A change to anything
    /// else (the name, saved shots, the shot size) is applied to the running camera, so saving a
    /// shot never drops a source that may be on air.
    var pipeline: String {
        [device, videoFile ?? "", inputSource ?? "", inputFormat ?? "", output.rawValue, ndiName, ndiGroups ?? "", sendUYVY ? "uyvy" : "", maxZoom.map { String($0) } ?? ""].joined(separator: "|")
    }
}
