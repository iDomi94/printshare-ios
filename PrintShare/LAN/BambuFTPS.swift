import Darwin
import Foundation
import Security

/// Upload of the print file to a Bambu printer's SD card.
protocol BambuUploading: Sendable {
    /// Blocking: call it off the main thread. `progress` gets 0...1 of the file.
    func upload(host: String, code: String, file: URL, remoteName: String, progress: (@Sendable (Double) -> Void)?) throws
}

/// FTPS with implicit TLS on port 990, user "bblp" + access code (Expo app `modules/bambu-lan` BambuCore.upload,
/// server `printers/bambu.py`, checked there on a P1S): the data channel must resume the control channel's TLS session
/// (the printer refuses a fresh one) and the printer never answers the TLS close of the data channel.
///
/// SecureTransport is used because it is the only TLS API on iOS that lets a second connection resume a session on
/// purpose (`SSLSetPeerID`, the same "host:990" key on both channels, like the Android app's
/// `createSocket(raw, host, 990, true)`); Network.framework keys its session cache itself. `tls: false` is plain FTP
/// for the tests.
struct BambuFTPS: BambuUploading {
    var port: UInt16 = 990
    var tls = true
    var timeout: TimeInterval = 30

    @available(iOS, deprecated: 13.0, message: "SecureTransport, see the type's comment")
    func upload(host: String, code: String, file: URL, remoteName: String, progress: (@Sendable (Double) -> Void)?) throws {
        let peer = "\(host):\(port)"
        let control = try FTPChannel(host: host, port: port, timeout: timeout)
        defer { control.close() }
        if tls { try control.startTLS(peerID: peer) }
        let hello = try control.reply()
        guard hello.hasPrefix("220") else { throw LanError("FTP: \(hello)") }
        try control.command("USER bblp", expect: "331")
        do {
            try control.command("PASS \(code)", expect: "230")
        } catch {
            throw LanError("the printer refused the access code")
        }
        if tls {
            try control.command("PBSZ 0", expect: "200")
            try control.command("PROT P", expect: "200")
        }
        try control.command("TYPE I", expect: "200")
        let pasv = try control.command("PASV", expect: "227")
        let nums = pasv.firstMatch(#"(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)"#)
        guard nums.count == 7, let hi = Int(nums[5]), let lo = Int(nums[6]) else { throw LanError("FTP: unexpected PASV answer") }
        // the control host, not the address in the PASV answer
        let data = try FTPChannel(host: host, port: UInt16(truncatingIfNeeded: hi * 256 + lo), timeout: timeout)
        defer { data.close() }
        let started = try control.command("STOR \(remoteName)", expect: "1")
        guard started.hasPrefix("150") || started.hasPrefix("125") else { throw LanError("FTP: \(started)") }
        if tls { try data.startTLS(peerID: peer) }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var sent = 0.0
        while let chunk = try input.read(upToCount: 1 << 16), !chunk.isEmpty {
            try data.write(chunk)
            sent += Double(chunk.count)
            if size > 0 { progress?(min(1, sent / size)) }
        }
        // no TLS close on the data channel: the printer never answers it - just end the TCP connection
        data.close()
        let done = try control.reply()
        guard done.hasPrefix("226") else { throw LanError("FTP: \(done)") }
        try? control.write(Data("QUIT\r\n".utf8))
    }
}

/// One TCP connection (blocking POSIX socket with timeouts), optionally wrapped in SecureTransport.
@available(iOS, deprecated: 13.0, message: "SecureTransport, see BambuFTPS")
final class FTPChannel {
    private var fd: Int32
    private var ctx: SSLContext?
    private var pending: [UInt8] = []

