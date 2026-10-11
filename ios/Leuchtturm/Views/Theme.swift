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
        Color(red: 0.12, green: 0.42, blue: 0.29), // pine
    ]

    static func color(for id: String) -> Color {
        // djb2: stable across launches and devices, unlike `hashValue`.
        let hash = id.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        return memberColors[Int(hash % UInt32(memberColors.count))]
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
    static var sky: LinearGradient {
        LinearGradient(colors: [skyTop, skyBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// A person as a colored circle with initials.
struct Avatar: View {
    let name: String?
    let id: String
    var size: CGFloat = 44

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.color(for: id).gradient, in: .circle)
            .overlay { Circle().strokeBorder(.white, lineWidth: max(2, size * 0.06)) }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = (name ?? "?").split(separator: " ").prefix(2)
        return parts.compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// An avatar standing on the map like a pin.
struct MemberPin: View {
    let name: String?
    let id: String
    var isFocused = false
    /// Not updated for a while: drawn faded.
    var isStale = false

    var body: some View {
        VStack(spacing: -3) {
            Avatar(name: name, id: id, size: isFocused ? 56 : 44)
            PinTip()
                .fill(.white)
                .frame(width: 14, height: 9)
        }
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .saturation(isStale ? 0.15 : 1)
        .opacity(isStale ? 0.8 : 1)
        .animation(.spring(duration: 0.3), value: isFocused)
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
