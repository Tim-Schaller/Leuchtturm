import CoreLocation
import LeuchtturmCore
import MapKit
import SwiftUI

enum DrawerRoute: Hashable {
    case member(String)
    case history(String)
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
    @State private var tab = DrawerTab.people

    var body: some View {
        @Bindable var bindable = model
        NavigationStack(path: $path) {
            content
                .navigationTitle(circle.map { model.title(of: $0) } ?? AppInfo.name)
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
        .alert("Apple TV verbinden?", isPresented: Binding(get: { model.pendingTV != nil }, set: { if !$0 { model.pendingTV = nil } }),
               presenting: model.pendingTV) { tv in
            Button("Verbinden") { model.pairTV(tv) }
            Button("Abbrechen", role: .cancel) { model.pendingTV = nil }
        } message: { _ in
            Text("Das Apple TV zeigt dann die Karte des Leuchtturms, den du gerade offen hast, mit dir und allen anderen. Es braucht dieselbe iCloud wie du und bekommt keine Schlüssel deiner Leuchttürme, nur eine verschlüsselte Kopie der Karte. Trennen kannst du es in den Einstellungen.")
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
            VStack(spacing: 0) {
                DrawerTabBar(selection: $tab)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                switch tab {
                case .people: peopleList(details, circle)
                case .chat: ChatView(details: details)
                case .places: List { PlacesSection(details: details, sheet: $sheet, onShowPlace: onShowPlace) }
                case .trips: WeekView(details: details, mode: .trips)
                case .ranking: WeekView(details: details, mode: .ranking)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The start tab: people, news and what you can do.
    private func peopleList(_ details: CircleDetails, _ circle: CircleSummary) -> some View {
            List {
                if !details.hasKey {
                    Label("Warte auf den Schlüssel vom Besitzer. Er wird übertragen, sobald der Besitzer die App öffnet.", systemImage: "key")
                        .font(.callout)
                }
                if details.canTakeOver {
                    TakeOverSection(details: details, onTakenOver: onSelectCircle)
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
                    if !details.isFriendship {
                        Button("Jemanden einladen", systemImage: "person.badge.plus") { sheet = .invite(circle.ref) }
                            .disabled(!details.hasKey)
                    }
                }
                MemoryCard()
                if let journey = model.journey, journey.circleID == details.id {
                    Section { JourneyBanner(journey: journey) }
                }
                ActionSections(details: details, sheet: $sheet)
                NewsSection(details: details, onShowPlace: onShowPlace)
                Section {
                    if details.isFriendship {
                        Button("Freunde verwalten", systemImage: "person.2") { sheet = .friends }
                    } else {
                        NavigationLink(value: DrawerRoute.manage(circle.ref)) {
                            Label("Leuchtturm verwalten", systemImage: "gearshape")
                        }
                    }
                    Button("Funktionen", systemImage: "sparkles") { sheet = .features }
                } footer: {
                    Label("Ende-zu-Ende-verschlüsselt", systemImage: "lock.fill")
                        .font(.caption)
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
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
        case let .journey(ref, walkHome):
            JourneySheet(ref: ref, walkHome: walkHome)
        case let .meetingPoint(ref):
            MeetingPointSheet(ref: ref)
        case .friends:
            FriendsView { friend in
                if let ref = friend.friendship?.ref ?? friend.circles.first.flatMap({ first in model.circles.first { $0.id == first.id }?.ref }) {
                    onSelectCircle(ref)
                    path = [.member(friend.id)]
                }
            }
        case let .addPlace(ref, suggestion):
            AddPlaceSheet(ref: ref, suggestion: suggestion)
        case .sos:
            SOSSheet()
        case .liveLink:
            LiveLinkSheet()
        case .features:
            FeaturesSheet()
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
                    RoleBadge(member: member)
                    if model.verifiedDevices.contains(member.id) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Sicherheitscode überprüft")
                    }
                }
                if let status = (member.isMe ? model.myProfile : member.profile)?.status(at: Date()) {
                    Text([status.emoji, status.text].compactMap { $0 }.joined(separator: " "))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                Text(LocationStatus.text(for: member, model: model))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                WeatherBadge(location: member.isMe ? model.tracker.location.flatMap { SharedLocation($0) } : member.location)
            if let battery = member.location?.battery {
                BatteryBadge(level: battery, isCharging: member.location?.isCharging ?? false)
            }
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
        if let journey = activeJourney(of: member.id, in: model.latestCircle(model.circleOf(member.id) ?? "")?.notes ?? []),
           let deadline = journey.deadline {
            let time = deadline.formatted(date: .omitted, time: .shortened)
            return journey.kind == .walkHome
                ? String(localized: "Heimweg zu \(journey.text) · bis \(time)")
                : String(localized: "Auf dem Weg zu \(journey.text) · ca. \(time)")
        }
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
    @State private var editing = false
    @State private var asked = false

    /// One's own page shows the profile as edited, not the copy from iCloud.
    private var shown: CircleMember {
        guard member.isMe else { return member }
        var me = member
        me.profile = model.myProfile
        return me
    }

    var body: some View {
        List {
            Section {
                ProfileHeader(member: shown, subtitle: LocationStatus.text(for: member, model: model))
                    .listRowSeparator(.hidden)
                if model.showsWeather {
                    WeatherBadge(location: member.isMe ? model.tracker.location.flatMap { SharedLocation($0) } : member.location,
                                 withAttribution: true)
                        .padding(.horizontal)
                        .listRowSeparator(.hidden)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))

            if member.isMe {
                Section {
                    Button("Profil gestalten", systemImage: "paintbrush") { editing = true }
                }
            }

            if !member.isMe, !member.isPending, let ref {
                Section {
                    Button(asked ? "Gefragt, Standort kommt gleich" : "Wo bist du?", systemImage: "location.magnifyingglass") {
                        let (id, ref) = (member.id, ref)
                        Task { if await model.send(.locationRequest, to: id, in: ref) { asked = true } }
                    }
                    .disabled(asked)
                } footer: {
                    Text("Weckt das iPhone von \(member.name ?? String(localized: "der Person")) für einen frischen Standort. Die Person sieht, dass du gefragt hast.")
                }
            }

            if !member.isPending {
                DriveStatsSection(member: member)
            }

            if !member.isMe, !member.isPending, let ref {
                ReactionPicker(member: member, ref: ref)
            }

            if !member.isMe, !member.isPending, let ref {
                ArrivalWatchSection(member: member, circleID: ref.circleID)
                RoleSection(member: member, ref: ref)
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
        .sheet(isPresented: $editing) { ProfileEditor() }
    }
}
