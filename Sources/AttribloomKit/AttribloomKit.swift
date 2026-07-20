/// iOS-side affiliate attribution support for StoreKit 2 purchases.
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Security)
import Security
#endif

/// The result of binding a referral to an App Store account token.
public struct BindResult: Sendable, Equatable {
    /// The StoreKit 2 account token issued by Attribloom.
    public let appAccountToken: UUID
    /// An optional offer code returned with the binding.
    public let offerCode: String?

    /// Creates a binding result.
    public init(appAccountToken: UUID, offerCode: String?) {
        self.appAccountToken = appAccountToken
        self.offerCode = offerCode
    }
}

/// Errors returned while resolving an Attribloom account token.
public enum AttribloomError: Error, Sendable, Equatable {
    /// Neither supported referral value was supplied.
    case missingReferral
    /// The server rejected the request.
    case invalidRequest(message: String)
    /// A deferred bind did not find a matching click.
    case notFound
    /// The service rate limited the request.
    case rateLimited(message: String?)
    /// The service is temporarily unavailable.
    case serverUnavailable(message: String?)
    /// The service returned an unrecognised HTTP status.
    case unexpectedStatus(code: Int)
    /// A response body could not be decoded.
    case decodingFailed
    /// URLSession failed before a valid response was received.
    case transport(message: String)
}

private struct BindResponse: Decodable, Sendable {
    let appAccountToken: String
    let offerCode: String?
}

private struct ErrorResponse: Decodable, Sendable {
    let error: String?
    let message: String?
}

