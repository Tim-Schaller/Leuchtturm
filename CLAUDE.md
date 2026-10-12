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

Tim's requests from 2026-10-12, in this order (Tim reads summaries in German; install every finished build on his iPhone without asking):

1. **Drawer tabs**: the bottom sheet gets tabs, e.g. „Personen“ (start), „Bestenliste“, „Fahrten“, „Orte“ (own idea welcome).
2. **History path coloured by speed**: draw the real path; when driving, colour segments by speed so 30 km/h in town and 250 km/h on the Autobahn are clearly different (gradient, legend).
3. **Profile pictures and a basic chat** (reactions exist). Pictures and messages end-to-end encrypted like everything else (CKAsset or bytes field; pictures small, e.g. 256 px JPEG).
4. **Keys via iCloud Keychain by default** („einfach statt streng“), with an option „nur auf diesem Gerät“. Same identity on all devices of one Apple Account; only one device shares the location (setting). Update threat model.
5. **More languages** (e.g. French, Spanish, Italian, Dutch, Polish, Turkish) in `Localizable.xcstrings` / `InfoPlist.xcstrings`.
6. **Privacy policy** (German and English) as a page in the repo for the App Store URL.
7. **CloudKit schema**: Tim does not know this step. Explain: records types are created automatically only in the Development environment; before TestFlight the schema must be deployed to Production in the CloudKit Console. Build a debug helper that writes one record of every type in Development, then deploy together with Tim in Claude in Chrome.
8. **TestFlight** as soon as ready (Tim tests with his girlfriend, which also covers the two-account checks below). App Store Connect is set up together in Claude in Chrome.
9. Answer Tim's question „welche Features brauchen wir noch?“ with a short list.

Still open from before: verify on real CloudKit with **two** iCloud accounts (creator/lastModified user IDs and `CKCurrentUserDefaultName` normalization, removing a public-link participant, leaving by deleting the `CKShare`, `recordZoneChanges` returning all records, silent pushes, takeover across accounts).
