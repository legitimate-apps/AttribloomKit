# AttribloomKit

![License](https://img.shields.io/badge/license-MIT-green)

AttribloomKit binds a referral to an Attribloom-issued StoreKit 2 `appAccountToken`, stores it locally, and supplies it to purchases. It has no third-party dependencies, fingerprinting, IDFA use, or secrets.

## Get started

Add `AttribloomKit` to your Swift package or Xcode project. Create one facade for the signed-in app account. Resolve an explicit referral in a separate action after the permissions required for your integration are satisfied:

```swift
import AttribloomKit
import StoreKit

let attribution = Attribloom(store: KeychainTokenStore(accountID: opaqueLocalAccountID))

// Called by your referral action after your app's applicable consent checks.
func acceptReferral(_ code: String) async {
    do {
        _ = try await attribution.resolveToken(refCode: code)
    } catch {
        // Show a referral retry option; purchasing remains available.
    }
}

// Purchase does not make or wait for an attribution network request.
func purchase(_ product: Product, attributionPermitted: Bool) async throws -> Product.PurchaseResult {
    let token = attributionPermitted ? (try? await attribution.appAccountToken()) : nil
    let options: Set<Product.PurchaseOption> = token.map { [.attribloom($0)] } ?? []
    return try await product.purchase(options: options)
}
```

`opaqueLocalAccountID` is your app's stable local account key. Recreate the facade when accounts change. For recovery after installation, offer user-initiated paste or referral-code entry. If consent required for tracking is denied or withdrawn, do not resolve referrals or attach a stored attribution token; purchase with no attribution options. Entitlement restoration must work independently of referral lookup.

## RevenueCat apps

RevenueCat's SDK sets StoreKit's `appAccountToken` from its own App User ID when that ID is a UUID, so the Attribloom token cannot ride on a RevenueCat purchase. Send it as a customer attribute before the first purchase, then connect RevenueCat under Integrations in Attribloom:

```swift
if let token = try? attribution.appAccountToken() {
    Purchases.shared.attribution.setAttributes(["attribloom_ref": token.uuidString])
}
```

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
