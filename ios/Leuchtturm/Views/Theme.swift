import LeuchtturmCore
import SwiftUI
import UIKit

/// The green, landscape look shared by all screens.
enum Theme {
    /// Member colors from nature, picked by device ID so everyone in a
    /// circle sees the same color for the same person.
    static let memberColors: [Color] = [
        Color(red: 0.31, green: 0.62, blue: 0.43), // moss
        Color(red: 0.16, green: 0.55, blue: 0.60), // lagoon
        Color(red: 0.95, green: 0.47, blue: 0.42), // coral
        Color(red: 0.91, green: 0.62, blue: 0.18), // sun
        Color(red: 0.36, green: 0.55, blue: 0.85), // sky
        Color(red: 0.58, green: 0.47, blue: 0.80), // heather
        Color(red: 0.62, green: 0.45, blue: 0.30), // earth
        Color(red: 0.80, green: 0.33, blue: 0.52), // berry
    ]

    static func color(for id: String) -> Color {
        memberColors[colorIndex(for: id)]
    }

    /// Distinct colors for everyone in a circle (as long as there are
    /// enough). Same member list, same colors on every device.
    static func colors(for ids: [String]) -> [String: Color] {
        var used = Set<Int>()
        var out: [String: Color] = [:]
        for id in ids.sorted() {
            var index = colorIndex(for: id)
            for _ in memberColors.indices where used.contains(index) {
                index = (index + 1) % memberColors.count
            }
            used.insert(index)
            out[id] = memberColors[index]
        }
        return out
    }

    private static func colorIndex(for id: String) -> Int {
        // djb2: stable across launches and devices, unlike `hashValue`.
        let hash = id.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        return Int(hash % UInt32(memberColors.count))
    }

    /// Soft mint at the top, deep forest at night.
    static let skyTop = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.06, green: 0.16, blue: 0.13, alpha: 1)
        : UIColor(red: 0.85, green: 0.95, blue: 0.93, alpha: 1)
    })
    static let skyBottom = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.09, green: 0.23, blue: 0.18, alpha: 1)
        : UIColor(red: 0.93, green: 0.98, blue: 0.94, alpha: 1)
    })
    /// "57 km/h" or "35 mph", depending on the region.
    static func speed(_ metersPerSecond: Double) -> String {
        let unit: UnitSpeed = Locale.current.measurementSystem == .metric ? .kilometersPerHour : .milesPerHour
        return Measurement(value: metersPerSecond, unit: UnitSpeed.metersPerSecond).converted(to: unit)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static var sky: LinearGradient {
        LinearGradient(colors: [skyTop, skyBottom], startPoint: .top, endPoint: .bottom)
    }

    /// The few colours for icons and tiles, from the same landscape as the
    /// member colours, so screens do not turn into a rainbow.
    enum Tone {
        static let moss = memberColors[0]
        static let lagoon = memberColors[1]
        static let coral = memberColors[2]
        static let sun = memberColors[3]
        static let sky = memberColors[4]
        static let heather = memberColors[5]
        static let stone = Color(red: 0.52, green: 0.56, blue: 0.55)
    }

    /// Corner radii: small icon squares, inner pieces, cards.
    enum Radius {
        static let icon: CGFloat = 10
        static let inner: CGFloat = 16
        static let card: CGFloat = 22
    }
}

/// A white symbol on a rounded square of one tone, like the icons in
/// Settings.
struct IconSquare: View {
    let symbol: String
    let tone: Color
    @ScaledMetric(relativeTo: .body) private var size = 30

