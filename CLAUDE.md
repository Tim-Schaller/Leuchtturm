# Leuchtturm – notes for Claude Code

Privacy-first location sharing for families on iOS. Owner: Tim (GitHub `Tim-Schaller`). Tim does not write code himself; explain decisions briefly in German, keep answers direct and concise.

## Layout

- `ios/Leuchtturm/` – SwiftUI app (iOS 26+, Liquid Glass). UI text in **German** (source), English in `Localizable.xcstrings` / `InfoPlist.xcstrings`. In the UI a circle is called a **Leuchtturm** ("einen Leuchtturm gründen", English "lighthouse"); code and docs say "circle". After changing UI text: build, run `python3 ios/scripts/check-strings.py`, add the missing English entries. Text outside SwiftUI views needs `String(localized:)`.
- `ios/LeuchtturmCore/` – Swift package: crypto, record formats, `CircleBackend` (CloudKit + in-memory simulation), `LeuchtturmClient`. Builds and tests on macOS and Linux.
- `ios/project.yml` – XcodeGen spec. `Leuchtturm.xcodeproj`, `Info.plist` and `.entitlements` are **generated and gitignored**.
- `docs/` – `ARCHITECTURE.md` (record formats, the source of truth), `THREAT_MODEL.md`, `ROADMAP.md`, `test-vectors/`.

## Commands

```sh
# Core tests (fast, no signing, no iCloud)
cd ios/LeuchtturmCore && swift test

# Regenerate the Xcode project after changing project.yml or adding files
cd ios && xcodegen generate          # brew install xcodegen

# Build + app tests on a simulator
cd ios && xcodebuild test -project Leuchtturm.xcodeproj -scheme Leuchtturm \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

# Build for running with signing (team TW877YHM7Q is set in project.yml)
cd ios && xcodebuild -project Leuchtturm.xcodeproj -scheme Leuchtturm \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -allowProvisioningUpdates build

# Start in the simulation mode (debug builds only, no iCloud needed)
xcrun simctl launch 'iPhone 18 Pro' de.timschaller.leuchtturm -simulation
# ... already set up as "Tim" with the demo circle "Familie" (Anna, Ben, Clara): best for screenshots
xcrun simctl launch 'iPhone 18 Pro' de.timschaller.leuchtturm -simulationDemo

# Tim's iPhone ("iPhone 17 Pro von Tim", paired): build with -destination 'id=00008150-001C182226FB801C', then
xcrun devicectl device install app --device 00008150-001C182226FB801C <path>/Debug-iphoneos/Leuchtturm.app
xcrun devicectl device process launch --device 00008150-001C182226FB801C de.timschaller.leuchtturm
```

Simulator text input: the simulator tool's `text` action does not fill the clipboard. Use `printf 'Text' | xcrun simctl pbcopy booted`, then long-press the field and tap „Einsetzen“.

CI (`.github/workflows/ci.yml`): core tests on Linux (swift-crypto) and macOS (CryptoKit, also compiles CloudKitBackend), app build + tests on an iOS simulator. Keep it green.

## Rules

- Swift 6 language mode, strict concurrency. No warnings.
- **Privacy**: nothing personal goes to CloudKit unencrypted. Every record must be verifiable (owner-signed circle record, self-signed member records, HPKE-auth key wraps). Never trust a record just because CloudKit returned it: any share participant can overwrite any record.
- Never name other apps or companies (competitors) in the code, UI, docs, README, commit messages or App Store metadata, and do not reuse their feature names; describe our own features in our own words.
- No third-party SDKs in the app. CryptoKit and CloudKit only (swift-crypto is a Linux-only test dependency).
- Record format or crypto changes: update `docs/ARCHITECTURE.md`, `docs/THREAT_MODEL.md` if the security picture changes, and tests (including attack tests in `ClientTests.swift`).
- Be honest in user-facing text about what Apple can see (metadata: which iCloud accounts share a circle).
- License MPL-2.0. Commit to `main` is fine for now; run tests before pushing.

## Current state (2026-10-11)

