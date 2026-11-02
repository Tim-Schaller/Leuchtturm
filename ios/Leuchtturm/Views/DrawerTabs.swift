import SwiftUI

/// The tabs at the top of the drawer.
enum DrawerTab: CaseIterable, Identifiable {
    case people
    case chat
    case places
    case week

    var id: Self { self }

    /// The tab the drawer starts on; in test builds `-demoTab week` picks one for screenshots.
    static var start: DrawerTab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "demoTab") {
        case "chat": return .chat
        case "places": return .places
        case "week": return .week
        default: return .people
        }
        #else
        return .people
        #endif
    }

    var title: LocalizedStringResource {
        switch self {
        case .people: "Personen"
        case .chat: "Chat"
        case .places: "Orte"
        case .week: "Woche"
        }
    }

    var symbol: String {
        switch self {
        case .people: "person.2.fill"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .places: "mappin.and.ellipse"
        case .week: "chart.bar.fill"
        }
    }
}

/// The tabs: symbols on one line, the selected one on a tinted capsule
/// that slides over. The content below switches at once.
struct DrawerTabBar: View {
    @Binding var selection: DrawerTab
    @Namespace private var pill
    @ScaledMetric(relativeTo: .body) private var iconHeight = 22

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DrawerTab.allCases) { tab in
                let selected = selection == tab
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.body.weight(.semibold))
                            .frame(height: iconHeight)
                        Text(tab.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.14))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.28), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