    init(_ symbol: String, tone: Color) {
        self.symbol = symbol
        self.tone = tone
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tone.gradient, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// "Gerade eben", "vor 5 Min.", "vor 3 Std." that keeps itself current.
struct FreshnessText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.text(for: date, now: context.date))
        }
    }

    static func text(for date: Date, now: Date = .now) -> String {
        let age = now.timeIntervalSince(date)
        if age < 60 { return String(localized: "Gerade eben") }
        if age < 86400 {
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

extension EnvironmentValues {
    /// Colors of the people in the circle on screen, from `Theme.colors(for:)`.
    @Entry var memberColors: [String: Color] = [:]
}

/// A person as a colored circle with initials.
struct Avatar: View {
    @Environment(\.memberColors) private var memberColors
    @Environment(\.memberProfiles) private var memberProfiles
    let name: String?
    let id: String
    var size: CGFloat = 44
    /// Shown instead of the circle's copy, e.g. while editing one's own profile.
    var profile: Profile?
    /// A white edge, for pins on the map and the banner; lists go without.
    var ring = false

    var body: some View {
        let profile = self.profile ?? memberProfiles[id]
        let color = Color(hex: profile?.color) ?? memberColors[id] ?? Theme.color(for: id)
        ZStack {
            Circle().fill(color.gradient)
            if let data = profile?.photo, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().clipShape(.circle)
            } else if let emoji = profile?.emoji {
                Text(emoji).font(.system(size: size * 0.55))
            } else {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if ring { Circle().strokeBorder(.white, lineWidth: max(2, size * 0.06)) }
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = (name ?? "?").split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// Crown for the owner, shield for admins.
struct RoleBadge: View {
    let member: CircleMember

    var body: some View {
        if member.isOwner {
            Image(systemName: "crown.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
                .accessibilityLabel("Besitzer")
        } else if member.isAdmin {
            Image(systemName: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Admin")
        }
    }
}

/// Battery level next to each person. Red when low.
struct BatteryBadge: View {
    let level: Int
    let isCharging: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text("\(level) %").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(isLow ? .red : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCharging ? "Akku \(level) Prozent, lädt" : "Akku \(level) Prozent")
    }

    private var isLow: Bool { level <= 15 && !isCharging }

    private var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch level {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

/// An avatar standing on the map like a pin.
struct MemberPin: View {
    let name: String?
    let id: String
    var isFocused = false
    /// Not updated for a while: drawn faded.
    var isStale = false
    /// Above the pin: "42 km/h" while driving, or how old the position is.
    var caption: String?
    var captionSymbol: String?
    /// The person's status emoji, at the corner.
    var emoji: String?

    var body: some View {
        VStack(spacing: -3) {
            Avatar(name: name, id: id, size: isFocused ? 56 : 44, ring: true)
                .overlay(alignment: .bottomTrailing) {
                    if let emoji {
                        Text(emoji)
                            .font(.system(size: 13))
                            .frame(width: 22, height: 22)
                            .background(.white, in: .circle)
                            .offset(x: 5, y: 3)
                    }
                }
            PinTip()
                .fill(.white)
                .frame(width: 14, height: 9)
        }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .saturation(isStale ? 0.15 : 1)
        .opacity(isStale ? 0.85 : 1)
        // Over the avatar, so the tip stays on the spot.
        .overlay(alignment: .top) {
            if let caption {
                Label {
                    Text(caption).monospacedDigit()
                } icon: {
                    if let captionSymbol { Image(systemName: captionSymbol) }
                }
                .labelStyle(PinCaptionStyle())
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: .capsule)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                .fixedSize()
                .offset(y: -20)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: isFocused)
        .animation(.snappy, value: caption)
    }
}

private struct PinCaptionStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private struct PinTip: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// One of a few big actions side by side, like on a contact card.
struct QuickAction: View {
    let title: LocalizedStringResource
    let systemImage: String
    var working = false
    let action: () -> Void

    init(_ title: LocalizedStringResource, systemImage: String, working: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.working = working
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                            .font(.title3.weight(.medium))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(height: 26)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Theme.Radius.inner, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .disabled(working)
    }
}

/// Gives way a little while pressed; faded when it cannot be used.
struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .contentShape(.rect)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

/// A tick in the hand when something worked, for actions that close their
/// sheet right after (a view-bound `sensoryFeedback` would go with it).
@MainActor
enum Haptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
