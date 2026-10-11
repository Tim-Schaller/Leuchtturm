# Architecture

Status: draft v0. Details will change as the protocol is implemented. Nothing here has been security-reviewed.

## Components

```
┌────────────┐   HTTPS (TLS 1.3)    ┌──────────────────────┐
│ iOS app    │ ───────────────────► │ leuchtturmd (Go)         │
│ SwiftUI    │ ◄─────────────────── │ SQLite, blob store   │
│ CryptoKit  │   WebSocket (live)   │ Hetzner, Germany     │
└─────┬──────┘                      └──────────┬───────────┘
      │                                        │ APNs (opaque payload)
      └───────────── Apple Push ◄──────────────┘
```

- **iOS app:** SwiftUI, iOS 26+, Liquid Glass. CoreLocation (tracking), CoreMotion (drive detection), CryptoKit (crypto), Keychain/Secure Enclave (keys), StoreKit 2 (in-app purchases).
- **Server (`leuchtturmd`):** single Go binary. SQLite (WAL mode) for storage, so no separate database service is needed. Runs on the smallest Hetzner Cloud instance.
- **Push:** APNs with a Notification Service Extension that decrypts the payload on the device.

## Identity and keys

- Each device generates an identity key pair (Curve25519: signing + key agreement) on first launch. The private key stays in the Keychain, protected by the Secure Enclave where possible.
- The account is an anchor only: Sign in with Apple, or an anonymous account identified by the device public key. The login method never has access to location data.
- Adding a second device or recovering after a device loss requires a key backup (planned: user-held recovery phrase, optionally iCloud Keychain). This is an open design question, see ROADMAP.

## Circles

- A circle has a random 256-bit symmetric **circle key**.
- Joining: an existing member shows an invite (code or QR) that contains the circle ID and a one-time secret. The new member's public key is sent to the server, and an existing member wraps the circle key to it (HPKE / sealed box). The server stores only wrapped keys.
- **Key rotation** on member removal: the owner creates a new circle key and wraps it for the remaining members. Old data stays readable only to those who already held the old key.

## Data in transit and at rest

| Data | Encrypted client-side | Visible to server |
|------|-----------------------|-------------------|
| Live location | yes (circle key, AEAD) | ciphertext, size, time |
| Places / geofences | yes | ciphertext only. Evaluated on device |
| Location history (opt-in) | yes | ciphertext, retention deadline |
| SOS / check-in | yes | ciphertext, recipient circle |
| Circle membership | no | which accounts belong to which circle |
| Push tokens | no | token, account |

Each encrypted message carries a sender signature so members can detect tampering by the server.

## Tracking strategy (battery)

| State | Mechanism | Cadence |
|-------|-----------|---------|
| Stationary | Significant-location-change + visits | rare |
| Moving | Standard location updates, reduced accuracy | moderate |
| Driving (CoreMotion automotive) | Best-for-navigation accuracy, live speed | frequent, only while a circle member is watching or an opt-in trip is active |

Viewers register "presence" over the WebSocket. Frequent uploads happen only while someone is watching.

## Retention

- Live location: only the latest value per device is kept.
- History: opt-in per user, with a retention period chosen by the user. The server deletes expired ciphertext automatically.
- Account deletion removes all data immediately.

## Server API sketch

- `POST /v1/accounts`, `POST /v1/devices`: registration with public keys
- `POST /v1/circles`, `POST /v1/circles/{id}/members`: circles and wrapped keys
- `PUT /v1/circles/{id}/location`: upload encrypted location
- `GET /v1/circles/{id}/stream` (WebSocket): live updates
- `GET /healthz`: health check

The API is versioned and documented as it is implemented.

## Hosting and cost

- Hetzner Cloud, smallest shared-CPU instance (about 4-5 EUR/month), Falkenstein or Nuremberg.
- Docker container behind Caddy (automatic TLS) or any reverse proxy.
- SQLite with Litestream-style backups to an EU object store is an option later.

## Licensing split

- `ios/`: MPL-2.0 (compatible with App Store distribution by the project owner)
- everything else: AGPL-3.0 (network use of a modified server requires publishing the changes)
