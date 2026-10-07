import Foundation
import Network
import Security

/// MQTT 3.1.1, only what Bambu printers need: CONNECT with user/password, one SUBSCRIBE, PUBLISH with QoS 0, PING.
/// Bambu: TLS on port 8883, user "bblp", password = access code; reports on device/<serial>/report, commands to
/// device/<serial>/request (Expo app `modules/bambu-lan` BambuMqtt, server `printers/bambu.py`).
enum MQTT {
    enum Packet: Equatable {
        case connack(code: UInt8)
        case suback
        case publish(topic: String, payload: Data)
        case pingresp
        case other(UInt8)
    }

    struct Malformed: Error {}

    static func remainingLength(_ n: Int) -> [UInt8] {
        var n = n, out: [UInt8] = []
        repeat {
            var b = UInt8(n % 128)
            n /= 128
            if n > 0 { b |= 0x80 }
            out.append(b)
        } while n > 0
        return out
    }

    static func string(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        return [UInt8(b.count >> 8), UInt8(b.count & 0xFF)] + b
    }

    static func packet(_ type: UInt8, _ body: [UInt8]) -> Data { Data([type] + remainingLength(body.count) + body) }

    static func connect(clientId: String, user: String, password: String, keepAlive: UInt16 = 30) -> Data {
        // protocol "MQTT" level 4; flags: user name, password, clean session
        let header = string("MQTT") + [4, 0xC2, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)]
        return packet(0x10, header + string(clientId) + string(user) + string(password))
    }

    static func subscribe(packetId: UInt16, topic: String) -> Data {
        packet(0x82, [UInt8(packetId >> 8), UInt8(packetId & 0xFF)] + string(topic) + [0])
    }

    static func publish(topic: String, payload: Data) -> Data { packet(0x30, string(topic) + Array(payload)) }

    static let pingreq = Data([0xC0, 0])
    static let disconnect = Data([0xE0, 0])

    /// Takes the complete packets off the front of `buffer`; an incomplete one stays for the next call.
    static func parse(_ buffer: inout [UInt8]) throws -> [Packet] {
        var out: [Packet] = []
        while buffer.count >= 2 {
            var length = 0, multiplier = 1, i = 1
            while true {
                guard i < buffer.count else { return out }          // length not complete yet
                let b = buffer[i]
                length += Int(b & 0x7F) * multiplier
                i += 1
                if b & 0x80 == 0 { break }
                multiplier *= 128
                guard i <= 4 else { throw Malformed() }
            }
            guard buffer.count >= i + length else { return out }
            let type = buffer[0]
            let body = Array(buffer[i ..< i + length])
            buffer.removeFirst(i + length)
            switch type >> 4 {
            case 2:
                guard body.count >= 2 else { throw Malformed() }
                out.append(.connack(code: body[1]))
            case 9: out.append(.suback)
            case 13: out.append(.pingresp)
            case 3:
                guard body.count >= 2 else { throw Malformed() }
                let n = Int(body[0]) << 8 | Int(body[1])
                guard body.count >= 2 + n else { throw Malformed() }
                let topic = String(decoding: body[2 ..< 2 + n], as: UTF8.self)
                let qos = (type >> 1) & 3
                let start = 2 + n + (qos > 0 ? 2 : 0)                 // packet id only with QoS 1/2
                guard body.count >= start else { throw Malformed() }
                out.append(.publish(topic: topic, payload: Data(body[start...])))
            default: out.append(.other(type))
            }
        }
        return out
    }
}

/// TLS details of Bambu printers: their certificates come from Bambu's own CA and name the serial number, not the
/// address, so they are accepted as they are (like Bambu Studio and the server do).
enum BambuNet {
    struct Cert: Sendable, Equatable {
        var serial: String
        var issuer: String
        var bambu: Bool { issuer.uppercased().contains("BBL") || issuer.uppercased().contains("BAMBU") }
    }

