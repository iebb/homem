# Standalone Mac App Store submission — 3 October 2026

- App: Homem (`ad.neko.homem`), Apple ID `6812852139`, team `7P8CLHDH5G`.
- Platform/version: macOS (`MAC_OS`) **1.0.0 (101)**.
- Build ID: `2bef8d4b-4e12-426f-bd46-11cc857ec17b`; processing state **VALID**.
- Review submission: `e9c86f1d-ebc6-46a2-995d-54867ef1adc9`; state **WAITING_FOR_REVIEW**.
- Release remains **manual** after approval.
- This replaces the previously queued Catalyst build 67. Its previous review submission was withdrawn before selecting the native build.

**Later review update, 3 October:** Apple's automated entitlement analysis rejected this submission for the incoming-network entitlement. The native WebRTC desktop viewer needs the entitlement for UDP reception. App Review Information now contains the explanation and demo steps; an unsent response draft is prepared. See [the entitlement investigation](MACOS-ENTITLEMENT-REVIEW-2026-10-03.md) for evidence and the current resubmission state. The initial waiting-for-review state above is historical.

## Native app and validation

`HomemMac` is a standalone SwiftUI/AppKit target. Both Intel and Apple silicon executables report `MACOS`, with minimum macOS 14. The archive is `build-release/HomemNativeMac-1.0.0-101.xcarchive`. Its app is sandboxed, uses native Mac icons and a Mac Info.plist, and excludes the iOS share extension. Xcode's direct App Store upload succeeded. Apple accepted the native build as valid. The prebuilt WebRTC SDK emitted a nonblocking missing dSYM warning; Homem's own dSYM is present.

51 signed native tests passed with no failures. Keychain tests cover updating, migration to synchronizable storage, and deletion. Window and account isolation, workspace restoration, chat queues, model catalogs, official login, code formatting, and RFB transport tests passed. Shared changes also build for iOS and arm64 visionOS simulators. Physical iCloud Keychain propagation and live production desktop/terminal interaction were not exercised by the local fixture.

## Store metadata and screenshots

Four **1440 × 900** native Mac screenshots replaced the prior Catalyst captures. Every uploaded asset reached **COMPLETE**. Upload JPEGs are in [screenshots/native-mac/en-US](screenshots/native-mac/en-US/); source captures and UI evidence are in [the native UI report](../ui/2026-10-03-native/README.md).

The English, Simplified Chinese, Japanese, and Spanish descriptions now describe the standalone Mac controls, separate windows, splits, and synchronized sign-ins. Review notes explain the native platform and server requirements; existing demo credentials were retained. There is no new purchase or subscription in this client.

## Xcode Cloud

All three workflows are enabled for `master`. The Mac workflow uses `HomemMac` for required tests and App Store eligible archives on `ANY_MAC`, with delivery to **Homem Internal**. The shared next build number was set to **102**, above this local upload. See [Cloud configuration](../XCODE_CLOUD.md).
