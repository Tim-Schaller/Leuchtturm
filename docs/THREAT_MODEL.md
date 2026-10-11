# Threat model

Status: v1.1 for CloudKit (M1: identity, circles, invites; M2 in progress: encrypted live locations and the map). Not independently reviewed.

## Parties

- **Members**: people in a circle, each with one iPhone.
- **Owner**: the member whose device created the circle (trust anchor).
- **Apple**: operates iCloud/CloudKit, stores all records, controls zone access, push delivery and the App Store.
- **Outsiders**: anyone else, including people who obtained a share URL or an invite link.

## Goals

1. Apple (or anyone who breaches iCloud) cannot read locations, places, history, circle names or display names.
2. Only admitted members can read a circle's data. Removed members cannot read anything shared after their removal.
3. A member cannot impersonate another member or the owner.
4. The project collects no data itself (there is no project server).

## Non-goals (not protected against)

- **Metadata at Apple.** Apple knows which iCloud accounts (real identities) share a circle, who owns it, when records are written and their approximate sizes. This is the main privacy cost of using CloudKit instead of a self-hosted server.
- **Movement patterns from timing.** Location records are written more often while someone moves (every 25 m, at most every 2 minutes) than while they stand still. Apple can therefore tell when a member is on the move, though not where. A fixed update cadence could hide this later.
- **Map tiles.** The map comes from Apple Maps, which sees the map areas the app loads. These are usually where the circle's members are.
- **Data location.** iCloud data is stored in Apple's data centers; Apple is a US company. EU-only storage is not guaranteed.
- **Apple as an active attacker on the app itself.** Apple distributes the app binary and operating system.
- **A compromised device.** Malware or physical access to an unlocked phone defeats client-side encryption.
- **A malicious member reading or leaking.** Anyone in a circle can read what the circle shares and can screenshot it.
- **Denial of service by a member.** Any participant can delete records in the zone (CloudKit permission model). Leuchtturm detects forgeries but cannot prevent deletion.
- **Coercion and stalking by a trusted person.** Location sharing can be abused. Leuchtturm will show clear sharing indicators and lets users leave at any time, but cannot prevent misuse by someone with access to the victim's phone.

## Threats and mitigations

| Threat | Mitigation | Status |
|--------|------------|--------|
| Apple or an iCloud breach reads content | Content encrypted on device; keys never leave devices; names padded | M1 |
| Someone obtains only the iCloud share URL | Without the invite secret: no circle key, no valid admission proof; ignored by members, flagged to the owner, removable | M1 |
| Invite link intercepted | Links expire (1 h to 7 days); joiners appear in the member list; removal rotates the key and kills all open invites | M1 |
| Member forges another member's record | Member records are signed by their own device and bound to the device ID (hash of the key) | M1 |
| Member forges circle name, roster or epoch | Circle record must be signed by the pinned owner device | M1 |
| Member hands out a fake circle key | Wrapped keys are accepted only from the owner device (HPKE auth mode) | M1 |
| Member moves cards between devices or epochs | Card AAD binds circle, device and epoch | M1 |
| Removed member keeps reading | Removed from the iCloud share and atomic key rotation | M1 |
| Apple injects its own device into a circle | Apple could add a participant to the share, but that device has no invite proof and gets no key. Safety codes detect key substitution when compared in person | M1 |
| Apple substitutes the owner's keys for a new joiner | Owner keys come from the invite payload, authenticated by the secret that Apple never sees | M1 |
| Device reinstalled or keychain lost | Device cannot verify or decrypt; needs a new invite (no silent re-trust) | M1 |
| Member fakes another member's location | Location records are signed by the member's own device and checked against the key in its member record | M2 |
| Member replays an older location | Readers keep the newest timestamp per device; the shown age reveals stale data. The memory is lost when the app restarts | M2 |
| Someone not admitted shares a location | Only devices in the signed roster appear on the map | M2 |
| Last position stays behind | Pausing, leaving and removal delete the location record | M2 |
| Supply chain | App uses Apple frameworks only (CryptoKit, CloudKit). swift-crypto is used only for Linux tests | M1 |

## Known limitations

- **Location only while the app is open.** Background tracking and push updates are not built yet; the map polls every 30 seconds.
- **Single device per person.** A second iPhone or iPad needs its own invite.
- **The owner device is a single point of failure.** If the owner loses their iPhone, the circle can no longer be managed (no new admissions, removals or renames); members can still read it. Ownership transfer is not possible with CloudKit zones.
- **Pending members need the owner.** New members are visible as pending right away, but enter the signed roster only when the owner opens the app. Their admission is verified against the invite record, so if an invite expires and is cleaned up first, the owner must re-invite them.
- **No use limits on invites.** CloudKit cannot enforce them; a link works for anyone until it expires. Owners see every new member.
- **Safety codes are manual.** Nothing warns yet when an unverified key appears.
- **No forward secrecy within an epoch.** Anyone with a circle key can decrypt everything under that epoch. Periodic rotation may be added later.

## Open questions

- Multi-device support and key backup without weakening E2EE.
- Owner succession (e.g. a new zone created by another member).
- Automatic safety-code verification UX.
- Independent security audit before a public App Store launch.
