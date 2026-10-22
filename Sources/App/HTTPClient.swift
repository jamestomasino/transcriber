import Foundation
import Security

// MARK: - URLSession HTTP client (App)
//
// The real `HTTPClient`. Uses URLSession.shared. The Core `HTTPClient` seam is
// what the LLM / cloud transcriber depend on, so tests inject a fake instead of
// hitting the network.

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(requestTimeout: TimeInterval = HTTPRetryPolicy.defaultRequestTimeout) {
        // URLSession.shared caps a request at 60s, which is far too short for a
        // long meeting: uploading a long recording (Deepgram) or sending a long
        // transcript to the LLM can legitimately take minutes. Use a dedicated
        // session with a generous timeout so long meetings don't fail mid-flight.
        // `timeoutIntervalForResource` is set even higher to bound the *whole*
        // transfer (including retries) without cutting it off prematurely.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = requestTimeout * 4
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.badStatus(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.badStatus(http.statusCode)
        }
        return HTTPResponse(statusCode: http.statusCode, body: data)
    }
}

// MARK: - Keychain (App)
//
// Stores API keys (Deepgram, OpenAI, Anthropic) in the macOS Keychain — never
// in settings.json, never in the bundle. The Core layer never touches the
// Keychain; it only ever *reads* a key via an injected closure, so the
// decision logic stays pure.

public enum Keychain {
    private static let service = "com.transcriber.app"

    public static func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Update if it exists, else add.
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.addFailed }
        }
    }

    public static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum KeychainError: Error { case addFailed }
