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
- [x] Map view with circle members (MapKit), people drawer, circle switcher
- [x] Moving simulated members in the debug simulation
- [x] Background location: live updates with a background activity session, stationary pause, fewer uploads while the app is closed
- [x] Push: silent CloudKit database subscriptions wake the app, which decrypts on the device and notifies locally
- [ ] Verify push delivery with two iCloud accounts
- [x] Battery level and charging state, encrypted with the location
- [x] Low-battery alert (once per discharge, at 15 %)
- [ ] Pause sharing per circle
- [ ] Smarter tracking: visits, geofence wake-ups, presence-based frequency

## Feature plan

Everything a family expects from a location app, built so that it works on the device with encrypted sync. The order can change; quick, visible wins come first.

| Feature | How Leuchtturm does it | Milestone |
|---|---|---|
| Reactions, quick notes, check-ins | Encrypted and signed by the sender | M3 |
| Good-morning greeting | Opt-in, on the first movement of the day | M3 |
| Fog mode („Nebel“) | Share only a rough area for a while | M3 |
| Places with arrival and departure alerts | Encrypted places, checked on the device | M4 |
| "Not arrived yet" alerts, place suggestions | Checked on the device | M4 |
| History | Opt-in, own retention, deletable and exportable | M5 |
| Trips and driving | CoreMotion trips with route, distance, top speed, hard braking and acceleration; weekly summary | M6 |
| SOS, crash detection | Alert to the circle; no call center | M7 |
| Temporary circles, leaderboards | Circles that expire; opt-in weekly ranking computed on the device | M8 |

Not planned, because they would need a company server, a call center or third parties: emergency dispatch, roadside assistance, insurance, identity-theft services, crime data, tracker hardware. Never: ads, selling or sharing data. Maybe later: a web link for people without the app (static page, key in the URL fragment), an Apple Watch app, weather alerts via WeatherKit.

## M3: Reactions and check-ins
- [x] Emoji reactions and quick notes, end-to-end encrypted, signed by the sender
- [x] Check-in with the current place
- [x] Opt-in morning greeting on the first movement of the day
- [x] Local notifications when the app fetches new notes (open or while sharing in the background)
- [x] Delivery by silent push while the app is closed
- [x] Fog mode: approximate area for a limited time

## M4: Places
- [x] Create and share places (encrypted, signed, re-encrypted after key rotation)
- [x] On-device arrival and departure detection with a leaving margin
- [x] Arrival and departure notifications (signed notes, silent push, local notification)
- [x] Region monitoring (CLMonitor, up to 20 places, "Always" only) wakes the app at place edges while iOS pauses location updates
- [ ] No-show alerts and place suggestions

## M5: History
- [x] Opt-in history with user-chosen retention (1, 7, 30 days), deleted by the writing device
- [x] History view per member: path on the map, distance, time span
- [x] Export (GPX) of your own history

## M6: Trips and driving
- [x] Trip detection on the device (speed-based), opt-in sharing
- [x] Trip records: route, distance, duration, top speed, hard braking, rapid acceleration, score
- [x] Live speed (km/h) while driving
- [x] Weekly summary with leaderboards ("Sicher gefahren", "Am meisten unterwegs")
- [x] Passenger: remove a trip you only rode along on
- [ ] CoreMotion automotive detection
- [ ] Flight detection
- [ ] Battery profiling and tuning

## M7: Safety
- [x] SOS to every circle (hold 3 s), exact position, time-sensitive notification, call 112, all-clear
- [x] Crash detection heuristic with an "Are you OK?" countdown (60 s), then SOS
- [ ] Critical Alerts entitlement (needs Apple's approval)

## M8: Friends, groups, fun and polish
- [x] Temporary circles (1 day, 1 week, 2 weeks)
- [ ] Friend requests, multiple circles and groups
- [x] Opt-in weekly circle leaderboards (driving, distance)
- [x] Weekly badges (safe driving, long distances, explorer)
- [ ] Liquid Glass UI polish, accessibility, localization (DE, EN)
- [ ] Multi-device support and key backup
- [ ] Owner succession if the owner's device is lost
- [ ] Warning when an unverified key appears in a circle

## M9: Monetization and release
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