    init(host: String, port: UInt16, timeout: TimeInterval) throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else {
            throw LanError("printer not reachable on the Wi-Fi")
        }
        defer { freeaddrinfo(res) }
        fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { throw LanError("no socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // connect with a time limit, then blocking reads/writes with SO_RCVTIMEO / SO_SNDTIMEO
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { Darwin.close(fd); throw LanError("printer not reachable on the Wi-Fi (port \(port))") }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&p, 1, Int32(min(timeout, 10) * 1000)) == 1,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else {
                Darwin.close(fd)
                throw LanError("printer not reachable on the Wi-Fi (port \(port))")
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close() }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    /// TLS client handshake; the printer's certificate is accepted as it is (Bambu's own CA, named after the serial).
    func startTLS(peerID: String) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else { throw LanError("TLS not available") }
        let read: SSLReadFunc = { conn, data, length in
            let fd = Int32(Int(bitPattern: conn) - 1)
            let want = length.pointee
            var got = 0
            while got < want {
                let n = Darwin.read(fd, data.advanced(by: got), want - got)
                if n > 0 { got += n; continue }
                if n < 0 && errno == EINTR { continue }
                length.pointee = got
                return n == 0 ? errSSLClosedGraceful : errSSLClosedAbort
            }
            length.pointee = got
            return noErr
        }
        let write: SSLWriteFunc = { conn, data, length in
            let fd = Int32(Int(bitPattern: conn) - 1)
            let want = length.pointee
            var done = 0
            while done < want {
                let n = Darwin.write(fd, data.advanced(by: done), want - done)
                if n > 0 { done += n; continue }
                if n < 0 && errno == EINTR { continue }
                length.pointee = done
                return errSSLClosedAbort
            }
            length.pointee = done
            return noErr
        }
        SSLSetIOFuncs(ctx, read, write)
        SSLSetConnection(ctx, UnsafeRawPointer(bitPattern: Int(fd) + 1))
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        let id = Array(peerID.utf8)
        SSLSetPeerID(ctx, id, id.count)
        var status: OSStatus
        repeat { status = SSLHandshake(ctx) } while status == errSSLServerAuthCompleted || status == errSSLWouldBlock
        guard status == noErr else { throw LanError("TLS with the printer failed (\(status))") }
        self.ctx = ctx
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var done = 0
            while done < buf.count {
                var n = 0
                if let ctx {
                    let st = SSLWrite(ctx, base.advanced(by: done), buf.count - done, &n)
                    guard st == noErr || (st == errSSLWouldBlock && n > 0) else { throw LanError("the printer closed the connection") }
                } else {
                    n = Darwin.write(fd, base.advanced(by: done), buf.count - done)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw LanError("the printer closed the connection") }
                }
                done += n
            }
        }
    }

    /// Up to 4 kB; empty at the end of the stream.
    private func readSome() throws -> [UInt8] {
        let capacity = 4096
        var buf = [UInt8](repeating: 0, count: capacity)
        var n = 0
        if let ctx {
            let st = SSLRead(ctx, &buf, capacity, &n)
            if n == 0 {
                if st == errSSLClosedGraceful || st == errSSLClosedNoNotify { return [] }
                if st != noErr { throw LanError("no answer from the printer") }
            }
        } else {
            repeat { n = Darwin.read(fd, &buf, capacity) } while n < 0 && errno == EINTR
            guard n >= 0 else { throw LanError("no answer from the printer") }
        }
        return Array(buf[0 ..< n])
    }

    private func line() throws -> String {
        while true {
            if let i = pending.firstIndex(of: 0x0A) {
                let l = String(decoding: pending[..<i], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeFirst(i + 1)
                return l
            }
            let more = try readSome()
            guard !more.isEmpty else { throw LanError("the printer closed the connection") }
            pending += more
        }
    }

    /// One FTP reply; a multi-line reply ("230-…") up to its last line ("230 …").
    func reply() throws -> String {
        let first = try line()
        guard first.count > 3, Array(first)[3] == "-" else { return first }
        let end = String(first.prefix(3)) + " "
        while true {
            let l = try line()
            if l.hasPrefix(end) { return l }
        }
    }

    @discardableResult
    func command(_ text: String, expect: String) throws -> String {
        try write(Data("\(text)\r\n".utf8))
        let r = try reply()
        guard r.hasPrefix(expect) else { throw LanError("\(text.hasPrefix("PASS") ? "PASS ***" : text): \(r)") }
        return r
    }
}

private extension String {
    /// Groups of the first match ([whole, group 1, …]); empty without a match.
    func firstMatch(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return [] }
        return (0 ..< m.numberOfRanges).map { Range(m.range(at: $0), in: self).map { String(self[$0]) } ?? "" }
    }
}
