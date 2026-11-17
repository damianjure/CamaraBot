import Foundation

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
    /// Which format to ask the device for, as "3840x2160". Nil takes the largest it offers.
    var inputFormat: String?
    var output: OutputSize = .p1080
    /// The NDI source name: other computers see "<this Mac> (<ndiName>)".
    var ndiName: String
    /// The tightest zoom. Nil works it out from the input and output sizes.
    var maxZoom: Double?
    /// The shot the follow mode frames: "shoulders", "waist" or "full".
    var shotSize = "waist"
    /// Saved framings to go to by name.
    var shots: [CropShot] = []
    /// Set when this output also feeds an ATEM input (through an NDI converter), for reference.
    var atemInput: Int?

    init(id: UUID = UUID(), name: String = "Virtual camera", device: String, ndiName: String) {
        self.id = id
        self.name = name
        self.device = device
        self.ndiName = ndiName
    }

    private enum Keys: String, CodingKey { case id, name, enabled, device, inputFormat, output, ndiName, maxZoom, shotSize, shots, atemInput }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Virtual camera"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        device = try c.decode(String.self, forKey: .device)
        inputFormat = try c.decodeIfPresent(String.self, forKey: .inputFormat)
        output = try c.decodeIfPresent(OutputSize.self, forKey: .output) ?? .p1080
        ndiName = try c.decodeIfPresent(String.self, forKey: .ndiName) ?? name
        maxZoom = try c.decodeIfPresent(Double.self, forKey: .maxZoom)
        shotSize = try c.decodeIfPresent(String.self, forKey: .shotSize) ?? "waist"
        shots = try c.decodeIfPresent([CropShot].self, forKey: .shots) ?? []
        atemInput = try c.decodeIfPresent(Int.self, forKey: .atemInput)
    }

    var shot: ShotSize { ShotSize(rawValue: shotSize) ?? .waist }

    /// Whatever can only change by reopening the capture and the NDI output. A change to anything
    /// else (the name, saved shots, the shot size) is applied to the running camera, so saving a
    /// shot never drops a source that may be on air.
    var pipeline: String {
        [device, inputFormat ?? "", output.rawValue, ndiName, maxZoom.map { String($0) } ?? ""].joined(separator: "|")
    }
}
