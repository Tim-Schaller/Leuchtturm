# Leuchtturm – notes for Claude Code

Privacy-first location sharing for iOS (Life360 alternative). Owner: Tim (GitHub `Tim-Schaller`). Tim does not write code himself; explain decisions briefly in German, keep answers direct and concise.

## Layout

- `ios/Leuchtturm/` – SwiftUI app (iOS 26+, Liquid Glass). UI text in **German**.
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
```

CI (`.github/workflows/ci.yml`): core tests on Linux (swift-crypto) and macOS (CryptoKit, also compiles CloudKitBackend), app build + tests on an iOS simulator. Keep it green.

## Rules

- Swift 6 language mode, strict concurrency. No warnings.
- **Privacy**: nothing personal goes to CloudKit unencrypted. Every record must be verifiable (owner-signed circle record, self-signed member records, HPKE-auth key wraps). Never trust a record just because CloudKit returned it: any share participant can overwrite any record.
- No third-party SDKs in the app. CryptoKit and CloudKit only (swift-crypto is a Linux-only test dependency).
- Record format or crypto changes: update `docs/ARCHITECTURE.md`, `docs/THREAT_MODEL.md` if the security picture changes, and tests (including attack tests in `ClientTests.swift`).
- Be honest in user-facing text about what Apple can see (metadata: which iCloud accounts share a circle).
- License MPL-2.0. Commit to `main` is fine for now; run tests before pushing.

## Current state (2026-10-11)

- M1 done in code: identity, circles, invites (link + QR), admission proofs, removal with key rotation, safety codes, settings. 27 core tests green, CI green.
- Storage switched from a self-hosted Go server to **CloudKit** (server is in git history before commit `415663a`).
- iCloud container: `iCloud.de.timschaller.leuchtturm` (entitlement in project.yml). Signing works (automatic, team TW877YHM7Q) and the container is registered. The app has not been run against real iCloud yet. The CloudKit schema is created just-in-time in the Development environment on first save; deploy it to Production before TestFlight.

## Next steps

1. Run the app against real iCloud (simulator signed in to an Apple Account, or Tim's iPhone).
2. Verify on real CloudKit with **two** iCloud accounts (cannot be tested in the simulation):
   - creator/lastModified user IDs of records and `CKCurrentUserDefaultName` normalization in `CloudKitBackend.normalize`,
   - removing a public-link participant via `share.removeParticipant`,
   - leaving a share by deleting the `CKShare` from the shared database,
   - `recordZoneChanges` returning all records of a shared zone.
3. M2: encrypted location records, CloudKit subscriptions (silent push), MapKit view, adaptive background location. See `docs/ROADMAP.md`.
