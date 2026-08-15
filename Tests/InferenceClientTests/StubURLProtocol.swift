import Foundation

/// An in-process fake HTTP server for `InferenceClientTests`, mirroring
/// `ModelDownloaderTests.StubURLProtocol` (see that file's doc comment for why a
/// `URLProtocol` stub was chosen over a real local server process: no port binding, no
/// process lifecycle, fully in-process, deterministic per-test control — including
/// delivering an SSE response in several pieces so streaming is genuinely exercised
/// incrementally rather than resolving as one instantaneous burst).
///
/// Duplicated rather than shared across test targets — this repo has no cross-test-target
/// support module, and each test target's fixtures/doubles are self-contained (the same
/// posture `ModelDownloaderTests` itself established).
final class StubURLProtocol: URLProtocol {

    struct Response {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        /// Delivered via one `didLoad:` call per chunk, each hopped onto a background
        /// queue with a short delay before the next — so a consumer iterating
        /// `URLSession.bytes(for:)`/`.lines` genuinely observes incremental delivery
        /// instead of the whole response resolving as a single instantaneous burst.
        var chunks: [Data]
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

    // `static` is invalid here: these override `URLProtocol`'s `class func` API, so
    // `class` is required, not a stylistic choice — a genuine false positive on
    // `static_over_final_class`.
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
