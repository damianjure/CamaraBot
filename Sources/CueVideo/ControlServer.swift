import Foundation
import Network

/// A small HTTP interface so other software (the CueVideo MCP server that Claude uses, and
/// Companion) can do anything the app's screens can. It listens on 127.0.0.1 only, unless
/// "Allow control from other computers" is on in Setup, which is kept in this Mac's preferences
/// (not the config file, so nothing that edits the config over the network can turn it on).
/// Every request, from this Mac or the network, must carry the key saved in
/// ~/Library/Application Support/CueVideo/control-token.
///
///     GET  /tools                       the tool list (MCP tool definitions)
///     POST /call  {"name": ..., "arguments": {...}}   run one tool, returns its result
final class ControlServer: ObservableObject {
    static let shared = ControlServer()
    /// 9911. A self-test may name its own port (CUEVIDEO_CONTROL_PORT) so it never meets the real app's.
    static let port: UInt16 = ProcessInfo.processInfo.environment["CUEVIDEO_CONTROL_PORT"].flatMap(UInt16.init) ?? 9911
    private static let networkKey = "controlOnNetwork"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cuevideo.control")
    private(set) var token = ""
    @Published private(set) var running = false
    /// Whether computers on the network may connect (always with the key). Off by default.
    @Published private(set) var onNetwork = UserDefaults.standard.bool(forKey: networkKey)
    /// Read on the control queue, which can't touch the published value.
    private var allowNetwork = UserDefaults.standard.bool(forKey: networkKey)

    static var tokenURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueVideo", isDirectory: true).appendingPathComponent("control-token")
    }

    func start() {
        token = Self.loadOrMakeToken()
        let network = allowNetwork
        queue.async { self.listen(network: network) }
    }

    /// Turn network control on or off. Saved on this Mac and applied straight away.
    func setOnNetwork(_ on: Bool) {
        guard on != onNetwork else { return }
        onNetwork = on
        UserDefaults.standard.set(on, forKey: Self.networkKey)
        queue.async {
            self.allowNetwork = on
            if self.listener != nil { self.listen(network: on) }
        }
    }

    /// On the control queue: (re)open the listener on 127.0.0.1, or on every network interface.
    private func listen(network: Bool, tries: Int = 0) {
        listener?.cancel()
        listener = nil
        setRunning(false)
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let port = NWEndpoint.Port(rawValue: Self.port)!
            let l: NWListener
            if network {
                l = try NWListener(using: params, on: port)
            } else {
                params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
                l = try NWListener(using: params)
            }
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self, weak l] s in
                guard let self, let l, l === self.listener else { return }
                if case .ready = s { self.setRunning(true) }
                if case .failed(let e) = s {
                    self.setRunning(false)
                    print("CueVideo control server stopped: \(e)")
                    // The port may still be held by the listener just closed; try again a few times.
                    guard tries < 5 else { return }
                    self.queue.asyncAfter(deadline: .now() + 1) {
                        if l === self.listener { self.listen(network: self.allowNetwork, tries: tries + 1) }
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            print("CueVideo control server didn't start: \(error)")
        }
    }

    private func setRunning(_ on: Bool) { DispatchQueue.main.async { self.running = on } }

    /// This Mac's addresses on the local network (IPv4), for typing into Companion on another computer.
    static func networkAddresses() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let a = i.ifa_addr, a.pointee.sa_family == UInt8(AF_INET),
                  i.ifa_flags & UInt32(IFF_UP) != 0, i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: host)
                if !s.hasPrefix("169.254.") && !out.contains(s) { out.append(s) }
            }
        }
        return out
    }

    /// A random key, made once and kept readable only by this user.
    private static func loadOrMakeToken() -> String {
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.createDirectory(at: tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }

    // MARK: Minimal HTTP

    private func serve(_ c: NWConnection) {
        // A connection from the network that got in while network control was being turned off.
        if !allowNetwork, !Self.isLoopback(c.endpoint) { c.cancel(); return }
        c.start(queue: queue)
        receive(c, Data())
    }

    static func isLoopback(_ e: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = e else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || a.asIPv4?.isLoopback == true
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    /// Compares the whole key whatever it holds, so timing doesn't hint how much of a guess was right.
    static func sameKey(_ given: String?, _ key: String) -> Bool {
        guard let given, !key.isEmpty else { return false }
        let a = Array(given.utf8), b = Array(key.utf8)
        var diff = a.count ^ b.count
        for i in 0..<b.count { diff |= Int((i < a.count ? a[i] : 0) ^ b[i]) }
        return diff == 0
    }

    private func receive(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = got
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.handle(req) { status, body in self.reply(c, status, body) }
            } else if done || err != nil || buf.count > 4 << 20 {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }

    /// A whole request, or nil while more bytes are needed.
    private static func parse(_ d: Data) -> Request? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[d.startIndex..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return Request(method: "", path: "", headers: [:], body: Data()) }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard d.distance(from: bodyStart, to: d.endIndex) >= len else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers,
                       body: d.subdata(in: bodyStart..<d.index(bodyStart, offsetBy: len)))
    }

    private func reply(_ c: NWConnection, _ status: Int, _ body: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let text = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : "Bad Request"))
        var head = "HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        if status == 0 { head = "" }
        c.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in c.cancel() })
    }

    private func handle(_ r: Request, _ done: @escaping (Int, Any) -> Void) {
        guard Self.sameKey(r.headers["x-cuevideo-token"], token) else { done(401, ["error": "Missing or wrong key."]); return }
        switch (r.method, r.path) {
        case ("GET", "/tools"):
            DispatchQueue.main.async { done(200, ["tools": ControlTools.definitions]) }
        case ("POST", "/call"):
            guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any], let name = obj["name"] as? String else {
                done(400, ["error": "Send {\"name\": tool, \"arguments\": {...}}."]); return
            }
            let args = obj["arguments"] as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                ControlTools.call(name, args) { result in done(200, result) }
            }
        default:
            done(404, ["error": "Use GET /tools or POST /call."])
        }
    }
}
