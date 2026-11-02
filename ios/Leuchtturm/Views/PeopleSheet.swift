import CoreLocation
import LeuchtturmCore
import MapKit
import SwiftUI

enum DrawerRoute: Hashable {
    case member(String)
    case history(String)
    case ride(SharedRide)
    case manage(CircleRef)
}

/// The drawer at the bottom of the map: everyone in the circle, with how
/// long ago and how far away they were seen.
struct PeopleSheet: View {
    static let peek = PresentationDetent.height(190)

    @Environment(AppModel.self) private var model
    @Environment(\.memberColors) private var memberColors
    @Environment(\.memberProfiles) private var memberProfiles
    let details: CircleDetails?
    let circle: CircleSummary?
    @Binding var sheet: HomeSheet?
    @Binding var path: [DrawerRoute]
    let onFocus: (CircleMember) -> Void
    let onShowPlace: (SharedLocation) -> Void
    let onSelectCircle: (CircleRef) -> Void
    /// Pulled up beyond the small peek: the lists get their grey ground.
    var expanded = true
    /// An invite from the simulation, shown once its sheet has closed.
    @State private var receivedInvite: InviteLink?
    @State private var tab = DrawerTab.start

    var body: some View {
        @Bindable var bindable = model
        NavigationStack(path: $path) {
            content
                .navigationTitle(circle.map { model.title(of: $0) } ?? AppInfo.name)
                .navigationBarTitleDisplayMode(.inline)
                // The name is already on the map; the tabs are the header here.
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: DrawerRoute.self) { route in
                    destination(route)
                        // The same grey ground with white rows as the lists at the root.
                        .scrollContentBackground(.hidden)
                        .background(Color(.systemGroupedBackground))
                }
        }
        .errorAlert()
        .sheet(item: $sheet, onDismiss: showReceivedInvite) { sheet in
            presented(sheet)
                .environment(\.memberColors, memberColors)
                .environment(\.memberProfiles, memberProfiles)
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

    @ViewBuilder private func destination(_ route: DrawerRoute) -> some View {
        switch route {
        case let .member(id):
            if let member = details?.members.first(where: { $0.id == id }) {
                MemberDetailView(member: member, ref: circle?.ref)
            }
        case let .history(id):
            if let member = details?.members.first(where: { $0.id == id }), let ref = circle?.ref {
                HistoryView(member: member, ref: ref)
            }
        case let .ride(ride):
            TripView(ride: ride, members: details?.members ?? [])
        case let .manage(ref):
            CircleDetailView(ref: ref)
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
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                switch tab {
                case .people: peopleList(details, circle)
                case .chat: ChatView(details: details)
                case .places:
                    List { PlacesSection(details: details, sheet: $sheet, onShowPlace: onShowPlace) }
                        .contentMargins(.top, 4, for: .scrollContent)
                case .week: WeekTab(details: details)
                }
            }
            // Glass while small over the map; one solid ground once pulled up.
            .background {
                if expanded {
                    (tab == .chat ? Color(.systemBackground) : Color(.systemGroupedBackground))
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: expanded)
        } else {
            ProgressView("Lädt …")
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
                            PersonRow(member: member, details: details)
                        }
                        .tint(.primary)
                    }
                    if !details.isFriendship {
                        Button("Jemanden einladen", systemImage: "person.badge.plus") { sheet = .invite(circle.ref) }
                            .disabled(!details.hasKey)
                    }
                }
                if let journey = model.journey, journey.circleID == details.id {
                    Section { JourneyBanner(journey: journey) }
                }
                NewsSection(details: details, onShowPlace: onShowPlace)
                ActionSections(details: details, sheet: $sheet)
                MemoryCard()
                Section {
                    if details.isFriendship {
                        Button("Freunde verwalten", systemImage: "person.2") { sheet = .friends }
                    } else {
                        NavigationLink(value: DrawerRoute.manage(circle.ref)) {
                            Label("Leuchtturm verwalten", systemImage: "gearshape")
                        }
                    }
                    Button { sheet = .features } label: {
                        Label { Text("Funktionen").foregroundStyle(.primary) } icon: { Image(systemName: "sparkles") }
                    }
                } footer: {
                    Label("Ende-zu-Ende-verschlüsselt", systemImage: "lock.fill")
                        .font(.caption)
                }
            }
            .contentMargins(.top, 0, for: .scrollContent)
    }

    /// Everyone by name, you last: the small drawer shows the others first.
    private func sorted(_ members: [CircleMember]) -> [CircleMember] {
        members.sorted { a, b in
            if a.isMe != b.isMe { return b.isMe }
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

/// One person: where they are or what they do, how fresh, battery.
private struct PersonRow: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember
    let details: CircleDetails

    var body: some View {
        // Keeps "vor 5 Min." current while nothing else changes.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            row(PersonStatus.of(member, places: details.places, notes: details.notes, model: model, now: context.date))
        }
    }

    private func row(_ status: PersonStatus) -> some View {
        let profileStatus = (member.isMe ? model.myProfile : member.profile)?.status(at: .now)
        return HStack(spacing: 14) {
            Avatar(name: member.name, id: member.id, size: 48)
                .overlay(alignment: .bottomTrailing) {
                    if let emoji = profileStatus?.emoji {
                        Text(emoji)
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                            .background(Color(.secondarySystemGroupedBackground), in: .circle)
                            .offset(x: 4, y: 4)
                    }
                }
                .saturation(status.isStale ? 0.3 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name ?? "Unbekannt")
                        .font(.headline)
                        .lineLimit(1)
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
                if let headline = status.headline {
                    Label {
                        Text(headline)
                    } icon: {
                        Image(systemName: status.symbol ?? "mappin")
                            .foregroundStyle(status.isDriving ? Theme.Tone.sky : Color.accentColor)
                    }
                    .labelStyle(RowLabelStyle())
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                } else if let profileStatus, let text = profileStatus.text {
                    Text(text)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                Text(status.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                WeatherBadge(location: member.isMe ? model.tracker.location.flatMap { SharedLocation($0) } : member.location)
                if let battery = member.location?.battery {
                    BatteryBadge(level: battery, isCharging: member.location?.isCharging ?? false)
                }
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Symbol and text close together, as in a subtitle.
struct RowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// One person, opened from the drawer or a pin: first where they are and
/// what you can do, then the rest.
struct MemberDetailView: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember
    let ref: CircleRef?
    @State private var editing = false
    @State private var asked = false
    @State private var asking = false
    @State private var showsHistory = false

    /// One's own page shows the profile as edited, not the copy from iCloud.
    private var shown: CircleMember {
        guard member.isMe else { return member }
        var me = member
        me.profile = model.myProfile
        return me
    }

    private var isOther: Bool { !member.isMe && !member.isPending }

    var body: some View {
        List {
            Section {
                ProfileHeader(member: shown)
                    .listRowSeparator(.hidden)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))

            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LocationCard(member: member, status: PersonStatus.of(member, model: model, now: context.date))
                }
            }

            Section {
                actions
            } footer: {
                if isOther {
                    Text("„Wo bist du?“ weckt das iPhone von \(member.name ?? String(localized: "der Person")) für einen frischen Standort. „Route“ gibt den Ort an Apple Karten.")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if isOther, let ref {
                ReactionPicker(member: member, ref: ref)
                ArrivalWatchSection(member: member, circleID: ref.circleID)
            }

            if !member.isPending, member.isMe || member.profile?.driving != nil {
                DriveStatsSection(member: member)
            }

            if isOther, let ref {
                RoleSection(member: member, ref: ref)
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
                MoreFooter("Vergleicht den Code, wenn ihr euch seht.", more: "Vergleicht den Code persönlich mit dem Gerät der Person. Stimmt er überein, kann niemand unbemerkt einen fremden Schlüssel unterschieben. Installiert jemand die App neu, bekommt er einen neuen Code und muss neu überprüft werden.")
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(member.name ?? "Mitglied")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsHistory) {
            if let ref {
                HistoryView(member: member, ref: ref)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
            }
        }
        .sheet(isPresented: $editing) { ProfileEditor() }
        .sensoryFeedback(.success, trigger: asked) { _, new in new }
    }

    /// The main things to do, side by side.
    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            if member.isMe {
                QuickAction("Profil", systemImage: "paintbrush.fill") { editing = true }
            }
            if isOther, let ref {
                QuickAction(asked ? "Gefragt" : "Wo bist du?",
                            systemImage: asked ? "checkmark" : "location.magnifyingglass", working: asking) {
                    let (id, ref) = (member.id, ref)
                    asking = true
                    Task {
                        asked = await model.send(.locationRequest, to: id, in: ref)
                        asking = false
                    }
                }
                .disabled(asked)
                if let location = member.location, location.fogRadius == nil {
                    QuickAction("Route", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                        let item = MKMapItem(location: location.clLocation, address: nil)
                        item.name = member.name
                        item.openInMaps()
                    }
                }
            }
            if !member.isPending, ref != nil {
                QuickAction("Verlauf", systemImage: "clock.arrow.circlepath") { showsHistory = true }
            }
        }
    }
}

/// Where the person is, how fresh, battery and weather.
private struct LocationCard: View {
    @Environment(AppModel.self) private var model
    let member: CircleMember
    let status: PersonStatus

    private var location: SharedLocation? {
        member.isMe ? model.tracker.location.flatMap { SharedLocation($0) } : member.location
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconSquare(status.symbol ?? "location.fill", tone: status.isDriving ? Theme.Tone.sky : Theme.Tone.moss)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.headline ?? String(localized: "Standort"))
                        .font(.headline)
                    Text(status.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            if let location, !member.isPending {
                HStack(spacing: 14) {
                    if let battery = location.battery {
                        BatteryBadge(level: battery, isCharging: location.isCharging)
                    }
                    if let radius = location.fogRadius {
                        Label("ca. \(radius * 2 / 1000) km Umkreis", systemImage: "circle.dashed")
                    } else {
                        Label("± \(Int(location.accuracy.rounded())) m", systemImage: "scope")
                    }
                    if model.showsWeather {
                        WeatherBadge(location: location, withAttribution: true)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(RowLabelStyle())
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
