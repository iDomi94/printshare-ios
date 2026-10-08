@preconcurrency import CoreNFC
import Foundation

/// A chip held to the phone (server 0.38.0): its number (hex, upper case, in the byte order Android reports = as
/// received over the air) and - for an OpenPrintTag - what is written in it. Port of the Expo app's `lib/nfc.ts`.
struct NFCChip: Sendable, Equatable {
    var uid: String
    var tag: OpenPrintTag?
}

enum NFCError: Error, LocalizedError, Equatable {
    case unavailable, timeout, cancelled, readFailed

    var errorDescription: String? { nil }

    /// The text shown for it ("" = the user cancelled: nothing to show).
    func text(_ t: L10n) -> String {
        switch self {
        case .unavailable: return t(.nfcNone)
        case .timeout: return t(.nfcTimeout)
        case .cancelled: return ""
        case .readFailed: return t(.nfcReadFailed)
        }
    }
}

enum NFC {
    /// Can this phone read NFC tags at all? (hide the NFC buttons otherwise)
    static var available: Bool { NFCTagReaderSession.readingAvailable }

    /// Waits for any chip (system NFC sheet): OpenPrintTag / ISO 15693 (memory read and decoded), NTAG sticker or a
    /// Bambu spool's MIFARE tag (number only).
    @MainActor
    static func scanChip(_ t: L10n) async throws -> NFCChip {
        guard available else { throw NFCError.unavailable }
        let raw = try await NFCScanner().scan(prompt: t(.nfcHold))
        var tag: OpenPrintTag?
        if !raw.memory.isEmpty { tag = try? OpenPrintTag.parse(raw.memory, uid: raw.uid) }   // blank or another format
        return NFCChip(uid: raw.uid, tag: tag)
    }

    /// iOS reports an ISO 15693 UID most significant byte first (E0 …); Android (and the server's links) use the order
    /// received over the air. NFC-A numbers are the same on both.
    static func uid(_ identifier: Data, iso15693: Bool) -> String {
        let bytes = iso15693 && identifier.first == 0xE0 ? Array(identifier.reversed()) : Array(identifier)
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: matching a tag to a spool

    private static func rgb(_ hex: String?) -> [Double]? {
        let s = (hex ?? "").replacingOccurrences(of: "#", with: "")
        guard s.matches("^[0-9A-Fa-f]{6}") else { return nil }
        return [0, 2, 4].map { i in
            let a = s.index(s.startIndex, offsetBy: i)
            return Double(Int(s[a ..< s.index(a, offsetBy: 2)], radix: 16) ?? 0)
        }
    }

    private static func norm(_ s: String?) -> String {
        (s ?? "").lowercased().replacingRegex("[^a-z0-9+]", with: "")
    }

    /// The spool a scanned OpenPrintTag belongs to: same material, then brand, name and colour; among equal ones the
    /// one whose remaining weight is closest to the tag's. nil if no spool fits well enough.
    static func matchSpool(_ tag: OpenPrintTag, _ spools: [Spool]) -> Spool? {
        let type = norm(tag.materialType)
        var best: (s: Spool, score: Int, diff: Double)?
        for s in spools {
            let mat = norm(s.material)
            guard !type.isEmpty, !mat.isEmpty, mat.hasPrefix(type) || type.hasPrefix(mat) else { continue }
            var score = 0
            let brand = norm(tag.brand), vendor = norm(s.vendor)
            if !brand.isEmpty && !vendor.isEmpty && (vendor.contains(brand) || brand.contains(vendor)) { score += 3 }
            let tn = norm(tag.name), sn = norm(s.name)
            if !tn.isEmpty && !sn.isEmpty && (tn.contains(sn) || sn.contains(tn)) { score += 2 }
            if let a = rgb(tag.color), let b = rgb(s.color) {
                let d = ((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2])).squareRoot()
                score += d < 40 ? 2 : d < 90 ? 1 : -1
            }
            let diff = tag.remainingWeight.flatMap { w in s.remainingG.map { abs(w - $0) } } ?? 1e9
            if best == nil || score > best!.score || (score == best!.score && diff < best!.diff) { best = (s, score, diff) }
        }
        guard let best, best.score >= 2 else { return nil }
        return best.s
    }