- M1 done in code: identity, circles, invites (link + QR), admission proofs, removal with key rotation, safety codes, settings.
- M2 started: signed + encrypted `Location` records (`SharedLocation.swift`, `LeuchtturmClient.shareLocation`), `LocationTracker` (CLLocationManager; background only with "Always" and without the blue indicator, paused when stationary, woken by significant changes and visits; started by `AppModel.updateTracking()` so it also runs after a background relaunch; upload rules in `SharePolicy`), home screen is the map (`MapHomeView` + `PeopleSheet` drawer). The map polls every 30 s; silent CloudKit pushes (`CloudKitBackend.subscribeToChanges`, `AppDelegate`) wake the app to fetch news. Background sharing still needs a real-device test (Settings shows "Zuletzt geteilt"). 52 core tests and 23 app tests green.
- M3 started: `Note` records (`CircleNote.swift`, `LeuchtturmClient.send`) for reactions, quick notes, check-ins and good-morning; local notifications in `AppModel.deliverNews`; UI in `Views/NotesViews.swift`. Battery and fog size travel in the location payload; fog mode („Nebel“) snaps to a fixed grid (`SharedLocation.inFog`).
- M4 started: `Place` records (`CirclePlace.swift`), on-device `PlaceTracker`, arrivals/departures sent as notes; UI in `Views/PlacesViews.swift`. Demo circle includes places on Anna's and Ben's routes.
- M5: opt-in `History` records (`LocationHistory.swift`), uploaded with the location (`shareLocation(_:history:)`), local `HistoryRecorder`, `HistoryView`.
- M6: opt-in `Trip` records and `TripDetector` (`Trip.swift`), live speed in the location, `DriverStats.leaderboard`, `WeekView`/`TripView`. Demo: Ben and Clara have trips this week.
- M7: SOS and all-clear as notes (`sos`, `safe`), `SOSSheet`, crash suspicion in `TripDetector.takeCrash()`, `CrashCheckView` countdown, notification actions; time-sensitive entitlement.
- "Not arrived yet": local-only `ArrivalWatch` (`ArrivalWatch.swift`), scheduled as local notifications in `AppModel.scheduleArrivalWatches`, UI `ArrivalWatchSection`.
- Place suggestions: `VisitStore` (local CLVisit stays) + `PlaceSuggestion.suggest`, shown in `PlacesSection`.
- Roles and takeover: `CircleMeta.admins`, admin requests as notes carried out by the owner's device (`carryOutAdminRequests`), `takeOver` creates a new circle and a signed `Move` record (`MoveNotice.swift`); `circles()` follows valid moves. UI in `Views/RoleViews.swift`. Tests in `RoleTests.swift`.
- M8 parts: temporary circles (`CircleMeta.expires`), passenger trip removal, weekly badges (`Badge.earned`), GPX export, low-battery note, CLMonitor place wake-ups.
- Design: green, landscape, cute lighthouse. Palette and assets in `docs/assets` and `ios/Leuchtturm/Assets.xcassets`; app colors and avatars in `Views/Theme.swift`; rounded font app-wide.
- Simulation mode (debug builds, `ios/Leuchtturm/Simulation`): `SimulatedWorld` runs Anna, Ben and Clara as real `LeuchtturmClient`s on `InMemoryCloud`, with an in-memory key store and name. Activated by `-simulation`, the setup screen or settings; the orange „Simulation“ button controls the people. Everything is `#if DEBUG`; check that release builds stay free of it.
- Storage switched from a self-hosted Go server to **CloudKit** (server is in git history before commit `415663a`).
- iCloud container: `iCloud.de.timschaller.leuchtturm` (entitlement in project.yml). Signing works (automatic, team TW877YHM7Q) and the container is registered. The app runs on Tim's iPhone against real iCloud (Development environment, one account). The CloudKit schema is created just-in-time in the Development environment on first save; deploy it to Production before TestFlight.

## Next steps

**Goal from Tim (2026-10-12), work through all of it; tick items here as they land.** Install every finished build on Tim's iPhone without asking. Check the 5-hour limit before bigger steps; at 95 % commit and schedule a one-shot resume after the reset.

