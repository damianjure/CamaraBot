import XCTest
import Network
@testable import CueVideo

/// The control server's two gates: the key, and which addresses count as this Mac.
final class ControlServerTests: XCTestCase {

    func testKeyMustMatchExactly() {
        let key = "3f9a0c1b2d4e5f60718293a4b5c6d7e8f9011223344556677"
        XCTAssertTrue(ControlServer.sameKey(key, key))
        XCTAssertFalse(ControlServer.sameKey(nil, key), "no key")
        XCTAssertFalse(ControlServer.sameKey("", key), "empty key")
        XCTAssertFalse(ControlServer.sameKey(String(key.dropLast()), key), "one character short")
        XCTAssertFalse(ControlServer.sameKey(key + "0", key), "one character long")
        XCTAssertFalse(ControlServer.sameKey(String(key.dropLast()) + "8", key), "last character wrong")
        XCTAssertFalse(ControlServer.sameKey(key, ""), "an empty server key never matches")
    }

    func testOnlyLoopbackCountsAsThisMac() {
        func ep(_ h: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(h), port: 9911) }
        XCTAssertTrue(ControlServer.isLoopback(ep("127.0.0.1")))
        XCTAssertTrue(ControlServer.isLoopback(ep("::1")))
        XCTAssertTrue(ControlServer.isLoopback(ep("::ffff:127.0.0.1")))
        XCTAssertFalse(ControlServer.isLoopback(ep("192.168.20.50")))
        XCTAssertFalse(ControlServer.isLoopback(ep("fe80::1")))
    }
}
