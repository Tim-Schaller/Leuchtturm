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

- **Metadata at Apple.** Apple knows which iCloud accounts (real identities) share a circle, who owns it, when records are written and their approximate sizes. This is the main privacy cost of using CloudKit instead of a server of our own.
- **Movement patterns from timing.** Location records are written while someone moves (more often with the app open) and not while they stand still, also in the background. Apple can therefore tell when a member is on the move, though not where. A fixed update cadence could hide this later.
- **Chat metadata.** Apple sees when and how often messages are written and the size of pictures, not their content or who replies to whom.
- **Picture sizes.** Profile pictures are encrypted but not padded, so Apple sees their approximate size.
- **History size.** Apple sees on which days a member has history records and roughly how many points (padded size), i.e. how much they moved.
- **Note timing.** Apple sees when a note record is written (not what it says or for whom), and which devices get a silent push for it.
- **Weather requests.** With weather on, Apple Weather receives the members' places rounded to about 1 km.
- **Widgets and lock screen.** Widgets and the Live Activity show names and places on the lock screen; anyone holding the phone can read them. The snapshot file lives unencrypted (besides iOS file protection) in the app's App Group container.
- **Apple Watch and Apple TV.** The watch keeps the widget snapshot unencrypted (besides watchOS file protection). The TV shows the map of the selected circle, including the user, to anyone in the room, and caches the last snapshot. Whoever can sign in to the user's iCloud on a TV still needs the code shown on that TV to get a snapshot.
- **Live links.** Anyone who gets the link sees the position until it ends; it cannot be limited to one viewer. Apple sees that a public record is written and read (and the readers' IP addresses), GitHub sees visits to the page. If the phone dies, the last position stays readable for anyone with the link until the hour is over, then the page shows it as expired; the record itself is deleted the next time the app runs.
- **Long-term driving totals.** With "Fahrten teilen" a member's circles see sums over a year and all time (number of trips, distance, top speed, hard braking), even though single trips are deleted after 30 days. Turning trip sharing off removes them from the profile.
- **Friend requests.** Anyone who has a user's friend code can send them requests under any name. Apple sees which iCloud account writes a request to which mailbox, i.e. who adds whom.
- **Map tiles.** The map comes from Apple Maps, which sees the map areas the app loads. These are usually where the circle's members are.
- **Data location.** iCloud data is stored in Apple's data centers; Apple is a US company. EU-only storage is not guaranteed.
- **Apple as an active attacker on the app itself.** Apple distributes the app binary and operating system.
- **A compromised device.** Malware or physical access to an unlocked phone defeats client-side encryption.
- **A malicious member reading or leaking.** Anyone in a circle can read what the circle shares and can screenshot it.
- **Denial of service by a member.** Any participant can delete records in the zone (CloudKit permission model). Leuchtturm detects forgeries but cannot prevent deletion.
- **Emergencies.** SOS and crash detection only alert the circle. They are not an emergency service, crash detection is a GPS heuristic with false alarms and misses, and an SOS reaches others only as fast as iOS delivers silent pushes.
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
| Someone with access to the user's Apple Account and iCloud Keychain | With the default (synced keys) they get the device keys too. Users who do not want this keep keys on the device only | Keys |
| Device reinstalled or keychain lost | Device cannot verify or decrypt; needs a new invite (no silent re-trust) | M1 |
| Member fakes another member's location | Location records are signed by the member's own device and checked against the key in its member record | M2 |
| Member replays an older location | Readers keep the newest timestamp per device; the shown age reveals stale data. The memory is lost when the app restarts | M2 |
| Someone not admitted shares a location | Only devices in the signed roster appear on the map | M2 |
| Last position stays behind | Pausing, leaving and removal delete the location record | M2 |
| A member wants privacy for a while without leaving | Fog mode: only a grid cell of 2 to 50 km is shared; the exact position stays on the device | M3 |
| Someone fakes a member's trips or driving score | Trips are signed by the driver's device; scores are computed by each reader from verified trips | M6 |
| Someone fakes a member's long-term driving totals | The totals are part of the profile, signed by the driver's own device; readers drop implausible numbers. The driver's device could still lie about itself | Profile |
| Someone fakes or extends a member's history | History days are signed by the member's device; only the device itself writes and deletes them | M5 |
| History kept longer than wanted | The writing device deletes days past its retention, and everything when history is turned off or the member leaves | M5 |
| Member redirects everyone to a circle of their own | Move notices count only from admins in the owner-signed meta, signed with the admin's own keys, which become the new owner keys | Roles |
| Admin removes the owner or other admins | Requests can target only plain members; only the owner's device signs the roster | Roles |
| Admin takes over while the owner is around | Allowed only with the owner's offer or after three days without a sign of life; the takeover is visible to everyone | Roles |
| Member plants a fake place or fakes an arrival | Places and arrival notes are signed by the creating or arriving device | M4 |
| Apple learns where "Home" is | Places are encrypted; geofences are evaluated on the device | M4 |
| Member sends a note in someone else's name | Notes are signed by the sending device and checked against its member record | M3 |
| Someone not admitted posts notes | Only notes from roster devices are shown or notified | M3 |
| Old notes replayed | Note ID is bound into the encryption and the signature; readers notify each ID once and ignore notes older than 7 days | M3 |
| Apple or anyone with access to the user's iCloud reads the TV map | The snapshot is HPKE-encrypted to the TV's own key, which never leaves the TV | Apple TV |
| Someone with database access plants a fake map on the TV | HPKE PSK mode: only a device that scanned the code (pairing secret) can produce a snapshot the TV opens | Apple TV |
| An old TV snapshot is replayed | The TV ignores snapshots older than the one it shows | Apple TV |
| Apple or the web host reads a live link | AES-GCM with a key that exists only in the link fragment, which browsers never send to servers | Live link |
| Someone overwrites a live record with a fake position | Public records can only be changed by their creator; a forged one fails AES-GCM authentication without the key | Live link |
| A live link stays open forever | The expiry is inside the encrypted payload; the page stops after it and the app deletes the record | Live link |
| Someone with a friend code poses as a person the user knows | The request shows the sender's chosen name and safety code; the user decides. Accepting shares the location with that device only | Friends |
| Apple reads friend codes or requests | The code never leaves the devices; the card is encrypted under a key derived from it, requests are HPKE-encrypted to the recipient's device | Friends |
| Someone guesses friend codes | 60-bit codes; a wrong guess finds nothing. Users can make a new code at any time | Friends |
| Supply chain | App uses Apple frameworks only (CryptoKit, CloudKit). swift-crypto is used only for Linux tests | M1 |

## Known limitations

- **Background tracking depends on iOS.** Without "Always" access, sharing stops when the app goes to the background (to avoid a permanent status-bar indicator); a user who force-quits the app stops sharing until they open it again. Silent pushes can be delayed by iOS.
- **Synced keys trust iCloud Keychain.** By default the keys are protected by Apple's iCloud Keychain (end-to-end encrypted, tied to the device passcodes). „Nur auf diesem Gerät“ removes that trust; then every device needs its own invite.
- **Admins are trusted.** An admin can take a circle over once the owner seems inactive (or never shared a location or message). Owners should make only people admins they trust with the circle. Without any admin, a circle whose owner lost their device can no longer be managed.
- **Pending members need the owner.** New members are visible as pending right away, but enter the signed roster only when the owner opens the app. Their admission is verified against the invite record, so if an invite expires and is cleaned up first, the owner must re-invite them.
- **No use limits on invites.** CloudKit cannot enforce them; a link works for anyone until it expires. Owners see every new member.
- **Safety codes are manual.** The app warns when a new key appears in a circle and shows which members were verified, but comparing codes is still up to the people.
- **Members can wake each other's phones.** Refresh and „Wo bist du?“ notes make the others' devices take a fresh position, which costs battery. A device answers refresh notes at most every 30 seconds and the app sends them at most every three minutes per circle; a modified client could send more, but the answers stay limited, and members see such a person in the circle and can remove them.
- **No forward secrecy within an epoch.** Anyone with a circle key can decrypt everything under that epoch. Periodic rotation may be added later.

## Open questions

- Multi-device support and key backup without weakening E2EE.
- Owner succession (e.g. a new zone created by another member).
- Automatic safety-code verification UX.
- Independent security audit before a public App Store launch.
