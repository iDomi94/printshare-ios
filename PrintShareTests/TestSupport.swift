import Foundation
import XCTest
@testable import PrintShare

private final class TestBundleToken {}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: TestBundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name)"])
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: data(name))
    }
}

struct StubResponse {
    var status = 200
    var body = Data("{}".utf8)
    var delay: TimeInterval = 0
    var error: URLError?
    var headers: [String: String] = [:]
}

struct LoggedRequest: Equatable {
    var method: String
    var host: String
    var path: String
}

/// URLProtocol that answers from a closure, so the API client is tested without a network.
final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var respond: ((URLRequest) -> StubResponse)?
    static var log: [LoggedRequest] = []

    static func install(_ respond: @escaping (URLRequest) -> StubResponse) {
        lock.lock(); defer { lock.unlock() }
        Self.respond = respond
        log = []
    }

    static var requests: [LoggedRequest] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        StubProtocol.lock.lock()
        let respond = StubProtocol.respond
        StubProtocol.log.append(LoggedRequest(method: request.httpMethod ?? "GET", host: request.url?.host ?? "",
                                              path: request.url?.path ?? ""))
        StubProtocol.lock.unlock()
        let stub = respond?(request) ?? StubResponse(status: 500)
        DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay) { [weak self] in
            guard let self else { return }
            if let error = stub.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let res = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": "application/json"].merging(stub.headers) { $1 })!
            self.client?.urlProtocol(self, didReceive: res, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: stub.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
