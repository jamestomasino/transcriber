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
