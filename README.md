# Leuchtturm

**Privacy-first location sharing for friends and family. End-to-end encrypted, stored in iCloud, open source.**

Leuchtturm is a native iOS app (SwiftUI, Liquid Glass) for sharing your location with the people you choose, without handing your movements to a company that monetizes them. Everything is encrypted on the iPhone before it is stored.

> **Status:** early development. Milestone M1 (encrypted circles and invites, no location yet) is implemented and tested; nothing is released or audited. Do not rely on Leuchtturm for safety-critical use.

## Where your data lives (please read)

Leuchtturm has **no server of its own**. It stores data in **Apple iCloud (CloudKit)**: each circle lives in the iCloud of the person who created it and is shared with the members through iCloud sharing.

| | |
|---|---|
| **Apple cannot read** | circle names, display names, and later locations, places and history. They are encrypted on the iPhone with keys Apple never sees. |
| **Apple can see** | which iCloud accounts are in the same circle, who created it, when data is written, and approximate data sizes. Apple knows the real identities behind iCloud accounts. |
| **Location of the data** | Apple's data centers. Apple is a US company; storage in the EU is not guaranteed. |
| **Requirements** | Every member needs an iPhone signed in to iCloud. The data counts (negligibly) against the circle owner's iCloud storage. |
| **Cost** | Free. No server to run or pay for. |

An earlier version of this project used a self-hosted server in the EU, which saw only anonymous keys. It was replaced by CloudKit so the app works without anyone running hardware. The trade-off is that Apple sees who is connected with whom (metadata), even though it cannot see content. See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## Features

Working now (M1):

- Circles with encrypted names and display names
- Invites via link or QR code, with expiry
- Removing members rotates the circle key and revokes their iCloud access
- People who only obtained the iCloud share link (without the invite secret) are not admitted and are flagged to the owner
- Safety codes to verify members in person

Planned:

- Live location in circles, places (geofences) evaluated **on the device**, opt-in history with your own retention period, opt-in SOS and check-in
- Drive detection with live speed (km/h)
- Adaptive tracking to keep battery drain low

Safety features (live location, circles, SOS, check-in) will always be free. Optional in-app purchases only cover convenience, with no ads and no intrusive paywalls.

## Privacy model in short

- **End-to-end encryption.** Each iPhone has its own keys (CryptoKit, Keychain, this device only). Each circle has a key distributed with HPKE. Content is encrypted before upload.
- **Cryptographic membership.** In an iCloud share any participant can write any record, so Leuchtturm does not trust iCloud for membership: the circle record is signed by the owner's device, every member record is signed by its own device, and new members prove they knew the invite secret.
- **Geofences will run on the device.** Apple will never learn where "Home" is.
- **No tracking, no ads, no third-party SDKs.**

## Repository layout

| Path | Contents |
|------|----------|
| `ios/Leuchtturm` | SwiftUI app (iOS 26+) |
| `ios/LeuchtturmCore` | Crypto, record formats, CloudKit backend and client logic (Swift package; the logic also builds and is tested on Linux) |
| `docs/` | Architecture, threat model, roadmap, test vectors |

## Building

**Core library** (Swift 6, macOS or Linux):

```sh
cd ios/LeuchtturmCore
swift test
```

The tests run the full circle lifecycle, including attacks, against an in-memory CloudKit simulation.

**iOS app** (macOS, Xcode 26+, Apple Developer account for iCloud):

```sh
brew install xcodegen
cd ios
xcodegen generate
open Leuchtturm.xcodeproj
```

In Xcode, select your team under *Signing & Capabilities*. The iCloud container is `iCloud.de.timschaller.leuchtturm`; forks must use their own bundle ID and container. iCloud only works on a device or simulator signed in to an Apple Account.

## License

[Mozilla Public License 2.0](LICENSE). The name "Leuchtturm" and the logo are trademarks of the project owner; see [TRADEMARKS.md](TRADEMARKS.md).

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first, including the contributor license agreement.

## Security

Please report vulnerabilities privately via GitHub's "Report a vulnerability" feature on the Security tab, not in public issues.