/// A client for the Attribloom App Store binding API.
public actor AttribloomClient {
    private let baseURL: URL
    private let session: URLSession

    /// Creates an API client.
    public init(baseURL: URL = URL(string: "https://api.attribloom.com")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Binds a signed click ID or referral code to an App Store account token.
    public func bind(signedClickId: String? = nil, refCode: String? = nil) async throws -> BindResult {
        let signedClickId = signedClickId?.nilIfEmpty
        let refCode = refCode?.nilIfEmpty
        guard signedClickId != nil || refCode != nil else {
            throw AttribloomError.missingReferral
        }

        var body: [String: String] = [:]
        if let signedClickId { body["signedClickId"] = signedClickId }
        if let refCode { body["refCode"] = refCode }
        return try await request(path: "/v1/app-store/bind", body: body, isDeferred: false)
    }

    /// Resolves a deferred referral for a surface ID.
    public func deferredBind(surfaceId: String) async throws -> BindResult {
        try await request(path: "/v1/app-store/bind/deferred", body: ["surfaceId": surfaceId], isDeferred: true)
    }

    private func request(path: String, body: [String: String], isDeferred: Bool) async throws -> BindResult {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw AttribloomError.transport(message: "Invalid base URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw AttribloomError.decodingFailed
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AttribloomError.transport(message: error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AttribloomError.transport(message: "Response was not HTTP")
        }

        guard httpResponse.statusCode == 200 else {
            throw mapError(statusCode: httpResponse.statusCode, data: data, isDeferred: isDeferred)
        }
        let payload: BindResponse
        do {
            payload = try JSONDecoder().decode(BindResponse.self, from: data)
        } catch {
            throw AttribloomError.decodingFailed
        }
        guard let token = UUID(uuidString: payload.appAccountToken) else {
            throw AttribloomError.decodingFailed
        }
        return BindResult(appAccountToken: token, offerCode: payload.offerCode)
    }

    private func mapError(statusCode: Int, data: Data, isDeferred: Bool) -> AttribloomError {
        let payload = try? JSONDecoder().decode(ErrorResponse.self, from: data)
        switch statusCode {
        case 400:
            guard let message = payload?.error ?? payload?.message else { return .decodingFailed }
            return .invalidRequest(message: message)
        case 404 where isDeferred:
            return .notFound
        case 429:
            return .rateLimited(message: payload?.message ?? payload?.error)
        case 503:
            return .serverUnavailable(message: payload?.error ?? payload?.message)
        default:
            return .unexpectedStatus(code: statusCode)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Storage for the App Store account token associated with this app installation.
public protocol AppAccountTokenStore: Sendable {
    /// Loads the currently persisted token, if any.
    func load() throws -> UUID?
    /// Persists an account token.
    func save(_ token: UUID) throws
    /// Clears any persisted account token.
    func clear() throws
}

/// A Keychain-backed account token store.
public struct KeychainTokenStore: AppAccountTokenStore {
    private static let service = "com.attribloom.AttribloomKit"
    private static let account = "appAccountToken"

    /// Creates a Keychain token store.
    public init() {}

    /// Loads the token from the Keychain.
    public func load() throws -> UUID? {
        #if canImport(Security)
        var query = attributes
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let string = String(data: data, encoding: .utf8), let token = UUID(uuidString: string) else {
            throw KeychainError.status(status)
        }
        return token
        #else
        return KeychainFallback.load()
        #endif
    }

    /// Saves the token in the Keychain.
    public func save(_ token: UUID) throws {
        #if canImport(Security)
        let data = Data(token.uuidString.utf8)
        let status = SecItemUpdate(attributes as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = attributes
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
        #else
        KeychainFallback.save(token)
        #endif
    }

    /// Clears the token from the Keychain.
    public func clear() throws {
        #if canImport(Security)
        let status = SecItemDelete(attributes as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
        #else
        KeychainFallback.clear()
        #endif
    }

    #if canImport(Security)
    private var attributes: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    private enum KeychainError: Error { case status(OSStatus) }
    #endif
}

#if !canImport(Security)
private enum KeychainFallback {
    private static let lock = NSLock()
    private static var token: UUID?
    static func load() -> UUID? { lock.withLock { token } }
    static func save(_ value: UUID) { lock.withLock { token = value } }
    static func clear() { lock.withLock { token = nil } }
}
#endif

/// A thread-safe in-memory token store for tests and previews.
public final class InMemoryTokenStore: AppAccountTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?

    /// Creates an empty in-memory store.
    public init() {}

    /// Loads the current in-memory token.
    public func load() throws -> UUID? { lock.withLock { token } }

    /// Saves an in-memory token.
    public func save(_ token: UUID) throws { lock.withLock { self.token = token } }

    /// Clears the current in-memory token.
    public func clear() throws { lock.withLock { token = nil } }
}

/// High-level facade that resolves and persists an App Store account token.
public actor Attribloom {
    private let client: AttribloomClient
    private let store: any AppAccountTokenStore

    /// Creates an attribution facade with a client and persistent token store.
    public init(client: AttribloomClient = AttribloomClient(), store: any AppAccountTokenStore = KeychainTokenStore()) {
        self.client = client
        self.store = store
    }

    /// Returns the persisted account token, if present.
    public func appAccountToken() throws -> UUID? { try store.load() }

    /// Resolves and persists a token from an explicit referral.
    public func resolveToken(signedClickId: String? = nil, refCode: String? = nil) async throws -> UUID {
        if let token = try store.load() { return token }
        let result = try await client.bind(signedClickId: signedClickId, refCode: refCode)
        try store.save(result.appAccountToken)
        return result.appAccountToken
    }

    /// Resolves and persists a token from deferred attribution.
    public func resolveTokenDeferred(surfaceId: String) async throws -> UUID {
        if let token = try store.load() { return token }
        let result = try await client.deferredBind(surfaceId: surfaceId)
        try store.save(result.appAccountToken)
        return result.appAccountToken
    }

    /// Clears the persisted account token.
    public func reset() throws { try store.clear() }
}

#if canImport(StoreKit)
import StoreKit

public extension Product.PurchaseOption {
    /// Pass this option on every purchase for the attributed account.
    static func attribloom(_ token: UUID) -> Product.PurchaseOption { .appAccountToken(token) }
}
#endif
