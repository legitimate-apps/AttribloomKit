# AttribloomKit

![Swift Package](https://img.shields.io/badge/Swift_Package-SPI--friendly_placeholder-blue)
![License](https://img.shields.io/badge/license-MIT-green)

AttribloomKit binds a referral to an Attribloom-issued StoreKit 2 `appAccountToken`, stores it locally, and supplies it to purchases. It has no third-party dependencies, fingerprinting, IDFA use, or secrets.

## Get started (for AI agents)

Add `AttribloomKit` to your Swift package or Xcode project. On the first launch after a referral, resolve the token once. Pass the token to every StoreKit 2 purchase for that account.

```swift
import AttribloomKit
import StoreKit

let attribloom = Attribloom()
let token = try await attribloom.resolveToken(refCode: "creator-code")
let result = try await product.purchase(options: [.attribloom(token)])
```

The three calls are `Attribloom()`, `resolveToken(...)`, and `purchase(options: [.attribloom(token)])`.

For recovery after installation, offer user-initiated paste or referral-code entry. Use an account-scoped store as shown below.

## Links

- Agent integration guide: https://attribloom.com/agents/ios-affiliate-attribution
- GitHub topics: `swift`, `swift-package`, `storekit`, `storekit2`, `ios`, `affiliate-attribution`, `app-account-token`

## Scope

This package is client-side only. ASSN forwarding, HMAC signing, and server implementation are intentionally out of scope.

## Account and referral context

Create a separate facade for each signed-in app account:

```swift
let attribution = Attribloom(store: KeychainTokenStore(accountID: opaqueLocalAccountID))
```

Use an opaque app account key, never an email address. Switch to a new facade when the app account changes; keep each facade scoped to the account that initiated its request. Restores load the same account's stored token and never copy another account's token. The legacy default store remains readable but is installation-scoped; do not migrate its token into an identified account without explicit ownership evidence.

The built-in stores preserve `BindResult`, including offer codes; `await attribution.binding()` returns that context. Existing custom token-only stores remain compatible through protocol defaults but must implement `loadBinding`/`saveBinding` to persist offers.

Deferred IP attribution is retired. Use an explicit referral link, code field, or a user-initiated paste action. Do not inspect the clipboard at launch. Catch attribution errors and let StoreKit purchases and entitlement restoration proceed independently. The SDK does not request ATT consent or claim an exemption: review your actual cross-company measurement data flow against [Apple's privacy requirements](https://developer.apple.com/app-store/user-privacy-and-data-use/), obtain applicable permission before binding, and disclose the integration accurately.
