# AttribloomKit — implementation spec (source of truth)

Open-source Swift package: the iOS-side client for Attribloom affiliate attribution. It binds a
referred account to an Attribloom-issued StoreKit 2 `appAccountToken`, persists it, and hands it to
StoreKit 2 purchases. No fingerprinting, no IDFA, no third-party dependencies, no secrets in the app.

The ASSN v2 forwarder is SERVER-side (HMAC-signed) and is deliberately OUT OF SCOPE for this client
package. Do not implement it here.

## Authoritative API contract (from https://api.attribloom.com/openapi.json)

Base URL (default): `https://api.attribloom.com`

### POST /v1/app-store/bind
Request body (`application/json`), supply at least one field; if both are present the server uses
`signedClickId` and ignores `refCode`:
```json
{ "signedClickId": "string (minLength 1)", "refCode": "string (minLength 1)" }
```
Response 200:
```json
{ "appAccountToken": "uuid string", "offerCode": "string (optional)" }
```
Errors: 400 `{ "error": "string" }`, 429 `{ "statusCode": 429, "error": "Too Many Requests", "message": "string" }`, 503 `{ "error": "string" }`.

### POST /v1/app-store/bind/deferred
Request body:
```json
{ "surfaceId": "string (minLength 1, required)" }
```
Response 200: same `BindResponse` as above. Errors: 400, 404 (no matching click), 429, 503.

## Public API surface to implement

Module `AttribloomKit`. Swift 6 language mode, everything `Sendable`, `async`/`await`, `URLSession`.

- `public struct BindResult: Sendable, Equatable { public let appAccountToken: UUID; public let offerCode: String? }`
- `public enum AttribloomError: Error, Sendable, Equatable`:
  - `.missingReferral` (caller supplied neither signedClickId nor refCode)
  - `.invalidRequest(message: String)` (400)
  - `.notFound` (404, deferred bind found no click)
  - `.rateLimited(message: String?)` (429)
  - `.serverUnavailable(message: String?)` (503)
  - `.unexpectedStatus(code: Int)`
  - `.decodingFailed`
  - `.transport(message: String)` (URLSession error; store a String, not the Error, to stay Equatable/Sendable)
- `public actor AttribloomClient` (or a `Sendable struct` with an injected session — pick the cleaner Swift-6-safe design):
  - `public init(baseURL: URL = URL(string: "https://api.attribloom.com")!, session: URLSession = .shared)`
  - `public func bind(signedClickId: String? = nil, refCode: String? = nil) async throws -> BindResult`
    - Throw `.missingReferral` if both are nil/empty before any network call.
  - `public func deferredBind(surfaceId: String) async throws -> BindResult`
  - Map HTTP status → `AttribloomError` exactly per the contract above; decode `appAccountToken` into a `UUID` (throw `.decodingFailed` if not a valid UUID).
- Token persistence:
  - `public protocol AppAccountTokenStore: Sendable { func load() throws -> UUID?; func save(_ token: UUID) throws; func clear() throws }`
  - `public struct KeychainTokenStore: AppAccountTokenStore` — a real Keychain-backed store (Security framework, `kSecClassGenericPassword`, a stable service/account key, `kSecAttrAccessibleAfterFirstUnlock`). Gate with `#if canImport(Security)`.
  - `public final class InMemoryTokenStore: AppAccountTokenStore` — for tests/previews (thread-safe).
- High-level facade:
  - `public actor Attribloom` — holds a client + a token store.
    - `public init(client: AttribloomClient = AttribloomClient(), store: any AppAccountTokenStore = KeychainTokenStore())`
    - `public func appAccountToken() throws -> UUID?` (reads the store)
    - `public func resolveToken(signedClickId: String? = nil, refCode: String? = nil) async throws -> UUID` — if a token is already stored, return it (idempotent, no network); otherwise bind, persist, return. This is the "first launch after a referral" entry point.
    - `public func resolveTokenDeferred(surfaceId: String) async throws -> UUID` — same, via deferred bind.
    - `public func reset() throws` — clear the stored token.
- StoreKit purchase helper (gate with `#if canImport(StoreKit)`; iOS/macOS/tvOS/watchOS 15+):
  - `import StoreKit`
  - `public extension Product.PurchaseOption { static func attribloom(_ token: UUID) -> Product.PurchaseOption { .appAccountToken(token) } }`
  - A tiny doc note in code: pass this option on EVERY purchase for the attributed account.

## Tests (must pass `swift test`)

Use a `URLProtocol` subclass to stub responses (no real network). Cover:
- bind with refCode → 200 → returns the exact UUID + offerCode
- bind with signedClickId → 200 → returns UUID (offerCode nil)
- bind with neither → throws `.missingReferral` (assert NO request was made)
- deferredBind(surfaceId:) → 200 → UUID
- 400 → `.invalidRequest`; 404 (deferred) → `.notFound`; 429 → `.rateLimited`; 503 → `.serverUnavailable`; other → `.unexpectedStatus`
- malformed/invalid-UUID body → `.decodingFailed`
- request shape: assert the POST body JSON contains the right keys (refCode-only body has no signedClickId, etc.) and Content-Type is application/json
- `InMemoryTokenStore`: save/load/clear round-trip
- `Attribloom.resolveToken`: first call binds + persists; second call returns the stored token WITHOUT a network request (stub asserts request count == 1)

## Non-goals / do not do
- No ASSN forwarding, no HMAC signing, no server code.
- No third-party dependencies.
- No secrets, API keys, or forwarding secrets anywhere in the package.
- Do not invent endpoints or fields beyond this spec.

## Quality bar
`swift build` and `swift test` both green on Swift 6.2 (the toolchain here). Public API documented with
`///` doc comments. README.md with a "Get started (for AI agents)" section, the 3-call quickstart,
SPI-friendly badges placeholder, GitHub topics list, and a link to https://attribloom.com/agents/ios-affiliate-attribution.
LICENSE = MIT (author "Attribloom"). No em dashes in README/user-facing docs (use "·" or two sentences).
