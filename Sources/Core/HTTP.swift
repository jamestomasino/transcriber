import Foundation

// MARK: - HTTP seam (Core, pure)
//
// A minimal injectable HTTP client so the App-layer LLM and cloud transcriber
// can be unit-tested with a fake (no real network in the test suite). Core
// defines the seam; the App supplies the URLSession implementation.

public struct HTTPRequest: Equatable, Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Errors from the HTTP layer.
public enum HTTPError: Error, Equatable, Sendable {
    case badStatus(Int)
    case noBody
    case decoding(String)

    public var description: String {
        switch self {
        case .badStatus(let s): return "The server returned status \(s)."
        case .noBody: return "The server returned an empty response."
        case .decoding(let d): return "Could not read the server response: \(d)"
        }
    }
}

// MARK: - Retry + timeout policy (Core, pure)
//
// Long meetings are the hard case: a long recording is a large upload (Deepgram)
// and a long transcript is a large prompt (OpenAI / Anthropic). Both go through
// this seam, and both can exceed URLSession's default 60s request timeout or
// hit a transient server hiccup (rate limit, 5xx, a dropped connection). The
// pure decision below decides *which* failures are worth retrying and the
// generous defaults the App's real client adopts. The *retry loop itself* is
// the `RetryingHTTPClient` decorator (below), which only performs the side
// effect of calling the inner client again — so the decision stays pure and
// unit-testable with a fake, no network.

public enum HTTPRetryPolicy {
    /// Total attempts (1 initial + retries). 3 is enough to ride out a rate
    /// limit or a brief 5xx without hammering the provider.
    public static let defaultMaxAttempts = 3

    /// Backoff between attempts, in seconds. The App uses a real delay; tests
    /// inject 0 so the suite stays instant and deterministic.
    public static let defaultBackoffDelay: TimeInterval = 0.5

    /// A single request may run this long before it is considered failed.
    /// Generous on purpose: a long meeting's upload / a big transcript's
    /// generation can legitimately take minutes.
    public static let defaultRequestTimeout: TimeInterval = 300

    /// Status codes that are safe to retry — transient server/load conditions,
    /// not client errors. 429 (rate limited) and the 5xx family (server busy,
    /// bad gateway, unavailable, gateway timeout).
    public static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    /// URLError codes that are transient network hiccups, safe to retry:
    /// timed out, connection lost, no network, roaming off, data not allowed,
    /// resource unavailable, cannot connect / cannot find host, DNS failure.
    /// (Raw values verified against Foundation on macOS.)
    public static let transientURLErrorCodes: Set<Int> = [
        -1001, // NSURLErrorTimedOut
        -1003, // NSURLErrorCannotFindHost
        -1004, // NSURLErrorCannotConnectToHost
        -1005, // NSURLErrorNetworkConnectionLost
        -1006, // NSURLErrorDNSLookupFailed
        -1008, // NSURLErrorResourceUnavailable
        -1009, // NSURLErrorNotConnectedToInternet
        -1018, // NSURLErrorInternationalRoamingOff
        -1020, // NSURLErrorDataNotAllowed
    ]

    /// The pure decision: is this thrown error worth another attempt?
    /// `HTTPError.badStatus` is retriable only for the transient status codes
    /// above; `URLError` is retriable only for the transient network codes
    /// above. Anything else (a 4xx client error, a decode failure, a missing
    /// key, …) is not retriable — retrying it just wastes a round trip.
    public static func isRetryable(_ error: Error) -> Bool {
        if let http = error as? HTTPError, case .badStatus(let code) = http {
            return retryableStatusCodes.contains(code)
        }
        if let url = error as? URLError {
            return transientURLErrorCodes.contains(url.code.rawValue)
        }
        return false
    }
}

/// An `HTTPClient` that retries a request on transient failures, using the
/// pure `HTTPRetryPolicy` decision. This is the *performer* of the policy: it
/// calls the inner client again (with an optional backoff) only when the
/// decision says the error is worth retrying and the attempt cap has not been
/// reached. Generic over any `HTTPClient`, so it wraps the real URLSession
/// client in the app and a fake in tests.
///
/// `backoffDelay` is injectable so the test suite can pass 0 and stay instant.
public final class RetryingHTTPClient: HTTPClient, @unchecked Sendable {
    private let inner: any HTTPClient
    private let maxAttempts: Int
    private let backoffDelay: TimeInterval

    public init(
        inner: any HTTPClient,
        maxAttempts: Int = HTTPRetryPolicy.defaultMaxAttempts,
        backoffDelay: TimeInterval = HTTPRetryPolicy.defaultBackoffDelay
    ) {
        self.inner = inner
        self.maxAttempts = maxAttempts
        self.backoffDelay = backoffDelay
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await inner.send(request)
            } catch {
                // Stop (rethrow) on a non-retriable error or once the cap is hit.
                guard attempt < maxAttempts, HTTPRetryPolicy.isRetryable(error) else {
                    throw error
                }
                if backoffDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(backoffDelay * 1_000_000_000))
                }
            }
        }
    }
}
