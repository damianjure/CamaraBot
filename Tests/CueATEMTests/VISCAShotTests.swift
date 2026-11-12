import XCTest
import Network
import CueATEM

/// Saved shots on VISCA cameras: saving stores the camera's position in one of its own presets
/// (CAM_Memory Set, 81 01 04 3F 01 pp FF) and recalling sends CAM_Memory Recall
/// (81 01 04 3F 02 pp FF) for that preset, numbered like the preset buttons.
final class VISCAShotTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "ptzCameras")
    }

    private func wait(_ seconds: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func set(_ b: UInt8) -> [UInt8] { [0x81, 0x01, 0x04, 0x3F, 0x01, b, 0xFF] }
    private static func recall(_ b: UInt8) -> [UInt8] { [0x81, 0x01, 0x04, 0x3F, 0x02, b, 0xFF] }

    /// A controller with one VISCA over IP camera on a pretend camera, answering.
    private func rig(firstPreset: Int = 0, names: [Int: String] = [:]) throws -> (PTZController, PTZCamera, FakeVISCAMemoryCamera) {
        let fake = try FakeVISCAMemoryCamera()
        var cam = PTZCamera(); cam.name = "Center"; cam.host = "127.0.0.1"; cam.port = fake.port; cam.proto = .sonyUDP
        cam.firstPreset = firstPreset; cam.presetNames = names
        let ptz = PTZController(load: false)
        ptz.cameras = [cam]
        wait(3) { ptz.online.contains(cam.id) }
        XCTAssertTrue(ptz.online.contains(cam.id), "the pretend camera never answered")
        return (ptz, cam, fake)
    }

    private func save(_ ptz: PTZController, _ cam: PTZCamera, _ name: String, replacing: UUID? = nil) -> Bool {
        var result: Bool?
        ptz.saveShot(name, camera: cam.id, replacing: replacing) { result = $0 }
        wait(2) { result != nil }
        return result ?? false
    }

    private func shot(_ ptz: PTZController, _ name: String) -> PTZShot? {
        ptz.cameras.first?.shots.first { $0.name == name }
    }

    /// A camera that counts presets from 0: shot preset 9 is byte 08 on the wire.
    func testSaveAndRecallUseTheSamePresetCountingFromZero() throws {
        let (ptz, cam, fake) = try rig()
        XCTAssertTrue(save(ptz, cam, "Pulpit"))
        wait(1) { fake.commands.contains(Self.set(0x08)) }
        XCTAssertEqual(fake.commands.last, Self.set(0x08), "saving should send Memory Set for preset 9")
        let s = try XCTUnwrap(shot(ptz, "Pulpit"))
        XCTAssertEqual(s.preset, 9)

        ptz.go(to: s, camera: cam.id)
        wait(1) { fake.commands.last == Self.recall(0x08) }
        XCTAssertEqual(fake.commands.last, Self.recall(0x08), "recalling should send Memory Recall for preset 9")

        ptz.recall(9, camera: cam.id)             // the preset button with the same number
        wait(1) { fake.commands.filter { $0 == Self.recall(0x08) }.count == 2 }
        XCTAssertEqual(fake.commands.last, Self.recall(0x08), "preset button 9 and the shot in preset 9 should send the same bytes")
    }

    /// A camera that counts presets from 1: the same shot is byte 09, exactly as preset button 9 is.
    func testCameraCountingFromOneMapsShotsLikePresetButtons() throws {
        let (ptz, cam, fake) = try rig(firstPreset: 1)
        XCTAssertTrue(save(ptz, cam, "Pulpit"))
        wait(1) { fake.commands.contains(Self.set(0x09)) }
        XCTAssertEqual(fake.commands.last, Self.set(0x09))
        ptz.go(to: try XCTUnwrap(shot(ptz, "Pulpit")), camera: cam.id)
        wait(1) { fake.commands.last == Self.recall(0x09) }
        XCTAssertEqual(fake.commands.last, Self.recall(0x09))
        ptz.recall(9, camera: cam.id)
        wait(1) { fake.commands.filter { $0 == Self.recall(0x09) }.count == 2 }
        XCTAssertEqual(fake.commands.filter { $0 == Self.recall(0x09) }.count, 2)
    }

    /// Shots take free presets from 9 up, skip numbers that are named, and saving over a shot
    /// reuses its preset.
    func testShotsTakeFreePresetsAndReplaceKeepsTheirs() throws {
        let (ptz, cam, fake) = try rig(names: [10: "Choir"])
        XCTAssertTrue(save(ptz, cam, "Pulpit"))
        XCTAssertTrue(save(ptz, cam, "Band"))
        XCTAssertEqual(shot(ptz, "Pulpit")?.preset, 9)
        XCTAssertEqual(shot(ptz, "Band")?.preset, 11, "preset 10 is named on the camera, so it's skipped")

        let pulpit = try XCTUnwrap(shot(ptz, "Pulpit"))
        XCTAssertTrue(save(ptz, cam, "", replacing: pulpit.id))
        wait(1) { fake.commands.filter { $0 == Self.set(0x08) }.count == 2 }
        XCTAssertEqual(fake.commands.filter { $0 == Self.set(0x08) }.count, 2, "replacing should store the same preset again")
        XCTAssertEqual(ptz.cameras.first?.shots.count, 2, "replacing should not add a shot")
    }

    /// A VISCA shot with no preset (written into the setup file by hand) can't move the camera,
    /// and says so instead of sending something.
    func testShotWithoutPresetSendsNothing() throws {
        let (ptz, cam, fake) = try rig()
        let handWritten = PTZShot(name: "Old", PTZPosition(pan: 100, tilt: 0, zoom: 0))
        XCTAssertFalse(ptz.canRecall(handWritten, on: cam))
        let before = fake.commands.count
        ptz.go(to: handWritten, camera: cam.id)
        wait(0.5)
        XCTAssertEqual(fake.commands.count, before)
    }

    /// Nothing is saved when the camera isn't answering.
    func testSaveFailsWhenTheCameraIsNotAnswering() {
        var cam = PTZCamera(); cam.host = "127.0.0.1"; cam.port = 9; cam.proto = .sonyUDP   // nothing listens on 9
        let ptz = PTZController(load: false)
        ptz.cameras = [cam]
        XCTAssertFalse(save(ptz, cam, "Pulpit"))
        XCTAssertTrue(ptz.cameras.first?.shots.isEmpty ?? false)
    }
}

