import LeuchtturmCore
import MapKit
import SwiftUI

/// Sheets presented from the home screen. They open from the people
/// drawer, because the drawer itself is already a sheet.
enum HomeSheet: Identifiable {
    case settings
    case createCircle
    case join
    case invite(CircleRef)
    case fog
    case addPlace(CircleRef, PlaceSuggestion?)
    case sos
    #if DEBUG
    case simulation
    #endif

    var id: String {
        switch self {
        case .settings: "settings"
        case .createCircle: "create"
        case .join: "join"
        case let .invite(ref): "invite-\(ref.circleID)"
        case .fog: "fog"
        case let .addPlace(ref, suggestion): "place-\(ref.circleID)-\(suggestion?.id ?? "")"
        case .sos: "sos"
        #if DEBUG
        case .simulation: "simulation"
        #endif
        }
    }
}

/// Home screen: a full-screen map with everyone in the
/// selected circle, a circle switcher on top and the people drawer below.
struct MapHomeView: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("selectedCircle") private var selectedCircleID = ""
    @AppStorage("mapSatellite") private var satellite = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var details: CircleDetails?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    /// How many people were on the map when it last framed everyone. It
    /// frames again only when someone new shows up, otherwise the camera
    /// stays where the user puts it.
    @State private var framedCount = 0
    @State private var focusedID: String?
    @State private var sheet: HomeSheet?
    @State private var drawerPath: [DrawerRoute] = []
    @State private var detent: PresentationDetent = PeopleSheet.peek

    private var selected: CircleSummary? {
        model.circles.first { $0.id == selectedCircleID } ?? model.circles.first
    }

    private var myID: String { model.client?.deviceID ?? "" }

    private var memberColors: [String: Color] { Theme.colors(for: details?.members.map(\.id) ?? []) }

    private var memberProfiles: [String: Profile] {
        var out = Dictionary((details?.members ?? []).compactMap { m in m.profile.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        if let me = model.client?.deviceID { out[me] = model.myProfile }
        return out
    }

    var body: some View {
        Map(position: $camera) {
            ForEach(details?.places ?? []) { place in
                MapCircle(center: place.coordinate, radius: Double(place.radius))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                Annotation(place.name, coordinate: place.coordinate) {
                    PlaceBadge(emoji: place.emoji)
                }
            }
            // People in fog: only the approximate area.
            ForEach(details?.members ?? []) { member in
                if !member.isMe, let location = member.location, let radius = location.fogRadius {
                    let color = memberColors[member.id] ?? Theme.color(for: member.id)
                    MapCircle(center: location.coordinate, radius: Double(radius))
                        .foregroundStyle(color.opacity(0.15))
                        .stroke(color.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            if let fog = model.activeFog,
               let mine = model.tracker.location.flatMap({ SharedLocation($0)?.inFog(radius: fog.radius) }) {
                MapCircle(center: mine.coordinate, radius: Double(fog.radius))
                    .foregroundStyle(Color.accentColor.opacity(0.12))
                    .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            ForEach(details?.members ?? []) { member in
                if !member.isMe, let location = member.location {
                    Annotation(member.name ?? "Unbekannt", coordinate: location.coordinate, anchor: .bottom) {
                        Button { open(member) } label: {
                            MemberPin(
                                name: member.name, id: member.id, isFocused: focusedID == member.id,
                                isStale: location.timestamp.timeIntervalSinceNow < -3600
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(member.name ?? "Unbekannt")
                    }
                    .annotationTitles(.hidden)
                }
            }
            if let me = model.tracker.location {
                Annotation("Du", coordinate: me.coordinate, anchor: .bottom) {
                    MemberPin(name: model.displayName, id: myID, isFocused: focusedID == myID)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(satellite
            ? .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll)
            : .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass() }
        .safeAreaPadding(.bottom, 230)
        .safeAreaInset(edge: .top) { controls }
        .sheet(isPresented: .constant(true)) {
            PeopleSheet(
                details: details, circle: selected, sheet: $sheet, path: $drawerPath,
                onFocus: { focus($0) }, onShowPlace: showPlace, onSelectCircle: { selectedCircleID = $0.circleID }
            )
            .presentationDetents([PeopleSheet.peek, .medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .onChange(of: model.tracker.location == nil) { frameIfSomeoneNew() }
        .onChange(of: model.hasLoadedCircles && model.circles.isEmpty, initial: true) { _, empty in
            detent = empty ? .medium : PeopleSheet.peek
        }
        .environment(\.memberColors, memberColors)
        .environment(\.memberProfiles, memberProfiles)
        .task(id: model.externalChanges) { await model.refresh() }
        .task(id: "\(selected?.id ?? "")|\(model.externalChanges)") { await follow(selected?.ref) }
    }

    /// Keeps the selected circle current: polls iCloud every 30 seconds
    /// (push updates come later), the simulation every few seconds.
    private func follow(_ ref: CircleRef?) async {
        guard let ref else {
            details = nil
            return
        }
        if details?.id != ref.circleID {
            details = nil
            focusedID = nil
            drawerPath = []
            framedCount = 0
        }
        while !Task.isCancelled {
            if let loaded = await model.mapDetails(for: ref) {
                details = loaded
                frameIfSomeoneNew()
            }
            try? await Task.sleep(for: .seconds(model.isSimulation ? 4 : 30))
        }
    }

    private var placedPoints: [CLLocationCoordinate2D] {
        var points = (details?.members ?? []).filter { !$0.isMe }.compactMap { $0.location?.coordinate }
        if let me = model.tracker.location?.coordinate { points.append(me) }
        return points
    }

    private func frameIfSomeoneNew() {
        if placedPoints.count > framedCount { frameEveryone() }
    }

    /// Everyone with a position in view, but never closer than about 1.5 km.
    private func frameEveryone() {
        let points = placedPoints
        guard let first = points.first else { return }
        var (south, north, west, east) = (first.latitude, first.latitude, first.longitude, first.longitude)
        for point in points {
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            west = min(west, point.longitude)
            east = max(east, point.longitude)
        }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.015, (north - south) * 1.6), longitudeDelta: max(0.015, (east - west) * 1.6))
        )
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) { camera = .region(region) }
        framedCount = points.count
    }

    /// Flies to the person; with `showDetails` the drawer opens halfway.
    private func focus(_ member: CircleMember, showDetails: Bool = true) {
        focusedID = member.id
        if showDetails { detent = .medium }
        let coordinate = member.isMe ? model.tracker.location?.coordinate : member.location?.coordinate
        guard let coordinate else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 900, longitudinalMeters: 900))
        }
    }

    private func showPlace(_ place: SharedLocation) {
        focusedID = nil
        detent = PeopleSheet.peek
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))
        }
    }

    /// From a pin: focus and show the person in the drawer.
    private func open(_ member: CircleMember) {
        focus(member)
        drawerPath = [.member(member.id)]
    }

    // MARK: Controls on the map

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 12) {
            HStack {
                MapButton("Einstellungen", systemImage: "gearshape") { sheet = .settings }
                Spacer()
                circleMenu
                Spacer()
                MapButton("Jemanden einladen", systemImage: "person.badge.plus") {
                    if let ref = selected?.ref { sheet = .invite(ref) }
                }
                .disabled(details?.hasKey != true)
            }
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    #if DEBUG
                    if model.isSimulation {
                        MapButton("Simulation", systemImage: "testtube.2", tint: .orange) { sheet = .simulation }
                    }
                    #endif
                    MapButton("SOS", systemImage: "sos", tint: .red) { sheet = .sos }
                    MapButton("Mein Standort", systemImage: "location.fill") {
                        if let me = details?.members.first(where: \.isMe) { focus(me, showDetails: false) }
                    }
                    MapButton("Alle zeigen", systemImage: "person.2.fill") {
                        focusedID = nil
                        frameEveryone()
                    }
                    MapButton(satellite ? "Karte" : "Satellit", systemImage: satellite ? "map.fill" : "globe.europe.africa.fill") {
                        satellite.toggle()
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private var circleMenu: some View {
        Menu {
            Picker("Leuchtturm", selection: Binding(get: { selected?.id ?? "" }, set: { selectedCircleID = $0 })) {
                ForEach(model.circles) { circle in
                    Text(circle.name ?? "Unbekannter Leuchtturm").tag(circle.id)
                }
            }
            Divider()
            Button("Leuchtturm gründen", systemImage: "plus.circle") { sheet = .createCircle }
            Button("Einladung einfügen", systemImage: "link") { sheet = .join }
        } label: {
            HStack(spacing: 6) {
                Text(selected?.name ?? AppInfo.name)
                    .font(.headline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.bold())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .accessibilityLabel("Leuchtturm wählen")
    }
}

/// Round glass button floating on the map.
private struct MapButton: View {
    let label: String
    let systemImage: String
    var tint: Color?
    let action: () -> Void
    /// Grows with the text size setting.
    @ScaledMetric(relativeTo: .title3) private var size = 30

    init(_ label: String, systemImage: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(tint)
        .accessibilityLabel(label)
    }
}