    static func parameters(tls: Bool, timeout: TimeInterval, queue: DispatchQueue,
                           onTrust: (@Sendable (SecTrust) -> Void)? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcp.noDelay = true
        guard tls else { return NWParameters(tls: nil, tcp: tcp) }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            onTrust?(sec_trust_copy_ref(trust).takeRetainedValue())
            complete(true)
        }, queue)
        return NWParameters(tls: options, tcp: tcp)
    }

    /// Common name of the subject (the serial number) and the issuer of the leaf certificate.
    static func cert(_ trust: SecTrust) -> Cert? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        var cn: CFString?
        SecCertificateCopyCommonName(leaf, &cn)
        // the issuer as DER: the CA's name is plain text in it ("BBL CA", "BBL Technologies Co., Ltd")
        let issuer = SecCertificateCopyNormalizedIssuerSequence(leaf).map {
            String(decoding: ($0 as Data).map { (0x20 ... 0x7E).contains($0) ? $0 : 0x20 }, as: UTF8.self)
        } ?? ""
        return Cert(serial: (cn as String?) ?? "", issuer: issuer)
    }

    /// The printer's certificate on the MQTT port, nil when nothing answers there with TLS.
    static func readCert(host: String, port: UInt16 = 8883, timeout: TimeInterval = 4) async -> Cert? {
        guard let p = NWEndpoint.Port(rawValue: port) else { return nil }
        let queue = DispatchQueue(label: "bambu.cert")
        let box = Box<Cert?>(nil)
        let params = parameters(tls: true, timeout: timeout, queue: queue) { box.value = cert($0) }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        return await withCheckedContinuation { (cont: CheckedContinuation<Cert?, Never>) in
            let once = Once()
            @Sendable func finish(_ v: Cert?) {
                guard once.first() else { return }
                c.cancel()
                cont.resume(returning: v)
            }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(box.value)
                case .failed, .waiting, .cancelled: finish(nil)       // waiting = refused / unreachable
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    /// Bambu printers among `hosts` (address, serial); 32 at a time, a closed port answers fast.
    static func probe(hosts: [String], port: UInt16 = 8883, timeout: TimeInterval = 2) async -> [(address: String, serial: String)] {
        await withTaskGroup(of: (String, String)?.self) { group in
            var out: [(address: String, serial: String)] = []
            var next = 0
            while next < min(32, hosts.count) {
                group.addTask { [h = hosts[next]] in await bambu(h, port: port, timeout: timeout) }
                next += 1
            }
            while let r = await group.next() {
                if let r { out.append((address: r.0, serial: r.1)) }
                if next < hosts.count {
                    group.addTask { [h = hosts[next]] in await bambu(h, port: port, timeout: timeout) }
                    next += 1
                }
            }
            return out
        }
    }

    private static func bambu(_ host: String, port: UInt16, timeout: TimeInterval) async -> (String, String)? {
        guard let c = await readCert(host: host, port: port, timeout: timeout), c.bambu else { return nil }
        return (host, c.serial)
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ v: T) { stored = v }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }
}

/// One MQTT connection to a Bambu printer, kept open: the P1 series sends the full state only once ("pushall") and
/// afterwards only what changed, which is merged into `report` here.
final class BambuLink: @unchecked Sendable {
    let host: String
    let serial: String
    let code: String
    private let port: UInt16
    private let tls: Bool
    private let queue = DispatchQueue(label: "bambu.mqtt")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var report: [String: Any] = [:]
    private var replies: [String: (at: Date, msg: [String: Any])] = [:]
    private var pending: CheckedContinuation<Void, Error>?
    private var ping: DispatchSourceTimer?
    private var isConnected = false
    private var lastError: String?

    init(host: String, serial: String, code: String, port: UInt16 = 8883, tls: Bool = true) {
        self.host = host; self.serial = serial; self.code = code; self.port = port; self.tls = tls
    }

    var connected: Bool { lock.withLock { isConnected } }
    var error: String? { lock.withLock { lastError } }

    /// Reads the merged report under the lock.
    func read<T>(_ body: ([String: Any]) -> T) -> T { lock.withLock { body(report) } }

