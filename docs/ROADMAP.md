# Roadmap

Each milestone should be usable and testable on its own. Dates are intentionally absent.

## M0: Foundation (this scaffold)
- [x] Repository, licenses, trademark policy, contribution rules
- [x] Architecture and threat model drafts
- [x] Go server skeleton (later replaced by CloudKit)
- [x] SwiftUI project skeleton (iOS 26+), CI workflow

## M1: Identity and key exchange
- [x] Device keys (Ed25519 + X25519, CryptoKit, Keychain this-device-only)
- [x] Storage and sharing on CloudKit: one zone per circle, zone-wide share with public link
- [x] Circles with encrypted names and member cards
- [x] Owner-signed circle record and roster; self-signed member records
- [x] Invite links and QR codes; admission proof from the invite secret
- [x] Member removal with atomic key rotation (HPKE auth mode) and iCloud share removal
- [x] Safety codes per member; unverified iCloud participants flagged to the owner
- [x] Known-answer vectors, unit tests, full flow and attack tests against a CloudKit simulation
- [x] App: setup, circle list, circle details, invite, join, settings
- [x] Simulation mode in debug builds: made-up members on the in-memory backend, no iCloud needed
- [ ] First run against real iCloud with two accounts (owner, Mac + iPhone)

History: M1 was first built with a self-hosted Go server (EU, anonymous device keys). It was replaced by CloudKit so nobody has to run hardware. See the README for the privacy trade-off.

## M2: Live location
- [x] Encrypted, device-signed location records
- [x] Map view with circle members (MapKit), Life360-style people drawer, circle switcher
- [x] Moving simulated members in the debug simulation
- [ ] CloudKit subscriptions (silent push) for updates instead of 30-second polling
- [x] Background location: live updates with a background activity session, stationary pause, fewer uploads while the app is closed
- [ ] Smarter tracking: visits, geofence wake-ups, presence-based frequency
- [ ] Push entitlement and subscription handling

## M3: Places
- [ ] Create and share places (encrypted)
- [ ] On-device geofence evaluation
- [ ] Arrival and departure notifications via encrypted push + Notification Service Extension

## M4: History and safety
- [ ] Opt-in history with user-chosen retention, deleted by the writing device
- [ ] Opt-in SOS and check-in

## M5: Drive detection
- [ ] CoreMotion automotive detection
- [ ] Live speed (km/h) while driving
- [ ] Battery profiling and tuning

## M6: Friends, groups and polish
- [ ] Friend requests, multiple circles and groups
- [ ] Liquid Glass UI polish, accessibility, localization (DE, EN)
- [ ] Multi-device support and key backup
- [ ] Owner succession if the owner's device is lost
- [ ] Warning when an unverified key appears in a circle

## M7: Monetization and release
- [ ] StoreKit 2: non-intrusive convenience purchases (safety features stay free)
- [ ] Privacy policy (incl. iCloud metadata disclosure), App Privacy labels, background-location review justification
- [ ] Deploy CloudKit schema to production
- [ ] TestFlight with friends, then public App Store release
- [ ] Independent security review

## Setup tasks only the owner can do (Mac required)
- Bundle ID (e.g. `de.timschaller.leuchtturm`), signing and provisioning
- App Store Connect record, TestFlight
- iCloud container `iCloud.de.timschaller.leuchtturm` (created via Xcode)
- Check that the name "Leuchtturm" is usable in the App Store
