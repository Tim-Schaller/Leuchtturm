# Roadmap

Each milestone should be usable and testable on its own. Dates are intentionally absent.

## M0: Foundation (this scaffold)
- [x] Repository, licenses, trademark policy, contribution rules
- [x] Architecture and threat model drafts
- [x] Go server skeleton with health endpoint and Dockerfile
- [x] SwiftUI project skeleton (iOS 26+), CI workflow

## M1: Identity and key exchange
- [ ] Device key generation (CryptoKit, Keychain/Secure Enclave)
- [ ] Server: accounts, devices, public key registry (SQLite)
- [ ] Sign in with Apple and anonymous device identity
- [ ] Circle creation, invite code / QR, wrapped circle keys
- [ ] Test vectors and crypto unit tests

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
- [ ] Email and Google sign-in (optional anchors)

## M7: Monetization and release
- [ ] StoreKit 2: non-intrusive convenience purchases (safety features stay free)
- [ ] Privacy policy, App Privacy labels, background-location review justification
- [ ] TestFlight with friends, then public App Store release
- [ ] Independent security review

## Setup tasks only the owner can do (Mac required)
- Bundle ID (e.g. `de.timschaller.tandem`), signing and provisioning
- App Store Connect record, TestFlight
- Hetzner account and server, DNS
- Check that the name "Tandem" is usable in the App Store