    /// The last answer to a command ("project_file" …) with the time it arrived.
    func reply(_ command: String) -> (at: Date, msg: [String: Any])? { lock.withLock { replies[command] } }

    /// Connects, logs in and subscribes; throws when the printer can't be reached or refuses the access code.
    func open(timeout: TimeInterval = 10) async throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw LanError("bad port") }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p,
                             using: BambuNet.parameters(tls: tls, timeout: timeout, queue: queue))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.withLock {
                pending = cont
                connection = c
                buffer = []
            }
            c.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let id = "pp3d-ios-\(self.serial.suffix(6))-\(Int.random(in: 0 ..< 100_000))"
                    self.send(MQTT.connect(clientId: id, user: "bblp", password: self.code))
                    self.receive()
                case .waiting, .failed:
                    self.fail("printer not reachable on the Wi-Fi - is it on, in LAN-only mode?")
                case .cancelled:
                    self.fail("connection closed")
                default: break
                }
            }
            c.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.lock.withLock({ self.pending != nil }) else { return }
                self.fail("no answer from the printer")
            }
        }
    }

    private func send(_ data: Data) {
        let c = lock.withLock { connection }
        c?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(error.localizedDescription) }
        })
    }

    private func receive() {
        let c = lock.withLock { connection }
        c?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.feed(data) }
            if let error { return self.fail(error.localizedDescription) }
            if done { return self.fail("the printer closed the connection") }
            self.receive()
        }
    }

    private func feed(_ data: Data) {
        let packets: [MQTT.Packet]
        do {
            packets = try lock.withLock {
                buffer.append(contentsOf: data)
                return try MQTT.parse(&buffer)
            }
        } catch {
            return fail("unexpected data from the printer")
        }
        for packet in packets {
            switch packet {
            case .connack(let rc):
                // 4 = bad user name or password, 5 = not authorised
                guard rc == 0 else { return fail(rc == 4 || rc == 5 ? "the printer refused the access code" : "MQTT error \(rc)") }
                send(MQTT.subscribe(packetId: 1, topic: "device/\(serial)/report"))
                publishNow(["pushing": ["command": "pushall"]])
                publishNow(["info": ["command": "get_version"]])
                startPing()
                let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    isConnected = true
                    lastError = nil
                    defer { pending = nil }
                    return pending
                }
                cont?.resume()
            case .publish(_, let payload):
                guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                      let p = obj["print"] as? [String: Any] else { continue }
                lock.withLock {
                    if let cmd = p["command"] as? String, cmd != "push_status" { replies[cmd] = (Date(), p) }
                    BambuState.merge(&report, p)
                }
            default: break
            }
        }
    }

    private func startPing() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in self?.send(MQTT.pingreq) }
        t.resume()
        lock.withLock {
            ping?.cancel()
            ping = t
        }
    }

    private func publishNow(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        send(MQTT.publish(topic: "device/\(serial)/request", payload: data))
    }

    /// `{"print": {...}}` etc. to the printer.
    func publish(_ obj: [String: Any]) async throws {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { throw LanError("bad command") }
        guard let c = lock.withLock({ isConnected ? connection : nil }) else { throw LanError(error ?? "not connected to the printer") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            c.send(content: MQTT.publish(topic: "device/\(serial)/request", payload: data), completion: .contentProcessed { error in
                if let error { cont.resume(throwing: LanError(error.localizedDescription)) } else { cont.resume() }
            })
        }
    }

    private func fail(_ message: String) {
        let (cont, c, timer) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, NWConnection?, DispatchSourceTimer?) in
            let out = (pending, connection, ping)
            pending = nil
            connection = nil
            ping = nil
            if isConnected || out.0 != nil { lastError = message }
            isConnected = false
            return out
        }
        timer?.cancel()
        c?.stateUpdateHandler = nil
        c?.cancel()
        cont?.resume(throwing: LanError(message))
    }

    func close() {
        let c = lock.withLock { connection }
        c?.send(content: MQTT.disconnect, completion: .idempotent)
        fail("connection closed")
    }
}
