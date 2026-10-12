import SwiftUI

/// The tabs at the top of the drawer.
enum DrawerTab: CaseIterable, Identifiable {
    case people
    case places
    case trips
    case ranking

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .people: "Personen"
        case .places: "Orte"
        case .trips: "Fahrten"
        case .ranking: "Bestenliste"
        }
    }

    var symbol: String {
        switch self {
        case .people: "person.2.fill"
        case .places: "mappin.and.ellipse"
        case .trips: "car.fill"
        case .ranking: "trophy.fill"
        }
    }
}

/// Glass tab bar: the selected tab is a tinted capsule.
struct DrawerTabBar: View {
    @Binding var selection: DrawerTab
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(DrawerTab.allCases) { tab in
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { selection = tab }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tab.symbol).font(.body.weight(.semibold))
                            Text(tab.title).font(.caption2.weight(.semibold)).lineLimit(1)
                        }
                        .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(selection == tab ? .regular.tint(Color.accentColor.opacity(0.18)).interactive() : .identity, in: .capsule)
                    .glassEffectID(tab, in: glass)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}
