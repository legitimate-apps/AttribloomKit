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

For deferred attribution, call `resolveTokenDeferred(surfaceId:)` instead. To replace an account binding, call `reset()` before resolving again.

## Links

- Agent integration guide: https://attribloom.com/agents/ios-affiliate-attribution
- GitHub topics: `swift`, `swift-package`, `storekit`, `storekit2`, `ios`, `affiliate-attribution`, `app-account-token`

## Scope

This package is client-side only. ASSN forwarding, HMAC signing, and server implementation are intentionally out of scope.