    /// The spool of a chip: linked on the server by its number, else (OpenPrintTag) by what the tag says.
    static func identify(_ api: APIClient?, _ chip: NFCChip, _ spools: [Spool]) async -> Spool? {
        if let api, let linked = try? await api.spoolTag(uid: chip.uid).spool,   // older server: no links yet
           let sp = spools.first(where: { $0.id == linked }) {
            return sp
        }
        return chip.tag.flatMap { matchSpool($0, spools) }
    }
}

/// One NFC reader session: the first tag found is read and the session ends.
private final class NFCScanner: NSObject, NFCTagReaderSessionDelegate, @unchecked Sendable {
    struct Raw: Sendable { var uid: String; var memory: [UInt8] }

    private let queue = DispatchQueue(label: "nfc-scan")
    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<Raw, Error>?
    /// The session may hold its delegate weakly: keep this scanner alive until the scan is over.
    private var keepAlive: NFCScanner?

    func scan(prompt: String) async throws -> Raw {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Raw, Error>) in
            queue.async {
                self.continuation = c
                self.keepAlive = self
                guard let s = NFCTagReaderSession(pollingOption: [.iso14443, .iso15693], delegate: self, queue: self.queue) else {
                    self.finish(.failure(NFCError.unavailable))
                    return
                }
                s.alertMessage = prompt
                self.session = s
                s.begin()
            }
        }
    }

    /// Called on `queue` only; resumes once.
    private func finish(_ result: Result<Raw, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        defer { queue.async { self.keepAlive = nil } }
        c.resume(with: result)
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let code = (error as? NFCReaderError)?.code
        switch code {
        case .readerSessionInvalidationErrorUserCanceled: finish(.failure(NFCError.cancelled))
        case .readerSessionInvalidationErrorSessionTimeout: finish(.failure(NFCError.timeout))
        case .readerSessionInvalidationErrorFirstNDEFTagRead: break
        default: finish(.failure(NFCError.readFailed))
        }
        self.session = nil
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first else { return }
        switch first {
        case .iso15693(let tag):
            // CoreNFC calls back on `queue` only: the session and the tag never really cross threads
            let ref = Unchecked((session: session, tag: tag))
            session.connect(to: first) { error in
                if error != nil { return self.fail(ref.value.session) }
                self.readMemory(ref.value.tag) { memory in
                    self.done(ref.value.session, Raw(uid: NFC.uid(ref.value.tag.identifier, iso15693: true), memory: memory))
                }
            }
        case .miFare(let tag):
            // NTAG sticker / Bambu MIFARE tag: only the chip number is used
            done(session, Raw(uid: NFC.uid(tag.identifier, iso15693: false), memory: []))
        default:
            session.restartPolling()
        }
    }

    private func done(_ session: NFCTagReaderSession, _ raw: Raw) {
        finish(.success(raw))
        session.invalidate()
    }

    private func fail(_ session: NFCTagReaderSession) {
        finish(.failure(NFCError.readFailed))
        session.invalidate()
    }

    // ISO 15693 memory read so far (only touched on `queue`, where CoreNFC calls back)
    private var memory: [UInt8] = []

    /// All blocks of an ISO 15693 tag (ICODE SLIX2: 80 × 4 bytes), block by block until the tag answers with an error
    /// (past its end) or 256 blocks. A read error after some blocks keeps what was read (the NDEF data comes first).
    private func readMemory(_ tag: NFCISO15693Tag, _ then: @escaping @Sendable ([UInt8]) -> Void) {
        memory = []
        readBlock(Unchecked(tag), 0, then)
    }

    private func readBlock(_ tag: Unchecked<NFCISO15693Tag>, _ i: Int, _ then: @escaping @Sendable ([UInt8]) -> Void) {
        guard i < 256 else { return then(memory) }
        tag.value.readSingleBlock(requestFlags: [.highDataRate], blockNumber: UInt8(i)) { data, error in
            if error != nil { return then(self.memory) }
            self.memory += data
            self.readBlock(tag, i + 1, then)
        }
    }
}

/// A CoreNFC object handed between CoreNFC's own callbacks, which all run on the scanner's queue.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
