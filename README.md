# Leuchtturm

**Privacy-first location sharing for friends and family. End-to-end encrypted, EU-hosted, open source.**

Leuchtturm is a native iOS app (SwiftUI, Liquid Glass) for sharing your location with the people you choose, without handing your movements to a company that monetizes them. The server only ever sees ciphertext.

> **Status:** early development. Nothing here is released or audited yet. Do not rely on Leuchtturm for safety-critical use.

## Features (planned)

- Live location in circles and groups, with friend requests and invite codes / QR
- Places (geofences) with arrival and departure alerts, evaluated **on your device**
- Location history, **opt-in**, with a retention period you choose
- SOS and check-in, **opt-in**
- Drive detection with live speed (km/h)
- Adaptive tracking to keep battery drain low (idle = rare updates, driving = frequent)
- Sign in with Apple, device-key identity, or invite code. Email and Google may follow.

Safety features (live location, circles, SOS, check-in) will always be free. Optional in-app purchases only cover convenience (e.g. longer history, extra themes), with no ads and no intrusive paywalls.

## Privacy model

- **End-to-end encryption.** Each device generates its own key pair (Secure Enclave / CryptoKit). Each circle has a symmetric key that is distributed to members encrypted to their public keys. Locations, places and history are encrypted before upload.
- **Geofences run on the device.** The server never learns where "Home" is.
- **No tracking, no ads, no third-party analytics SDKs.**
- **EU hosting.** The reference backend runs on Hetzner Cloud in Germany.
- **Self-hostable.** The server is a single Go binary / Docker container.

### What the server can still see

End-to-end encryption protects content, not metadata. A server operator can see: which accounts exist, which devices belong to which circle, when a device uploads data, approximate payload sizes, IP addresses at connection time, and push notification tokens. See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for what we protect against and what we do not.

## Repository layout

| Path | Contents | License |
|------|----------|---------|
| `ios/` | SwiftUI app (iOS 26+) | MPL-2.0 |
| `server/` | Go backend, Dockerfile | AGPL-3.0 |
| `docs/` | Architecture, threat model, roadmap | AGPL-3.0 |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/ROADMAP.md](docs/ROADMAP.md).

## Building

**Server** (Go 1.24+):

```sh
cd server
go test ./...
go run ./cmd/leuchtturmd
```

or with Docker:

```sh
cd server
docker compose up --build
```

**iOS app** (macOS, Xcode 26+):

```sh
brew install xcodegen
cd ios
xcodegen generate
open Leuchtturm.xcodeproj
```

## Licenses

- Everything outside `ios/` is licensed under the [GNU AGPL-3.0](LICENSE).
- The iOS app in `ios/` is licensed under the [Mozilla Public License 2.0](ios/LICENSE).
- The name "Leuchtturm" and the logo are trademarks of the project owner; see [TRADEMARKS.md](TRADEMARKS.md).

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first, including the contributor license agreement.

## Security

Please report vulnerabilities privately via GitHub's "Report a vulnerability" feature on the Security tab, not in public issues.
