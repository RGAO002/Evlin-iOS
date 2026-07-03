import Foundation

enum StreamFailure: Error, Equatable {
    case fallbackToLegacy      // endpoint unreachable/missing — caller may auto-fallback once
    case manualRetry(String)   // server responded / mid-stream drop — surface + manual retry
    case signedOut             // refresh failed
}

/// SSE transport for POST /parent/chat/stream. Owns the spec's fallback
/// taxonomy and the single-flight 401-refresh-then-reopen contract.
final class ChatStreamClient {
    private let apiClient: APIClient
    init(apiClient: APIClient) { self.apiClient = apiClient }

    /// nil = not a terminal failure at this layer (200 OK, or 401 which the
    /// refresh path intercepts before classification).
    static func classify(statusCode: Int?, urlError: URLError?, gotHeaders: Bool)
        -> StreamFailure? {
        // A URLError after headers were received (e.g. the body stream broke
        // mid-read) is a post-headers drop regardless of the prior status —
        // check it before the statusCode switch so a 200 + dropped connection
        // classifies as manualRetry, not as the 200 "still fine" case below.
        if gotHeaders, let error = urlError {
            return .manualRetry(error.localizedDescription)
        }
        if let status = statusCode {
            switch status {
            // 200 OK and 401 (handled by the refresh-and-reopen path before this
            // classifier ever runs) are both non-terminal here.
            case 200, 401: return nil
            case 404, 405, 501: return .fallbackToLegacy
            default: return .manualRetry("Server error \(status)")
            }
        }
        if !gotHeaders { return .fallbackToLegacy }       // pre-connect URLError
        return .manualRetry(urlError?.localizedDescription ?? "Connection lost")
    }

    func stream(body: Data) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(body: body, attempt: 0,
                                       continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(body: Data, attempt: Int,
                     continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var req = apiClient.authedRequest(path: "/parent/chat/stream", method: "POST")
        req.httpBody = body
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 120
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch let e as URLError {
            throw Self.classify(statusCode: nil, urlError: e, gotHeaders: false)
                ?? StreamFailure.manualRetry(e.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        if http?.statusCode == 401 {
            // Single-flight refresh (reuse APIClient's shared refresher, §14.7),
            // then ONE reopen. Refresh failure → signed-out, never legacy.
            guard attempt == 0 else { throw StreamFailure.signedOut }
            do {
                _ = try await apiClient.refreshAccessTokenSingleFlight()
            } catch {
                throw StreamFailure.signedOut
            }
            return try await run(body: body, attempt: 1, continuation: continuation)
        }
        if let failure = Self.classify(statusCode: http?.statusCode,
                                       urlError: nil, gotHeaders: true) {
            throw failure
        }
        var parser = SSELineParser()
        do {
            for try await line in bytes.lines {
                if let raw = parser.feed(line: line),
                   let ev = ChatStreamEvent.parse(raw) {
                    continuation.yield(ev)
                    if case .envelope = ev { return }
                    if case .error = ev { return }
                }
            }
            // Body ended without a terminal event → post-headers drop.
            throw StreamFailure.manualRetry("Connection lost")
        } catch let e as URLError {
            throw Self.classify(statusCode: 200, urlError: e, gotHeaders: true)
                ?? StreamFailure.manualRetry(e.localizedDescription)
        }
    }
}
