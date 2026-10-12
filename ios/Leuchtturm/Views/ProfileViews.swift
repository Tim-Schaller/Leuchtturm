import LeuchtturmCore
import PhotosUI
import SwiftUI
import UIKit

extension Color {
    /// "#RRGGBB"
    init?(hex: String?) {
        guard let hex, hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String {
        let c = UIColor(self).cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0]
        let rgb = (0 ..< 3).map { Int((c.indices.contains($0) ? c[$0] : 0) * 255) }
        return String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2])
    }
}

extension EnvironmentValues {
    /// Profiles of the people in the circle on screen, by device ID.
    @Entry var memberProfiles: [String: Profile] = [:]
}

/// Banner looks without a picture.
enum BannerStyle: String, CaseIterable, Identifiable {
    case meadow, sea, sunset, night, forest, lavender
    var id: String { rawValue }

    var gradient: LinearGradient {
        let colors: [Color] = switch self {
        case .meadow: [Color(hex: "#CFEFF0")!, Color(hex: "#8ACB88")!]
        case .sea: [Color(hex: "#9AD8F0")!, Color(hex: "#2E6FA8")!]
        case .sunset: [Color(hex: "#FFD27A")!, Color(hex: "#F2786B")!]
        case .night: [Color(hex: "#173B4A")!, Color(hex: "#0F2A20")!]
        case .forest: [Color(hex: "#4E9F6E")!, Color(hex: "#1F5E43")!]
        case .lavender: [Color(hex: "#E3D5F5")!, Color(hex: "#9576C9")!]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The top of a person's page: banner with the big avatar.
struct ProfileHeader: View {
    let member: CircleMember
    let subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let data = member.profile?.banner, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    (BannerStyle(rawValue: member.profile?.bannerStyle ?? "") ?? .meadow).gradient
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(.rect(cornerRadius: 20))
            .accessibilityHidden(true)
            Avatar(name: member.name, id: member.id, size: 84)
                .offset(y: -42)
                .padding(.bottom, -42)
            VStack(spacing: 4) {
                if let status = member.profile?.status(at: Date()) {
                    Text([status.emoji, status.text].compactMap { $0 }.joined(separator: " "))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Edit your own picture, banner, pin and status.
struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var profile = Profile()
    @State private var photoItem: PhotosPickerItem?
    @State private var bannerItem: PhotosPickerItem?
    @State private var statusHours = 2.0
    @State private var saving = false
    @State private var pickedColor = Color.accentColor
    @State private var statusText = ""

    static let statusPresets: [(emoji: String, text: LocalizedStringResource)] = [
        ("🏋️", "beim Sport"), ("💼", "bei der Arbeit"), ("📚", "in der Schule"), ("🚗", "unterwegs"),
        ("🍽️", "beim Essen"), ("😴", "schläft"), ("📵", "nicht stören"), ("🎉", "feiert"),
    ]
    static let emojis = ["🦊", "🐻", "🐼", "🐸", "🦉", "🐝", "🌻", "⚓️", "🏄", "🚲", "⭐️", "🍀"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 0) {
                        ProfileHeader(member: preview, subtitle: model.displayName)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                Section("Bild") {
                    let hasPhoto = profile.photo != nil
                    let hasBanner = profile.banner != nil
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(hasPhoto ? "Profilbild ändern" : "Profilbild wählen", systemImage: "person.crop.circle")
                    }
                    PhotosPicker(selection: $bannerItem, matching: .images) {
                        Label(hasBanner ? "Bannerbild ändern" : "Bannerbild wählen", systemImage: "photo")
                    }
                    if profile.photo != nil || profile.banner != nil {
                        Button("Bilder entfernen", systemImage: "trash", role: .destructive) {
                            profile.photo = nil
                            profile.banner = nil
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(BannerStyle.allCases) { style in
                                Button { profile.bannerStyle = style.rawValue; profile.banner = nil } label: {
                                    style.gradient.frame(width: 56, height: 32).clipShape(.rect(cornerRadius: 8))
                                        .overlay { if profile.bannerStyle == style.rawValue && profile.banner == nil {
                                            RoundedRectangle(cornerRadius: 8).strokeBorder(.primary, lineWidth: 2)
                                        } }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(style.rawValue)
                            }
                        }
                    }
                }
                Section("Pin") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Theme.memberColors.indices, id: \.self) { i in
                                let color = Theme.memberColors[i]
                                Button { profile.color = color.hex } label: {
                                    Circle().fill(color).frame(width: 32, height: 32)
                                        .overlay { if profile.color == color.hex { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                                }
                                .buttonStyle(.plain)
                            }
                            ColorPicker("", selection: $pickedColor, supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            Button { profile.emoji = nil } label: {
                                Text("Aa").font(.headline).frame(width: 36, height: 36)
                                    .background(profile.emoji == nil ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Initialen")
                            ForEach(Self.emojis, id: \.self) { emoji in
                                Button { profile.emoji = emoji } label: {
                                    Text(emoji).font(.title2).frame(width: 36, height: 36)
                                        .background(profile.emoji == emoji ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
                        ForEach(Self.statusPresets, id: \.emoji) { preset in
                            let text = String(localized: preset.text)
                            Button {
                                profile.statusEmoji = preset.emoji
                                profile.statusText = text
                            } label: {
                                Text("\(preset.emoji) \(text)")
                                    .font(.subheadline)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(profile.statusText == text ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("Eigener Status", text: $statusText)
                    Picker("Wie lange?", selection: $statusHours) {
                        Text("1 Std.").tag(1.0)
                        Text("2 Std.").tag(2.0)
                        Text("Heute").tag(0.0)
                        Text("Bis ich es ändere").tag(-1.0)
                    }
                    if profile.statusText != nil || profile.statusEmoji != nil {
                        Button("Status löschen", role: .destructive) {
                            profile.statusEmoji = nil
                            profile.statusText = nil
                        }
                    }
                } header: {
                    Text("Status")
                } footer: {
                    Text("Bild, Pin und Status sehen alle in deinen Leuchttürmen, Ende-zu-Ende-verschlüsselt.")
                }
            }
            .navigationTitle("Profil gestalten")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).disabled(saving)
                }
            }
            .onAppear {
                profile = model.myProfile
                statusText = profile.statusText ?? ""
                pickedColor = Color(hex: profile.color) ?? .accentColor
            }
            .onChange(of: pickedColor) { _, color in profile.color = color.hex }
            .onChange(of: statusText) { _, text in
                profile.statusText = text.isEmpty ? nil : String(text.prefix(Profile.maxStatusLength))
            }
            .onChange(of: profile.statusText) { _, text in if (text ?? "") != statusText { statusText = text ?? "" } }
            .onChange(of: photoItem) { _, item in load(item, side: 256, maxBytes: Profile.maxPhotoBytes, square: true) { profile.photo = $0 } }
            .onChange(of: bannerItem) { _, item in load(item, side: 900, maxBytes: Profile.maxBannerBytes, square: false) { profile.banner = $0 } }
        }
    }

    private var preview: CircleMember {
        CircleMember(
            id: model.client?.deviceID ?? "", userID: nil, name: model.displayName, isOwner: false, isMe: true,
            isPending: false, safetyCode: "", location: nil, profile: profile
        )
    }

    private func save() {
        saving = true
        var updated = profile
        if updated.statusText != nil || updated.statusEmoji != nil {
            updated.statusUntil = switch statusHours {
            case -1: nil
            case 0: Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())
            default: Date().addingTimeInterval(statusHours * 3600)
            }
        } else {
            updated.statusUntil = nil
        }
        Task {
            if await model.saveProfile(updated) { dismiss() }
            saving = false
        }
    }

    /// Loads a picture, scales it down and compresses it until it fits.
    private func load(_ item: PhotosPickerItem?, side: CGFloat, maxBytes: Int, square: Bool, apply: @escaping (Data) -> Void) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
            if let jpeg = Self.compress(image, side: side, maxBytes: maxBytes, square: square) { apply(jpeg) }
        }
    }

    static func compress(_ image: UIImage, side: CGFloat, maxBytes: Int, square: Bool) -> Data? {
        let size = image.size
        let scale = min(1, side / max(size.width, size.height))
        var target = CGSize(width: size.width * scale, height: size.height * scale)
        var origin = CGPoint.zero
        if square {
            let edge = min(size.width, size.height) * min(1, side / min(size.width, size.height))
            target = CGSize(width: edge, height: edge)
            let drawScale = edge / min(size.width, size.height)
            origin = CGPoint(x: (edge - size.width * drawScale) / 2, y: (edge - size.height * drawScale) / 2)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            if square {
                let drawScale = target.width / min(size.width, size.height)
                image.draw(in: CGRect(origin: origin, size: CGSize(width: size.width * drawScale, height: size.height * drawScale)))
            } else {
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        }
        for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
            if let data = rendered.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
        }
        return nil
    }
}
