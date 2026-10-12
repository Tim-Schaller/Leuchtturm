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
    case journey(CircleRef, walkHome: Bool)
    case friends
    case meetingPoint(CircleRef)
    case addPlace(CircleRef, PlaceSuggestion?)
    case sos
    case liveLink
    case features
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
        case let .journey(ref, walkHome): "journey-\(ref.circleID)-\(walkHome)"
        case .friends: "friends"
        case let .meetingPoint(ref): "meet-\(ref.circleID)"
        case let .addPlace(ref, suggestion): "place-\(ref.circleID)-\(suggestion?.id ?? "")"
        case .sos: "sos"
        case .liveLink: "live"
        case .features: "features"
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
    /// Where the map and the drawer are on screen, for framing. Not state
    /// that redraws: it changes on every frame while the drawer moves.
    @State private var layout = MapLayout()
    @AppStorage("featuresIntroShown") private var featuresIntroShown = false

    private var selected: CircleSummary? {
        model.circles.first { $0.id == selectedCircleID } ?? model.leuchttuerme.first ?? model.circles.first
    }

    private var myID: String { model.client?.deviceID ?? "" }

    private var memberColors: [String: Color] { Theme.colors(for: details?.members.map(\.id) ?? []) }

    private var memberProfiles: [String: Profile] {
        var out = Dictionary((details?.members ?? []).compactMap { m in m.profile.map { (m.id, $0) } }, uniquingKeysWith: { a, _ in a })
        if let me = model.client?.deviceID { out[me] = model.myProfile }
        return out
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isRegular: Bool { sizeClass == .regular }

    var body: some View {
        Group {
            if isRegular {
                // iPad: people in a sidebar next to the map.
                NavigationSplitView {
                    drawer.navigationSplitViewColumnWidth(min: 340, ideal: 400, max: 480)
                } detail: {
                    mapView
                }
            } else {
                mapView.sheet(isPresented: .constant(true)) {
                    drawer
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { layout.drawerTop = $0 }
                        .presentationDetents([PeopleSheet.peek, .medium, .large], selection: $detent)
                        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                        .presentationDragIndicator(.visible)
                        .interactiveDismissDisabled()
                }
            }
        }
        .onChange(of: model.tracker.location == nil) { frameIfSomeoneNew() }
        .onChange(of: model.hasLoadedCircles && model.circles.isEmpty, initial: true) { _, empty in
            detent = empty ? .medium : PeopleSheet.peek
        }
        // A friend code opened as a link goes to the friends menu.
        .onChange(of: model.pendingFriendCode, initial: true) { _, code in
            if code != nil { sheet = .friends }
        }
        .task(id: model.hasLoadedCircles && !model.leuchttuerme.isEmpty) {
            guard model.hasLoadedCircles, !model.leuchttuerme.isEmpty, !featuresIntroShown else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard sheet == nil, !Task.isCancelled else { return }
            featuresIntroShown = true
            sheet = .features
        }
        .environment(\.memberColors, memberColors)
        .environment(\.memberProfiles, memberProfiles)
        .task(id: model.externalChanges) { await model.refresh() }
        .task(id: "\(selected?.id ?? "")|\(model.externalChanges)") { await follow(selected?.ref) }
    }

    private var drawer: some View {
        PeopleSheet(
            details: details, circle: selected, sheet: $sheet, path: $drawerPath,
            onFocus: { focus($0) }, onShowPlace: showPlace, onSelectCircle: { selectedCircleID = $0.circleID }
        )
    }

    private var mapView: some View {
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layout.map = $0 }
        // MapKit reports the part it fits cameras into; its shape tells how
        // tall that part is.
        .onMapCameraChange(frequency: .onEnd) { context in
            if context.rect.width > 0 { layout.safeAspect = context.rect.height / context.rect.width }
        }
        .safeAreaPadding(.bottom, isRegular ? 0 : 230)
        // Only the top row counts as covered: the button column floats, so
        // MapKit does not squeeze everyone below it.
        .overlay(alignment: .topTrailing) { buttonColumn }
        .safeAreaInset(edge: .top) {
            topRow.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { layout.safeTop = $0 }
        }
    }

    /// Keeps the selected circle current: polls iCloud every 10 seconds
    /// (pushes may come later), the simulation every few seconds; asks
    /// devices with an old position for a fresh one.
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
                await model.askForFreshPositions(loaded)
            }
            try? await Task.sleep(for: .seconds(model.isSimulation ? 4 : 10))
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
        show(placedPoints, atLeast: 1500)
        framedCount = placedPoints.count
    }

    /// Flies to the person; with `showDetails` the drawer opens halfway.
    private func focus(_ member: CircleMember, showDetails: Bool = true) {
        focusedID = member.id
        if showDetails && !isRegular && detent != .large { detent = .medium }
        let coordinate = member.isMe ? model.tracker.location?.coordinate : member.location?.coordinate
        guard let coordinate else { return }
        show([coordinate], atLeast: 900, drawer: showDetails ? .medium : nil)
    }

    /// Puts `points` in the middle of the part of the map that the buttons
    /// on top and the drawer below leave free, with room for the pins above
    /// their points. `atLeast` meters stay in view.
    /// `drawer` is where the drawer is about to be, if it is moving.
    private func show(_ points: [CLLocationCoordinate2D], atLeast meters: Double, drawer: PresentationDetent? = nil) {
        guard let first = points.first else { return }
        let mapPoints = points.map(MKMapPoint.init)
        let minX = mapPoints.map(\.x).min() ?? 0, maxX = mapPoints.map(\.x).max() ?? 0
        let minY = mapPoints.map(\.y).min() ?? 0, maxY = mapPoints.map(\.y).max() ?? 0
        let perMeter = MKMapPointsPerMeterAtLatitude(first.latitude)
        // MapKit fits the camera rect into the map's safe area (below the
        // top row, above the drawer's usual height).
        let safe = layout.safeRect
        guard safe.width > 100, safe.height > 100 else {
            let side = max(maxX - minX, maxY - minY, perMeter * meters) * 1.6
            let size = MKMapSize(width: side, height: side)
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) {
                camera = .rect(MKMapRect(origin: MKMapPoint(x: (minX + maxX - size.width) / 2, y: (minY + maxY - size.height) / 2), size: size))
            }
            return
        }
        // Where the pins may go: room above for the pin, and above the
        // drawer where it really is (or is about to be).
        // Pins are about 50 points wide; the button column covers the right edge.
        let pinHeight: CGFloat = 60, margin: CGFloat = 28, left: CGFloat = 52, right: CGFloat = 80
        var bottom = safe.maxY
        if !isRegular {
            let drawerTop = switch drawer {
            case .medium?: layout.map.maxY * 0.5
            case PeopleSheet.peek?: safe.maxY
            default: layout.drawerTop ?? safe.maxY
            }
            bottom = min(bottom, drawerTop)
        }
        let top = pinHeight + margin
        let free = CGRect(x: left, y: top, width: safe.width - left - right, height: max(bottom - safe.minY - margin - top, 60))
        let scale = max((maxX - minX) / free.width, (maxY - minY) / free.height, perMeter * meters / min(free.width, free.height))
        let rect = MKMapRect(
            x: (minX + maxX) / 2 - free.midX * scale,
            y: (minY + maxY) / 2 - free.midY * scale,
            width: safe.width * scale,
            height: safe.height * scale
        )
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.6)) { camera = .rect(rect) }
    }

    private func showPlace(_ place: SharedLocation) {
        focusedID = nil
        if !isRegular { detent = PeopleSheet.peek }
        show([place.coordinate], atLeast: 600, drawer: PeopleSheet.peek)
    }

    /// From a pin: focus and show the person in the drawer.
    private func open(_ member: CircleMember) {
        focus(member)
        drawerPath = [.member(member.id)]
    }

    // MARK: Controls on the map

    private var topRow: some View {
        HStack(spacing: 10) {
            MapButton("Einstellungen", systemImage: "gearshape") { sheet = .settings }
            circleMenu
            Spacer(minLength: 0)
            FriendsButton(requests: model.incomingFriendRequests.count) { sheet = .friends }
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var buttonColumn: some View {
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
        .padding(.top, 8)
        .padding(.trailing)
    }

    private var circleMenu: some View {
        Menu {
            Picker("Leuchtturm", selection: Binding(get: { selected?.id ?? "" }, set: { selectedCircleID = $0 })) {
                ForEach(model.leuchttuerme) { circle in
                    Text(model.title(of: circle)).tag(circle.id)
                }
            }
            if !model.friendships.isEmpty {
                Section("Freunde") {
                    Picker("Freund", selection: Binding(get: { selected?.id ?? "" }, set: { selectedCircleID = $0 })) {
                        ForEach(model.friendships) { circle in
                            Label(model.title(of: circle), systemImage: "person").tag(circle.id)
                        }
                    }
                }
            }
            Divider()
            if let selected, !selected.isFriendship, details?.hasKey == true {
                Button("Jemanden einladen", systemImage: "person.badge.plus") { sheet = .invite(selected.ref) }
            }
            Button("Leuchtturm gründen", systemImage: "plus.circle") { sheet = .createCircle }
            Button("Einladung einfügen", systemImage: "link") { sheet = .join }
        } label: {
            HStack(spacing: 6) {
                Text(selected.map { model.title(of: $0) } ?? AppInfo.name)
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

/// The friends menu, with its name on it and the number of open requests.
private struct FriendsButton: View {
    let requests: Int
    let action: () -> Void
    @ScaledMetric(relativeTo: .title3) private var height = 30

    var body: some View {
        Button(action: action) {
            Label("Freunde", systemImage: "person.2.fill")
                .font(.headline)
                .labelStyle(.titleAndIcon)
                .frame(height: height)
                .padding(.horizontal, 2)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .overlay(alignment: .topTrailing) {
            if requests > 0 {
                Text(requests, format: .number)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: .capsule)
                    .offset(x: 4, y: -4)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(requests > 0 ? "Freunde, \(requests) offene Anfragen" : "Freunde")
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

/// Where the map and the drawer are on screen (global coordinates).
final class MapLayout {
    var map: CGRect = .zero
    /// The map's safe area starts below the top row ...
    var safeTop: CGFloat?
    /// ... and is this tall per point of width (from MapKit).
    var safeAspect: CGFloat?
    var drawerTop: CGFloat?

    /// The part of the screen MapKit fits a camera rect into.
    var safeRect: CGRect {
        let top = safeTop ?? map.minY + 120
        let height = safeAspect.map { map.width * $0 } ?? (map.maxY - 264 - top)
        return CGRect(x: map.minX, y: top, width: map.width, height: height)
    }
}
