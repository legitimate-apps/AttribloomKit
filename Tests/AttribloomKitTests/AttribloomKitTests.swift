import Foundation
import XCTest
@testable import AttribloomKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
        var recordedRequests: [URLRequest] = []
    }
    private static let state = State()

    static func configure(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        state.lock.withLock {
            state.handler = handler
            state.recordedRequests = []
        }
    }

    static var requests: [URLRequest] { state.lock.withLock { state.recordedRequests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.state.lock.withLock { () -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? in
            Self.state.recordedRequests.append(request)
            return Self.state.handler
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class AttribloomKitTests: XCTestCase {
    private let token = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    override func tearDown() {
        StubURLProtocol.configure { _ in throw URLError(.cancelled) }
        super.tearDown()
    }

    func testBindWithRefCodeReturnsTokenAndOfferCode() async throws {
        stub(status: 200, json: "{\"appAccountToken\":\"\(token.uuidString)\",\"offerCode\":\"SUMMER\"}")
        let result = try await client().bind(refCode: "creator")
        XCTAssertEqual(result, BindResult(appAccountToken: token, offerCode: "SUMMER"))
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/app-store/bind")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try jsonBody(request)["refCode"] as? String, "creator")
        XCTAssertNil(try jsonBody(request)["signedClickId"])
    }

    func testBindWithSignedClickIDReturnsTokenWithoutOfferCode() async throws {
        stub(status: 200, json: "{\"appAccountToken\":\"\(token.uuidString)\"}")
        let result = try await client().bind(signedClickId: "signed-click")
        XCTAssertEqual(result, BindResult(appAccountToken: token, offerCode: nil))
        let body = try jsonBody(XCTUnwrap(StubURLProtocol.requests.first))
        XCTAssertEqual(body["signedClickId"] as? String, "signed-click")
        XCTAssertNil(body["refCode"])
    }

    func testBindWithoutReferralFailsBeforeRequest() async {
        do {
            _ = try await client().bind()
            XCTFail("Expected missing referral")
        } catch let error as AttribloomError {
            XCTAssertEqual(error, .missingReferral)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testDeferredBindReturnsTokenAndRequestShape() async throws {
        stub(status: 200, json: "{\"appAccountToken\":\"\(token.uuidString)\"}")
        let result = try await client().deferredBind(surfaceId: "surface-1")
        XCTAssertEqual(result.appAccountToken, token)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/app-store/bind/deferred")
        XCTAssertEqual(try jsonBody(request)["surfaceId"] as? String, "surface-1")
    }

    func testHTTPErrorMapping() async {
        await assertError(status: 400, json: "{\"error\":\"Bad referral\"}", expected: .invalidRequest(message: "Bad referral"), deferred: false)
        await assertError(status: 404, json: "{\"error\":\"No click\"}", expected: .notFound, deferred: true)
        await assertError(status: 429, json: "{\"statusCode\":429,\"error\":\"Too Many Requests\",\"message\":\"Later\"}", expected: .rateLimited(message: "Later"), deferred: false)
        await assertError(status: 503, json: "{\"error\":\"Unavailable\"}", expected: .serverUnavailable(message: "Unavailable"), deferred: false)
        await assertError(status: 418, json: "{}", expected: .unexpectedStatus(code: 418), deferred: false)
    }

    func testMalformedAndInvalidUUIDResponsesFailDecoding() async {
        stub(status: 200, json: "not json")
        await assertDecodingFailure()
        stub(status: 200, json: "{\"appAccountToken\":\"not-a-uuid\"}")
        await assertDecodingFailure()
    }

    func testInMemoryTokenStoreRoundTrip() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load())
        try store.save(token)
        XCTAssertEqual(try store.load(), token)
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testResolveTokenPersistsAndAvoidsSecondNetworkRequest() async throws {
        stub(status: 200, json: "{\"appAccountToken\":\"\(token.uuidString)\"}")
        let attribloom = Attribloom(client: client(), store: InMemoryTokenStore())
        let first = try await attribloom.resolveToken(refCode: "creator")
        let second = try await attribloom.resolveToken(refCode: "other")
        XCTAssertEqual(first, token)
        XCTAssertEqual(second, token)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // Mirrors the README "RevenueCat apps" snippet: the customer attribute carries the persisted token.
    func testRevenueCatAttributeValueIsThePersistedToken() async throws {
        stub(status: 200, json: "{\"appAccountToken\":\"\(token.uuidString)\"}")
        let attribution = Attribloom(client: client(), store: InMemoryTokenStore())
        _ = try await attribution.resolveToken(refCode: "creator")
        var attributes: [String: String] = [:]
        if let stored = try? await attribution.appAccountToken() {
            attributes["attribloom_ref"] = stored.uuidString
        }
        XCTAssertEqual(attributes, ["attribloom_ref": token.uuidString])
    }

    func testOffersPersistWithReferralContext() async throws {
        stub(status: 200, json: "{\"appAccountToken\":\"\(token.uuidString)\",\"offerCode\":\"WELCOME\"}")
        let store = InMemoryTokenStore()
        let facade = Attribloom(client: client(), store: store)
        _ = try await facade.resolveToken(refCode: "creator")
        XCTAssertEqual(try store.loadBinding()?.offerCode, "WELCOME")
        try await facade.reset()
        XCTAssertNil(try store.loadBinding())
    }

    func testKeychainAccountIsolationAndOffers() throws {
        let a = KeychainTokenStore(accountID: "test-a-\(UUID())")
        let b = KeychainTokenStore(accountID: "test-b-\(UUID())")
        defer { try? a.clear(); try? b.clear() }
        let result = BindResult(appAccountToken: token, offerCode: "OFFER")
        try a.saveBinding(result)
        XCTAssertEqual(try a.loadBinding(), result)
        XCTAssertNil(try b.load())
        try b.save(UUID())
        try b.clear()
        XCTAssertEqual(try a.loadBinding(), result)
    }

    private func client() -> AttribloomClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AttribloomClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: configuration))
    }

    private func stub(status: Int, json: String) {
        StubURLProtocol.configure { request in
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://example.test")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, Data(json.utf8))
        }
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1_024)
            var result = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                if count == 0 { break }
                result.append(bytes, count: count)
            }
            data = result
        } else {
            throw URLError(.badURL)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertError(status: Int, json: String, expected: AttribloomError, deferred: Bool) async {
        stub(status: status, json: json)
        do {
            if deferred { _ = try await client().deferredBind(surfaceId: "surface") }
            else { _ = try await client().bind(refCode: "ref") }
            XCTFail("Expected \(expected)")
        } catch let error as AttribloomError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertDecodingFailure() async {
        do {
            _ = try await client().bind(refCode: "ref")
            XCTFail("Expected decoding failure")
        } catch let error as AttribloomError {
            XCTAssertEqual(error, .decodingFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
