import SwiftUI
import UIKit

/// A person's pin as the widgets, Apple Watch and Apple TV show it.
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
