import Darwin
import Foundation

/// Finding printers and bridges on the home Wi-Fi (server 0.25 / 0.34, Expo app `lib/lan/discover.ts`): nobody should
/// have to look up an IP address.
///  - Elegoo Centauri Carbon (stock firmware): SDCP UDP discovery, "M99999" to port 3000; every printer answers with
///    {"Data": {"Name", "MachineName", "BrandName", "MainboardIP", "FirmwareVersion", ...}}. iOS sends it to every
///    address of the /24 network (unicast): broadcasts need Apple's multicast entitlement.
///  - Klipper/Moonraker, PrusaLink, OctoPrint: a short HTTP probe of every address: Moonraker `GET /server/info`
///    (port 80 behind Mainsail/Fluidd/COSMOS, else 7125), PrusaLink `GET /api/v1/info` → 401 with digest realm
///    "Printer API", OctoPrint's web page. COSMOS by its macros (`_COSMOS_SETTINGS`).
///  - PocketPrint3D bridges (Raspberry Pi image on port 80, also `pocketprint3d.local`; bridge containers on 8484):
///    `GET /api/bridge/hello`.
enum Discovery {
    struct Wifi: Sendable, Equatable {
        var address: String
        var prefix: Int
    }

    enum Event: Sendable, Equatable {
        case found(FoundPrinter)
        case progress(done: Int, total: Int)
    }

    struct NoWifi: Error, Sendable {}

    /// A PocketPrint3D bridge answering `/api/bridge/hello`.
    struct FoundBridge: Sendable, Equatable, Identifiable {
        var address: String
        var name: String
        var version: String
        var bridgeId: String?
        var paired: Bool
        var account: String?
        var pairable: Bool
        var bridgeOnly: Bool
        var id: String { bridgeId ?? address }
    }

    // MARK: network

