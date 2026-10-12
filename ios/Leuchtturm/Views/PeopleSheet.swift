import CoreLocation
import LeuchtturmCore
import MapKit
import SwiftUI

enum DrawerRoute: Hashable {
    case member(String)
    case history(String)
    case week
    case trip(Trip)
    case manage(CircleRef)
}

/// The drawer at the bottom of the map: everyone in the circle, with how
/// long ago and how far away they were seen.
struct PeopleSheet: View {
    static let peek = PresentationDetent.height(190)

    @Environment(AppModel.self) private var model
    let details: CircleDetails?
    let circle: CircleSummary?
    @Binding var sheet: HomeSheet?
    @Binding var path: [DrawerRoute]
    let onFocus: (CircleMember) -> Void
    let onShowPlace: (SharedLocation) -> Void
    let onSelectCircle: (CircleRef) -> Void
    /// An invite from the simulation, shown once its sheet has closed.
    @State private var receivedInvite: InviteLink?

    var body: some View {
        @Bindable var bindable = model
        NavigationStack(path: $path) {
            content
                .navigationTitle(circle?.name ?? AppInfo.name)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: DrawerRoute.self) { route in
                    switch route {
                    case let .member(id):
                        if let member = details?.members.first(where: { $0.id == id }) {
                            MemberDetailView(member: member, ref: circle?.ref)
                        }
                    case let .history(id):
                        if let member = details?.members.first(where: { $0.id == id }), let ref = circle?.ref {
                            HistoryView(member: member, ref: ref)
                        }
                    case .week:
                        if let details { WeekView(details: details) }
                    case let .trip(trip):
                        TripView(trip: trip, member: details?.members.first { $0.id == trip.deviceID })
                    case let .manage(ref):
                        CircleDetailView(ref: ref)
                    }
                }
        }
        .errorAlert()
        .sheet(item: $sheet, onDismiss: showReceivedInvite) { sheet in
            presented(sheet)
        }
        .sheet(item: $bindable.pendingInvite) { link in
            JoinSheet(link: link, onJoined: onSelectCircle)
        }
    }

    @ViewBuilder private var content: some View {
        if model.circles.isEmpty && model.hasLoadedCircles {
            ContentUnavailableView {
                Label("Noch keine Leuchttürme", systemImage: "person.3")
            } description: {
                Text("Gründe einen Leuchtturm für deine Familie oder Freunde, oder tritt über eine Einladung bei.")
            } actions: {
                Button("Leuchtturm gründen") { sheet = .createCircle }
                    .buttonStyle(.glassProminent)
                Button("Einladung einfügen") { sheet = .join }
                    .buttonStyle(.glass)
            }
        } else if let details, let circle {
            List {
                if !details.hasKey {
                    Label("Warte auf den Schlüssel vom Besitzer. Er wird übertragen, sobald der Besitzer die App öffnet.", systemImage: "key")
                        .font(.callout)
                }
                if let end = details.expiresAt {
                    Label("Leuchtturm auf Zeit · endet \(end.formatted(.relative(presentation: .named)))", systemImage: "hourglass")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(sorted(details.members)) { member in
                        Button {
                            onFocus(member)
                            path.append(.member(member.id))
                        } label: {
                            PersonRow(member: member)
                        }
                        .tint(.primary)
                    }
                }
                Section {
                    NavigationLink(value: DrawerRoute.week) {
                        Label("Wochenrückblick und Bestenliste", systemImage: "trophy")
                    }
                }
                NewsSection(details: details, onShowPlace: onShowPlace)
                PlacesSection(details: details, sheet: $sheet, onShowPlace: onShowPlace)
                Section {
                    Button("Einchecken: „Ich bin hier“", systemImage: "mappin.and.ellipse") {
                        Task { await model.send(.checkIn, in: circle.ref) }
                    }
                    .disabled(!details.hasKey || model.activeFog != nil)
                    if let fog = model.activeFog {
                        Button {
                            Task { await model.endFog() }
                        } label: {
                            Label {
                                Text("Nebel bis \(fog.until, format: .dateTime.hour().minute()) · beenden")
                            } icon: {
                                Image(systemName: "circle.dashed")
                            }
                        }
                    } else {
                        Button("Nebel: nur ungefähre Gegend teilen", systemImage: "circle.dashed") { sheet = .fog }
                    }
                    Button("Jemanden einladen", systemImage: "person.badge.plus") { sheet = .invite(circle.ref) }
                        .disabled(!details.hasKey)
                    NavigationLink(value: DrawerRoute.manage(circle.ref)) {
                        Label("Leuchtturm verwalten", systemImage: "gearshape")
                    }
                } footer: {
                    Label("Ende-zu-Ende-verschlüsselt", systemImage: "lock.fill")
                        .font(.caption)
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// You first, then everyone by name.
    private func sorted(_ members: [CircleMember]) -> [CircleMember] {
        members.sorted { a, b in
            if a.isMe != b.isMe { return a.isMe }
            return (a.name ?? "~").localizedCaseInsensitiveCompare(b.name ?? "~") == .orderedAscending
        }
    }

    @ViewBuilder private func presented(_ sheet: HomeSheet) -> some View {
        switch sheet {
        case .settings:
            SettingsView()
        case .createCircle:
            CreateCircleSheet(onCreated: onSelectCircle)
        case .join:
            JoinSheet(link: nil, onJoined: onSelectCircle)
        case let .invite(ref):
            InviteSheet(ref: ref, circleName: details?.name)
        case .fog:
            FogSheet()
        case let .addPlace(ref, suggestion):
            AddPlaceSheet(ref: ref, suggestion: suggestion)
        case .sos:
            SOSSheet()
        #if DEBUG
        case .simulation:
            SimulationView { receivedInvite = $0 }
        #endif
        }
    }

    private func showReceivedInvite() {
        if let link = receivedInvite {
            model.pendingInvite = link
            receivedInvite = nil
        }
    }
}

private struct PersonRow: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember

    var body: some View {
        HStack(spacing: 14) {
            Avatar(name: member.name, id: member.id, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(member.name ?? "Unbekannt")
                        .font(.headline)
                    if member.isMe {
                        Text("Du").font(.caption).foregroundStyle(.secondary)
                    }
                    if member.isOwner {
                        Image(systemName: "crown.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Besitzer")
                    }
                    if model.verifiedDevices.contains(member.id) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Sicherheitscode überprüft")
                    }
                }
                Text(LocationStatus.text(for: member, model: model))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let battery = member.location?.battery {
                BatteryBadge(level: battery, isCharging: member.location?.isCharging ?? false)
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// "vor 3 Minuten · 1,2 km", or why there is no position.
enum LocationStatus {
    @MainActor
    static func text(for member: CircleMember, model: AppModel) -> String {
        if member.isMe {
            if !model.isSharingLocation { return String(localized: "Teilen pausiert") }
            if let fog = model.activeFog {
                return String(localized: "Nebel bis \(fog.until.formatted(.dateTime.hour().minute()))")
            }
            if model.tracker.isDenied { return String(localized: "Standortzugriff ist aus") }
            if model.tracker.location == nil { return String(localized: "Suche Standort …") }
            return model.tracker.isAlwaysAllowed || model.isSimulation ? String(localized: "Wird geteilt") : String(localized: "Nur solange die App läuft")
        }
        if member.isPending { return String(localized: "Wartet auf Bestätigung") }
        guard let location = member.location else { return String(localized: "Teilt noch keinen Standort") }
        let ago = location.timestamp.timeIntervalSinceNow > -60
            ? String(localized: "Gerade eben")
            : location.timestamp.formatted(.relative(presentation: .named))
        guard let distance = distance(to: location, from: model.tracker.location) else { return ago }
        if location.fogRadius != nil { return String(localized: "\(ago) · im Nebel") }
        if let speed = location.speed, speed >= 2 {
            return String(localized: "Fährt · \(Theme.speed(speed)) · \(distance)")
        }
        return "\(ago) · \(distance)"
    }

    static func distance(to location: SharedLocation, from me: CLLocation?) -> String? {
        guard let me else { return nil }
        let meters = me.distance(from: location.clLocation)
        return Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// One person, opened from the drawer or a pin.
struct MemberDetailView: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember
    let ref: CircleRef?

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Avatar(name: member.name, id: member.id, size: 56)
                    Text(LocationStatus.text(for: member, model: model))
                        .font(.headline)
                }
            }
            .listRowBackground(Color.clear)

            if !member.isMe, !member.isPending, let ref {
                ReactionPicker(member: member, ref: ref)
            }

            if !member.isMe, !member.isPending, let ref {
                ArrivalWatchSection(member: member, circleID: ref.circleID)
            }

            if !member.isPending {
                Section {
                    NavigationLink(value: DrawerRoute.history(member.id)) {
                        Label("Verlauf", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                }
            }

            if let location = member.location, let radius = location.fogRadius, !member.isMe {
                Section {
                    Label("Teilt gerade nur eine ungefähre Gegend (ca. \(radius * 2 / 1000) km).", systemImage: "circle.dashed")
                }
            } else if let location = member.location, !member.isMe {
                Section {
                    LabeledContent("Aktualisiert") {
                        Text(location.timestamp, format: .dateTime.hour().minute())
                    }
                    if let distance = LocationStatus.distance(to: location, from: model.tracker.location) {
                        LabeledContent("Entfernung", value: distance)
                    }
                    LabeledContent("Genauigkeit", value: "± \(Int(location.accuracy.rounded())) m")
                    if let battery = location.battery {
                        LabeledContent("Akku") {
                            BatteryBadge(level: battery, isCharging: location.isCharging)
                        }
                    }
                    Button("In Apple Karten öffnen", systemImage: "arrow.triangle.turn.up.right.diamond") {
                        let item = MKMapItem(location: location.clLocation, address: nil)
                        item.name = member.name
                        item.openInMaps()
                    }
                } footer: {
                    Text("Apple Karten bekommt dabei diesen Ort. In Leuchtturm selbst sieht Apple die Standorte nicht.")
                }
            }

            Section {
                LabeledContent("Sicherheitscode") {
                    Text(member.safetyCode).font(.body.monospaced())
                }
                if !member.isMe {
                    if model.verifiedDevices.contains(member.id) {
                        Label("Persönlich überprüft", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.accentColor)
                        Button("Markierung entfernen", role: .destructive) { model.setVerified(member.id, false) }
                    } else {
                        Button("Stimmt überein: als überprüft markieren", systemImage: "checkmark.seal") {
                            model.setVerified(member.id, true)
                        }
                    }
                }
            } footer: {
                Text("Vergleicht den Code persönlich mit dem Gerät der Person. Stimmt er überein, kann niemand unbemerkt einen fremden Schlüssel unterschieben. Installiert jemand die App neu, bekommt er einen neuen Code und muss neu überprüft werden.")
            }
        }
        .navigationTitle(member.name ?? "Mitglied")
        .navigationBarTitleDisplayMode(.inline)
    }
}
