import Foundation

/// The phone's Wi-Fi as a network ("192.168.86.0/24"). A bridge in Docker's bridge network can't see the home network
/// itself, so the app tells it where to look (server 0.35.1, `POST /api/bridges/<id>/discover {"subnet"}`). Same rules
/// as the Expo app's `wifiSubnet` (`lib/lan/discover.ts`): /24 ... /30, anything wider is searched as /24.
enum WifiSubnet {
    /// `address` dotted IPv4, `prefix` = length of the netmask. nil for anything that isn't IPv4.
    static func subnet(address: String, prefix: Int) -> String? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt32($0) }
        guard parts.count == 4, address.split(separator: ".", omittingEmptySubsequences: false).count == 4,
              parts.allSatisfy({ $0 < 256 }) else { return nil }
        let p = max(24, min(30, prefix == 0 ? 24 : prefix))
        let ip = parts.reduce(UInt32(0)) { $0 << 8 | $1 }
        let net = ip & (UInt32.max << UInt32(32 - p))
        let dotted = (0..<4).map { String((net >> UInt32(24 - 8 * $0)) & 0xFF) }.joined(separator: ".")
        return "\(dotted)/\(p)"
    }

    /// The Wi-Fi interface (`en0`), or nil without Wi-Fi (mobile data only).
    static func current() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard String(cString: entry.pointee.ifa_name) == "en0",
                  let addr = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let dotted = (0..<4).map { String((ip >> UInt32(24 - 8 * $0)) & 0xFF) }.joined(separator: ".")
            return subnet(address: dotted, prefix: netmask.nonzeroBitCount)
        }
        return nil
    }
}