/// A pretend VISCA over IP camera that answers every command (ACK, then completion) and logs
/// the VISCA bytes of each command it gets (not inquiries).
final class FakeVISCAMemoryCamera {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.visca.memory")
    private let lock = NSLock()
    private var _commands: [[UInt8]] = []
    private(set) var port: UInt16 = 0

    var commands: [[UInt8]] { lock.lock(); defer { lock.unlock() }; return _commands }

    init() throws {
        listener = try NWListener(using: .udp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: self.queue)
            self.receive(c)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let p = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        port = p
    }

    deinit { listener.cancel() }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, err in
            guard let self else { return }
            if let data, data.count >= 8 {
                let b = [UInt8](data)
                if b[0] == 0x01 {
                    let v = Array(b.dropFirst(8))
                    if v.count > 1, v[1] == 0x01 { self.lock.lock(); self._commands.append(v); self.lock.unlock() }
                    let seq = Array(b[4..<8])
                    c.send(content: Data([0x01, 0x11, 0, 3] + seq + [0x90, 0x41, 0xFF]), completion: .idempotent)
                    c.send(content: Data([0x01, 0x11, 0, 3] + seq + [0x90, 0x51, 0xFF]), completion: .idempotent)
                } else if b[0] == 0x02 {
                    c.send(content: Data([0x02, 0x01, 0, 1, 0, 0, 0, 0, 0x01]), completion: .idempotent)
                }
            }
            if err == nil { self.receive(c) }
        }
    }
}