Build order (dependencies first):
- [x] 1. Keys via iCloud Keychain by default (synchronizable), option „nur auf diesem Gerät“; threat model update.
- [x] 11/19/24. `Profile` record per device: picture, banner, pin colour/emoji, status emoji with expiry; shown on map, lists, chat.
- [x] 10. Chat tab: messages with reply, photos and Apple stickers (Genmoji/adaptive image glyphs), encrypted.
- [x] 13. „Wo bist du?“ request wakes the other phone for a fresh location.
- [x] 15. „Hol mich ab“ with location.
- [x] 12. „Bin auf dem Weg“ with ETA (MKDirections) and automatic arrival message.
- [x] 14. Heimweg-Begleitung: watchers' devices alert if not home by the deadline.
- [x] 16. Treffpunkt in the middle of everyone (MKLocalSearch nearby).
- [x] 9. Friends list across all Leuchttürme (`Views/FriendsView.swift`, map button).
- [x] 20. Weekly challenges and streaks. 21. Steps leaderboard (HealthKit, opt-in). 22. „Heute vor einem Jahr“ from a local-only archive. 23. Weather at a person's place (WeatherKit).
- [x] 5/17. Widgets (home and lock screen) via App Group snapshot. 7. Live Activity while driving / on the way. 18. Siri and Shortcuts (App Intents).
- [x] 25. iPad layout (`NavigationSplitView` in `MapHomeView` for regular width; iPad shares no location by default).
- [x] 6. Apple Watch app (`LeuchtturmWatch`, WatchConnectivity snapshot, SOS/check-in via iPhone) and Apple TV app (`LeuchtturmTV`, QR pairing, HPKE-PSK snapshot record `TVSnapshot` in the private DB; `TVLink.swift`, `TVPublisher.swift`). Demo: launch argument `-demo` on watch and TV, `-pairing` shows the TV code without iCloud.
- [x] 8. 1-hour live link (`LiveLink.swift`, `LiveLinkSharing.swift`, page in `docs/live`). **Needs Tim before it works:** GitHub Pages from `main` `/docs`; a CloudKit API token (read-only web access) in `docs/live/config.js`; record type `LiveLocation` (public DB, field `blob`, World read) appears in Development on the first save and must go to Production; optional MapKit JS token for an embedded map.
- [x] 2. Languages fr, es, it, nl, pl, tr in all catalogs (app, InfoPlist, widgets, watch, TV) and the live page. `python3 ios/scripts/check-strings.py` checks all targets and languages (build app and TV for the simulator first). Group term: phare/faro/faro/vuurtoren/latarnia/fener; app name stays Leuchtturm.
- [x] 3. Privacy policy `docs/privacy/index.html` (de, binding) and `en.html`, landing page `docs/index.html` (GitHub Pages from `/docs`, `.nojekyll`), with Tim's c/o address and Impressum link.
- [x] 4. TestFlight (2026-10-12): app „Leuchtturm – Location Sharing“ (ASC ID 6821851196, bundle `de.timschaller.leuchtturm`, iOS + tvOS), CloudKit schema in Production, GitHub Pages on, web API tokens in `docs/live/config.js`, export compliance „none of the listed algorithms“ (CryptoKit only, also `ITSAppUsesNonExemptEncryption = NO`). Internal group „Leuchtturmwärter“ with automatic distribution; Tim's girlfriend (team role Kundendienst, access to all apps) invited. New builds: `ios/scripts/testflight.sh` (timestamp build numbers). Next: external testing group (needs Beta App Review and test information). New record types or fields: create them in Development (debug button or `cktool`), then deploy to Production before the build that uses them.

