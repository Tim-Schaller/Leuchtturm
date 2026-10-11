# Leuchtturm

**Privacy-first location sharing for friends and family. End-to-end encrypted, EU-hosted, open source.**

Leuchtturm is a native iOS app (SwiftUI, Liquid Glass) for sharing your location with the people you choose, without handing your movements to a company that monetizes them. The server only ever sees ciphertext.

> **Status:** early development. Milestone M1 (encrypted circles and invites, no location yet) is implemented and tested; nothing is released or audited. Do not rely on Leuchtturm for safety-critical use.

## Features

Working now (M1):

- Circles with encrypted names and display names
- Invites via link or QR code, with expiry and use limits
- Removing members rotates the circle key
- Safety codes to verify members in person
- No accounts or passwords: each device signs its requests with its own key

Planned:

- Live location in circles and groups, with friend requests and invite codes / QR
- Places (geofences) with arrival and departure alerts, evaluated **on your device**
- Location history, **opt-in**, with a retention period you choose
- SOS and check-in, **opt-in**
- Drive detection with live speed (km/h)
- Adaptive tracking to keep battery drain low (idle = rare updates, driving = frequent)
- Multi-device support, with Sign in with Apple, email or Google as optional anchors

Safety features (live location, circles, SOS, check-in) will always be free. Optional in-app purchases only cover convenience (e.g. longer history, extra themes), with no ads and no intrusive paywalls.

## Privacy model

- **End-to-end encryption.** Each device generates its own keys (CryptoKit, stored in the Keychain on this device only). Each circle has a symmetric key that is distributed to members with HPKE. Names today, and locations, places and history later, are encrypted before upload.
- **Geofences run on the device.** The server never learns where "Home" is.
- **No tracking, no ads, no third-party analytics SDKs.**
- **EU hosting.** The reference backend runs on Hetzner Cloud in Germany.
- **Self-hostable.** The server is a single Go binary / Docker container.

### What the server can still see

End-to-end encryption protects content, not metadata. A server operator can see: which devices exist (public keys only), which devices belong to which circle and who owns it, when a device makes requests, padded payload sizes, IP addresses at connection time, and later push notification tokens. The server does not log IP addresses. See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for what we protect against and what we do not.

## Repository layout

| Path | Contents | License |
|------|----------|---------|
| `ios/Leuchtturm` | SwiftUI app (iOS 26+) | MPL-2.0 |
| `ios/LeuchtturmCore` | Crypto, protocol and API client (Swift package, also builds on Linux) | MPL-2.0 |
| `server/` | Go backend, Dockerfile | AGPL-3.0 |
| `docs/` | Architecture, API, threat model, roadmap, test vectors | AGPL-3.0 |

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/API.md](docs/API.md) and [docs/ROADMAP.md](docs/ROADMAP.md).

## Building

**Server** (Go 1.26+):

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

Settings: `LEUCHTTURM_ADDR` (default `:8080`), `LEUCHTTURM_DATA_DIR` (default `./data`), `LEUCHTTURM_MAX_MEMBERS` (default 500). Put it behind a TLS reverse proxy (e.g. Caddy) at the root of a (sub)domain.

**Core library** (Swift 6, macOS or Linux), including end-to-end tests against a running server:

```sh
cd ios/LeuchtturmCore
swift test                                            # unit tests
LEUCHTTURM_TEST_SERVER=http://127.0.0.1:8080 swift test   # plus end-to-end
```

**iOS app** (macOS, Xcode 26+):

```sh
brew install xcodegen
cd ios
xcodegen generate
open Leuchtturm.xcodeproj
```

For testing on a real iPhone against a server on your Mac, enter `http://<your-mac-ip>:8080` during setup (plain HTTP is only allowed for local network addresses).

## Licenses

- Everything outside `ios/` is licensed under the [GNU AGPL-3.0](LICENSE).
- The iOS app in `ios/` is licensed under the [Mozilla Public License 2.0](ios/LICENSE).
- The name "Leuchtturm" and the logo are trademarks of the project owner; see [TRADEMARKS.md](TRADEMARKS.md).

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first, including the contributor license agreement.

## Security

Please report vulnerabilities privately via GitHub's "Report a vulnerability" feature on the Security tab, not in public issues.