    /// The phone's IPv4 address on the Wi-Fi (en0) and its prefix length; nil when it isn't on a Wi-Fi.
    static func wifiAddress() -> Wifi? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == "en0", let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET), let mask = ifa.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            return Wifi(address: n2ip(UInt32(bigEndian: ip)), prefix: UInt32(bigEndian: m).nonzeroBitCount)
        }
        return nil
    }

    static func ip2n(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var n: UInt32 = 0
        for p in parts {
            guard let v = UInt32(p), v <= 255 else { return nil }
            n = n << 8 | v
        }
        return n
    }

    /// The Wi-Fi as a network for the bridge search ("192.168.86.0/24"): /24 ... /30, anything wider as /24 (Expo app
    /// `wifiSubnet`). nil for anything that isn't dotted IPv4.
    static func subnet(address: String, prefix: Int) -> String? {
        guard let own = ip2n(address) else { return nil }
        let p = max(24, min(30, prefix == 0 ? 24 : prefix))
        return "\(n2ip(own - own % (UInt32(1) << UInt32(32 - p))))/\(p)"
    }

    static func n2ip(_ n: UInt32) -> String { [24, 16, 8, 0].map { String((n >> UInt32($0)) & 255) }.joined(separator: ".") }

    /// Addresses to probe: at most the /24 around the phone's own address (bigger networks are rare at home and would
    /// take minutes), without the phone itself.
    static func subnetHosts(_ address: String, prefix: Int) -> [String] {
        guard let own = ip2n(address) else { return [] }
        let p = max(24, min(30, prefix == 0 ? 24 : prefix))
        let size = UInt32(1) << UInt32(32 - p)
        let net = own - own % size
        return (net + 1 ..< net + size - 1).filter { $0 != own }.map(n2ip)
    }

    // MARK: printers

    /// One SDCP discovery answer → printer (nil for anything else on that port).
    static func parseSdcp(address: String, data: Data) -> FoundPrinter? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let d = obj["Data"] as? [String: Any] ?? obj
        func s(_ k: String) -> String? { (d[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        guard s("MainboardID") != nil || s("MachineName") != nil || s("Name") != nil else { return nil }
        let ip = s("MainboardIP").flatMap { ip2n($0) != nil ? $0 : nil } ?? address
        let model = [s("BrandName"), s("MachineName")].compactMap { $0 }.joined(separator: " ")
        let detail = [model.isEmpty ? nil : model, s("FirmwareVersion")].compactMap { $0 }.joined(separator: " · ")
        return FoundPrinter(type: "elegoo_sdcp", address: ip, name: s("Name") ?? s("MachineName") ?? "Centauri Carbon",
                            detail: detail.isEmpty ? nil : detail)
    }

    struct Probe: Sendable {
        var status: Int
        var authenticate: String
        var text: String
        var json: [String: Any]? {
            guard status == 200, let d = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        c.timeoutIntervalForResource = 4
        c.httpMaximumConnectionsPerHost = 2
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func probe(_ url: String, timeout: TimeInterval = 1.5, session: URLSession = Discovery.session) async -> Probe? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.setValue("application/json, text/html", forHTTPHeaderField: "Accept")
        guard let answer = try? await session.data(for: req), let http = answer.1 as? HTTPURLResponse else { return nil }
        let data = answer.0
        // web pages can be big; the first 64 kB are enough to recognise them
        let text = String(decoding: data.prefix(65536), as: UTF8.self)
        return Probe(status: http.statusCode, authenticate: http.value(forHTTPHeaderField: "WWW-Authenticate") ?? "", text: text)
    }

    static func withPort(_ host: String, _ port: Int) -> String { port == 80 ? host : "\(host):\(port)" }

    /// What answers at this address? nil = no printer we know.
    static func identify(_ host: String, webPort: Int = 80, moonrakerPort: Int = 7125, timeout: TimeInterval = 1.5,
                         session: URLSession = Discovery.session) async -> FoundPrinter? {
        let web = "http://\(withPort(host, webPort))"
        let mr = "http://\(host):\(moonrakerPort)"
        async let a = probe("\(web)/server/info", timeout: timeout, session: session)
        async let b = probe("\(mr)/server/info", timeout: timeout, session: session)
        let (onWeb, onMr) = await (a, b)
        func isMoonraker(_ p: Probe?) -> Bool {
            guard let r = p?.json?["result"] as? [String: Any] else { return false }
            return r["klippy_state"] != nil || r["moonraker_version"] != nil || r["klippy_connected"] != nil
        }
        let base = isMoonraker(onWeb) ? web : isMoonraker(onMr) ? mr : nil
        if let base {
            async let o = probe("\(base)/printer/objects/list", timeout: timeout * 2, session: session)
            async let i = probe("\(base)/printer/info", timeout: timeout * 2, session: session)
            let (objs, info) = await (o, i)
            let objects = (objs?.json?["result"] as? [String: Any])?["objects"] as? [String] ?? []
            let cosmos = objects.contains { $0.range(of: "cosmos", options: .caseInsensitive) != nil }
            let hostname = ((info?.json?["result"] as? [String: Any])?["hostname"] as? String) ?? ""
            // MoonrakerPrinter tries the address and then :7125 itself
            let address = base == web ? withPort(host, webPort) : (moonrakerPort == 7125 ? host : "\(host):\(moonrakerPort)")
            return FoundPrinter(type: "moonraker", address: address,
                                name: cosmos ? "Centauri Carbon (COSMOS)" : hostname.isEmpty ? "Klipper" : hostname,
                                cosmos: cosmos, detail: cosmos ? "OpenCentauri COSMOS" : hostname.isEmpty ? nil : "Klipper")
        }
        guard let onWeb else { return nil }                     // nothing (or no web server) at this address
        if let pl = await probe("\(web)/api/v1/info", timeout: timeout, session: session), pl.status == 401,
           pl.authenticate.range(of: #"realm="?Printer API"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return FoundPrinter(type: "prusalink", address: withPort(host, webPort), name: "Prusa", detail: "PrusaLink")
        }
        var page: Probe? = onWeb
        if [401, 403, 404].contains(onWeb.status) { page = await probe("\(web)/", timeout: timeout, session: session) }
        if let page, page.text.range(of: "octoprint", options: .caseInsensitive) != nil {
            return FoundPrinter(type: "octoprint", address: withPort(host, webPort), name: "OctoPrint", detail: "OctoPrint")
        }
        return nil
    }

    /// SDCP discovery by unicast UDP: "M99999" to port 3000 of every host, answers collected for `timeout` seconds.
    static func sdcpProbe(hosts: [String], port: UInt16 = 3000, timeout: TimeInterval = 2.5) async -> [FoundPrinter] {
        await Task.detached(priority: .utility) { () -> [FoundPrinter] in
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return [] }
            defer { close(fd) }
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let message = Array("M99999".utf8)
            for host in hosts {
                guard let n = ip2n(host) else { continue }
                var to = sockaddr_in()
                to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                to.sin_family = sa_family_t(AF_INET)
                to.sin_port = port.bigEndian
                to.sin_addr.s_addr = n.bigEndian
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            var out: [FoundPrinter] = []
            let capacity = 8192
            var buffer = [UInt8](repeating: 0, count: capacity)
            let end = Date().addingTimeInterval(timeout)
            while Date() < end && !Task.isCancelled {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let got = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, capacity, 0, $0, &len) }
                }
                guard got > 0 else { continue }
                let address = n2ip(UInt32(bigEndian: from.sin_addr.s_addr))
                if let p = parseSdcp(address: address, data: Data(buffer[0 ..< got])),
                   !out.contains(where: { $0.address == p.address }) {
                    out.append(p)
                }
            }
            return out
        }.value
    }

    static func host(of address: String) -> String {
        address.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
    }

    /// Printers on the Wi-Fi, each reported as soon as it answers, plus progress. Finishes with an error `NoWifi` when
    /// the phone isn't on a Wi-Fi; cancelling the consuming task stops the scan.
    static func printers(hosts fixed: [String]? = nil, concurrency: Int = 24) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let hosts: [String]
                if let fixed {
                    hosts = fixed
                } else if let wifi = wifiAddress() {
                    hosts = subnetHosts(wifi.address, prefix: wifi.prefix)
                } else {
                    continuation.finish(throwing: NoWifi())
                    return
                }
                let seen = Seen()
                @Sendable func report(_ p: FoundPrinter?) async {
                    guard let p, !Task.isCancelled, await seen.insert(host(of: p.address)) else { return }
                    continuation.yield(.found(p))
                }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for p in await sdcpProbe(hosts: hosts) { await report(p) }
                    }
                    let queue = Queue(hosts)
                    let done = Counter()
                    for _ in 0 ..< max(1, concurrency) {
                        group.addTask {
                            while !Task.isCancelled, let h = await queue.next() {
                                // a Centauri found by UDP needs no HTTP probe (its web server is only the upload endpoint)
                                if await !seen.contains(h) { await report(await identify(h)) }
                                let n = await done.increment()
                                if n % 8 == 0 || n == hosts.count { continuation.yield(.progress(done: n, total: hosts.count)) }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: bridges

    /// `GET /api/bridge/hello` (no token) at one address; only bridges count, not other PocketPrint3D servers.
    static func bridgeHello(_ base: String, timeout: TimeInterval = 1.5, session: URLSession = Discovery.session) async -> FoundBridge? {
        guard let h = await probe("\(base)/api/bridge/hello", timeout: timeout, session: session)?.json,
              h["pocketprint3d"] as? String == "bridge" else { return nil }
        let name = (h["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "PocketPrint3D"
        return FoundBridge(address: base, name: name, version: h["version"] as? String ?? "",
                           bridgeId: h["bridge_id"] as? String, paired: h["paired"] as? Bool ?? false,
                           account: h["account"] as? String, pairable: h["pairable"] as? Bool ?? false,
                           bridgeOnly: h["bridge_only"] as? Bool ?? false)
    }

    /// The pairing code of a found bridge - it hands it out only on its home network (server: /api/bridge/local-code).
    static func bridgeLocalCode(_ base: String, session: URLSession = Discovery.session) async throws -> String {
        guard let u = URL(string: "\(base)/api/bridge/local-code") else { throw LanError("bad address") }
        var req = URLRequest(url: u, timeoutInterval: 8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status), let code = body["code"] as? String else {
            throw LanError((body["detail"] as? String) ?? "HTTP \(status)")
        }
        return code
    }

    /// Bridges on the phone's network: the Pi image answers on port 80 (also as pocketprint3d.local), a bridge
    /// container on 8484.
    static func bridges(hosts fixed: [String]? = nil, ports: [Int] = [80, 8484],
                        concurrency: Int = 24) -> AsyncThrowingStream<FoundBridge, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let hosts: [String]
                if let fixed {
                    hosts = fixed
                } else if let wifi = wifiAddress() {
                    hosts = subnetHosts(wifi.address, prefix: wifi.prefix)
                } else {
                    continuation.finish(throwing: NoWifi())
                    return
                }
                let seen = Seen()
                @Sendable func report(_ b: FoundBridge?) async {
                    guard let b, !Task.isCancelled, await seen.insert(b.id) else { return }
                    continuation.yield(b)
                }
                await withTaskGroup(of: Void.self) { group in
                    if fixed == nil {
                        group.addTask { await report(await bridgeHello("http://pocketprint3d.local")) }
                    }
                    let queue = Queue(hosts)
                    for _ in 0 ..< max(1, concurrency) {
                        group.addTask {
                            while !Task.isCancelled, let h = await queue.next() {
                                for port in ports { await report(await bridgeHello("http://\(withPort(h, port))")) }
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private actor Seen {
        var keys = Set<String>()
        func insert(_ k: String) -> Bool { keys.insert(k).inserted }
        func contains(_ k: String) -> Bool { keys.contains(k) }
    }

    private actor Queue {
        var items: [String]
        var index = 0
        init(_ items: [String]) { self.items = items }
        func next() -> String? {
            guard index < items.count else { return nil }
            defer { index += 1 }
            return items[index]
        }
    }

    private actor Counter {
        var n = 0
        func increment() -> Int { n += 1; return n }
    }
}
