import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LeuchtturmWidgets: WidgetBundle {
    var body: some Widget {
        PeopleWidget()
        TripLiveActivity()
    }
}

// MARK: People

struct PeopleEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct PeopleProvider: TimelineProvider {
    func placeholder(in context: Context) -> PeopleEntry { PeopleEntry(date: Date(), snapshot: .preview) }

    func getSnapshot(in context: Context, completion: @escaping (PeopleEntry) -> Void) {
        completion(PeopleEntry(date: Date(), snapshot: context.isPreview ? .preview : WidgetSnapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PeopleEntry>) -> Void) {
        // The app reloads the timeline whenever it has news; refresh every 15 min anyway.
        completion(Timeline(entries: [PeopleEntry(date: Date(), snapshot: WidgetSnapshot.load())], policy: .after(Date().addingTimeInterval(900))))
    }
}

struct PeopleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "people", provider: PeopleProvider()) { entry in
            PeopleWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(red: 0.85, green: 0.95, blue: 0.93), Color(red: 0.93, green: 0.98, blue: 0.94)], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Leuchtturm")
        .description("Wer ist wo, mit Akkustand.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

struct PeopleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PeopleEntry

    var body: some View {
        if let snapshot = entry.snapshot, !snapshot.people.isEmpty {
            switch family {
            case .accessoryInline:
                Text(snapshot.people.prefix(2).map { "\($0.name) · \($0.place)" }.joined(separator: ", "))
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Image(systemName: "person.2.fill")
                        Text("\(snapshot.people.count)").font(.headline)
                    }
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(snapshot.people.prefix(3)) { person in
                        Text("\(person.emoji ?? person.initials) \(person.name) · \(person.place)").font(.caption).lineLimit(1)
                    }
                }
            case .systemSmall:
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.circleName).font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(snapshot.people.prefix(3)) { person in
                        HStack(spacing: 6) {
                            WidgetAvatar(person: person, size: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(person.name).font(.caption.bold()).lineLimit(1)
                                Text(person.place).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(snapshot.circleName).font(.headline)
                        Spacer()
                        Text(snapshot.written, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.people.prefix(family == .systemLarge ? 7 : 3)) { person in
                        HStack(spacing: 10) {
                            WidgetAvatar(person: person, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.name).font(.subheadline.bold())
                                Text([person.status, person.place].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let battery = person.battery {
                                Text("\(battery) %").font(.caption).monospacedDigit().foregroundStyle(battery <= 15 ? .red : .secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "light.beacon.max").font(.title)
                Text("Öffne Leuchtturm, um loszulegen.").font(.caption).multilineTextAlignment(.center)
            }
        }
    }
}

struct WidgetAvatar: View {
    let person: WidgetSnapshot.Person
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Color(widgetHex: person.colorHex).gradient)
            if let data = person.photo, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().clipShape(.circle)
            } else if let emoji = person.emoji {
                Text(emoji).font(.system(size: size * 0.55))
            } else {
                Text(person.initials).font(.system(size: size * 0.42, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

extension Color {
    init(widgetHex hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x2F8F5B
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

// MARK: Live Activity

struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.speed != nil ? "car.fill" : "figure.walk.motion")
                    .font(.title2).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title).font(.headline)
                    HStack {
                        Text(context.state.distance)
                        if let eta = context.state.eta {
                            Text("· Ankunft \(eta, style: .time)")
                        } else {
                            Text("· seit \(context.attributes.started, style: .relative)")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let speed = context.state.speed {
                    VStack(spacing: 0) {
                        Text("\(speed)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("km/h").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.93, green: 0.98, blue: 0.94))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.title, systemImage: "light.beacon.max").font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let speed = context.state.speed { Text("\(speed) km/h").font(.headline).monospacedDigit() }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.distance)
                        Spacer()
                        if let eta = context.state.eta { Text("Ankunft \(eta, style: .time)") }
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Image(systemName: context.state.speed != nil ? "car.fill" : "figure.walk.motion").foregroundStyle(.green)
            } compactTrailing: {
                if let speed = context.state.speed {
                    Text("\(speed)").monospacedDigit()
                } else if let eta = context.state.eta {
                    Text(eta, style: .time)
                }
            } minimal: {
                Image(systemName: "light.beacon.max").foregroundStyle(.green)
            }
        }
    }
}
