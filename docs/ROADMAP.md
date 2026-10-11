# Roadmap

Each milestone should be usable and testable on its own. Dates are intentionally absent.

## M0: Foundation (this scaffold)
- [x] Repository, licenses, trademark policy, contribution rules
- [x] Architecture and threat model drafts
- [x] Go server skeleton with health endpoint and Dockerfile
- [x] SwiftUI project skeleton (iOS 26+), CI workflow

## M1: Identity and key exchange
- [x] Device keys (Ed25519 + X25519, CryptoKit, Keychain this-device-only)
- [x] Signed requests instead of accounts/passwords; public key registry (SQLite)
- [x] Circles with encrypted names and member cards
- [x] Invite links and QR codes; circle key released only on redeem
- [x] Member removal with atomic key rotation (HPKE auth mode)
- [x] Safety codes per member
- [x] Shared Go/Swift test vectors, unit tests, end-to-end tests in CI
- [x] App: setup, circle list, circle details, invite, join, settings
- [ ] First run on a real iPhone (owner, Mac required)

Sign in with Apple moved to M6: with one device per person it would only add an Apple ID to the server without any benefit. It becomes useful together with multi-device support.

## M2: Live location
- [ ] Encrypted location upload and WebSocket stream
- [ ] Map view with circle members (MapKit)
- [ ] Background location with adaptive tracking (significant changes, presence-based frequency)
- [ ] APNs registration

## M3: Places
- [ ] Create and share places (encrypted)
- [ ] On-device geofence evaluation
- [ ] Arrival and departure notifications via encrypted push + Notification Service Extension

## M4: History and safety
- [ ] Opt-in history with user-chosen retention and automatic server-side deletion
- [ ] Opt-in SOS and check-in

## M5: Drive detection
- [ ] CoreMotion automotive detection
- [ ] Live speed (km/h) while driving
- [ ] Battery profiling and tuning

## M6: Friends, groups and polish
- [ ] Friend requests, multiple circles and groups
- [ ] Liquid Glass UI polish, accessibility, localization (DE, EN)
- [ ] Multi-device support and key backup
- [ ] Sign in with Apple, email or Google as optional account anchors for multi-device
- [ ] Warning when an unverified member appears in a circle

## M7: Monetization and release
- [ ] StoreKit 2: non-intrusive convenience purchases (safety features stay free)
- [ ] Privacy policy, App Privacy labels, background-location review justification
- [ ] TestFlight with friends, then public App Store release
- [ ] Independent security review

## Setup tasks only the owner can do (Mac required)
- Bundle ID (e.g. `de.timschaller.leuchtturm`), signing and provisioning
- App Store Connect record, TestFlight
- Hetzner account and server, DNS
- Check that the name "Leuchtturm" is usable in the App Store