Working notes (2026-10-12, for continuing after a context reset):
- **Open:** FriendCode/FriendRequest exist in Development (index `to` queryable) but are not in Production yet (the console deploy failed with "Error performing DAW auth"): Tim must sign in to the CloudKit console again, then deploy. Until then the friends menu shows "Dein Code konnte gerade nicht erstellt werden" on Production builds.
- Done 2026-10-12 evening: launch screen + `BeaconLoading`, serialized `LocationTracker.monitor(places:)` (a second `CLMonitor` with the same name froze the app), one alert at a time (`AppModel.errorPresenters`: two alerts at once made iOS close the front sheet and left the drawer stuck), labeled friends button, `FeaturesSheet` (shown once after the first Leuchtturm), quick actions grouped in `ActionSections` (Unterwegs, Treffen, Dein Standort; rows explain themselves; check-in only on the watch as „Alles gut“ and via Siri), map framing in `MapHomeView.show(_:atLeast:drawer:)` (only the top row is a safe-area inset; MapKit fits camera rects into the safe area, whose height comes from `onMapCameraChange`), German InfoPlist strings marked translated (state "new" left them out of `de.lproj`).
- **Next (Tim, 2026-10-12 22:10), in this order:** (1) snap sparse trip gaps to roads with Apple Maps at the end of a trip (MKDirections between points more than ~300 m apart, plausibility check, splice, then `RouteShape.simplify` to 300; setting under Fahrten, honest text that Apple sees the gap's end points); (2) shared rides: trips of several members overlapping in time and place are one „Gemeinsame Fahrt“ in `WeekView`, each device asks once „Bist du gefahren?“ (notification + in-app), passengers' trips get an optional flag in the Trip payload and do not count for leaderboard and stats; (3) then a TestFlight build (`ios/scripts/testflight.sh`), watch the 5-hour limit.
- **Tracking (2026-10-12 evening):** driving mode in `LocationTracker` (≥ 6 m/s: best accuracy, 10 m, automotive), all batched points go to `TripDetector` (route every 15 m, Douglas–Peucker `RouteShape` to 300), `SharePolicy.driving` (5 s), battery change ≥ 5 points uploads, 100 m `CLMonitor` fence on pause, `BGAppRefreshTask` `de.timschaller.leuchtturm.refresh`, silent `refresh` notes from an open map (`AppModel.askForFreshPositions`), map polls every 10 s. Needs a real drive to judge.
- **CloudKit environments:** Debug builds on the simulator use Development; builds for Tim's iPhone (`deploy.sh` passes `CLOUDKIT_ENVIRONMENT=Production`) and TestFlight use Production, so Tim meets his TestFlight testers. Every new record type or field must be in Production before such a build uses it (add in Development, deploy in the CloudKit console). Invite and live links carry `e=d|p`.
- **Friends by code** (2026-10-12): `FriendCode.swift`, `Friends.swift`, `PublicDatabase.swift` (core), `FriendsModel.swift`, `Views/FriendsView.swift`; friendship = circle with `CircleMeta.kind = "friend"`. Record types `FriendCode` and `FriendRequest` (field `to` QUERYABLE) still need to be created in Development and deployed to Production (ask Tim). Simulation: Max (not in Familie) for friend codes.
- Done and pushed: all 25 items. TestFlight builds 202610120801 (iOS) and 202610120806 (tvOS) are with the internal group.
- An accidental commit of `ios/build/` (~200 MB) was removed from the history with Tim's OK (force push 2026-10-12); `ios/build/` is ignored.
- Helpers in the session scratchpad (recreate if missing): `apptest.sh` runs the app tests with an 8-minute cap (plain `xcodebuild test` sometimes hangs after finishing), `deploy.sh` builds/installs/launches on the iPhone, `tr.py` adds English entries to `Localizable.xcstrings`; `i18n/` has the translation source, validator and merge script.
- After UI text changes: build app and TV for the simulator, `python3 ios/scripts/check-strings.py`, add all 7 languages. Demo for screenshots: `xcrun simctl launch 'iPhone 18 Pro' de.timschaller.leuchtturm -simulationDemo` (add `-AppleLanguages "(fr)"` for other languages).

Still open from before: verify on real CloudKit with **two** iCloud accounts (creator/lastModified user IDs and `CKCurrentUserDefaultName` normalization, removing a public-link participant, leaving by deleting the `CKShare`, `recordZoneChanges` returning all records, silent pushes, takeover across accounts). Tim's girlfriend via TestFlight covers this.
