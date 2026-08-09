import Foundation

/// An in-process fake HTTP server for `ModelDownloaderTests` (specs/P2a Phase 5 guardrail:
/// "test `ModelDownloader` against a small LOCAL source, not the network"). A `URLProtocol`
/// stub was chosen over spinning up a real `http.server` process: it needs no port binding
/// or process lifecycle management (both awkward/flaky in a sandboxed CI-style test run),
/// runs fully in-process, and gives per-test, per-request deterministic control — including
/// simulating a dropped connection mid-transfer, which a real local server would need
/// deliberate fault injection to reproduce reliably.
///
/// Each test installs a `handler` closure that inspects the (possibly ranged) `URLRequest`
/// and returns a canned `Response`; `startLoading()` replays that response through the
/// standard `URLProtocolClient` callbacks, including an optional simulated failure partway
/// through delivery (the "interrupted mid-stream" scenario).
final class StubURLProtocol: URLProtocol {

    struct Response {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        /// Delivered via one `didLoad:` call per chunk, each hopped onto a background queue
        /// with a short delay between them — so `URLSession.bytes(for:)`'s consumer actually
        /// gets to dequeue+process earlier chunks before later ones (or `failure`) arrive,
        /// rather than the whole transfer resolving as one instantaneous burst. This is what
        /// makes the "interrupted mid-stream" scenario genuinely mid-stream.
        var chunks: [Data]
        /// When set, delivered *after* every chunk instead of a clean finish — simulates a
        /// connection dropping mid-transfer.
        var failure: Error?

        init(statusCode: Int = 200, headers: [String: String] = [:], body: Data = Data(), failure: Error? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.chunks = body.isEmpty ? [] : [body]
            self.failure = failure
        }

        init(statusCode: Int, headers: [String: String] = [:], chunks: [Data], failure: Error? = nil) {
            self.statusCode = statusCode
            self.headers = headers
            self.chunks = chunks
            self.failure = failure
        }
    }

    /// Keyed by request so concurrent/sequential stubbed calls within one test don't race
    /// on a single mutable slot; a lock guards access since `startLoading()` can run off
    /// the calling thread (the standard URL Loading System behaviour).
    private static let lock = NSLock()
    private static var _handler: ((URLRequest) -> Response)?

    static var handler: ((URLRequest) -> Response)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _handler = newValue
        }
    }

    static func reset() {
        handler = nil
    }

    // `static` is invalid here: these override `URLProtocol`'s `class func` API, so `class`
    // is required, not a stylistic choice — a genuine false positive on `static_over_final_class`.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = handler(request)
        guard
            let httpResponse = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        deliver(chunks: response.chunks, failure: response.failure, index: 0)
    }

    override func stopLoading() {}

    /// Deliver one chunk, then hop to a background queue with a short delay before the
    /// next — giving the `URLSession.AsyncBytes` consumer real opportunities to dequeue
    /// and process each chunk incrementally instead of the whole response resolving (or
    /// failing) as a single instantaneous burst.
    private func deliver(chunks: [Data], failure: Error?, index: Int) {
        guard index < chunks.count else {
            if let failure {
                client?.urlProtocol(self, didFailWithError: failure)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        client?.urlProtocol(self, didLoad: chunks[index])
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
            self?.deliver(chunks: chunks, failure: failure, index: index + 1)
        }
    }
}
