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
        let rgb = (0 ..< 3).map { Int(((c.indices.contains($0) ? c[$0] : 0) * 255).rounded()) }
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
            // The picture fills the banner without widening the layout.
            Color.clear
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let data = member.profile?.banner, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        (BannerStyle(rawValue: member.profile?.bannerStyle ?? "") ?? .meadow).gradient
                    }
                }
                .clipShape(.rect(cornerRadius: 20))
                .accessibilityHidden(true)
            Avatar(name: member.name, id: member.id, size: 84, profile: member.profile)
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
    /// Hours; 0 = until midnight, -1 = until changed.
    @State private var statusHours = 2.0
    /// The status and its expiry stay as they are unless one of them is changed.
    @State private var statusEdited = false
    @State private var saving = false
    @State private var loadingPicture = false
    @State private var pickedColor = Color.accentColor
    @State private var statusText = ""

    static let statusPresets: [(emoji: String, text: LocalizedStringResource)] = [
        ("🏋️", "beim Sport"), ("💼", "bei der Arbeit"), ("📚", "in der Schule"), ("🚗", "unterwegs"),
        ("🍽️", "beim Essen"), ("😴", "schläft"), ("📵", "nicht stören"), ("🎉", "feiert"),
    ]
    static let emojis = ["🦊", "🐻", "🐼", "🐸", "🦉", "🐝", "🌻", "⚓️", "🏄", "🚲", "⭐️", "🍀"]

    private var myID: String { model.client?.deviceID ?? "" }
    /// The pin colour as shown: chosen, or the one the app picks from the ID.
    private var currentColor: Color { Color(hex: profile.color) ?? Theme.color(for: myID) }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                pictureSection
                pinSection
                statusSection
            }
            .navigationTitle("Profil gestalten")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern", action: save).disabled(saving || loadingPicture)
                }
            }
            .onAppear {
                var current = model.myProfile
                // A status that has run out is not shown or kept.
                if current.status(at: Date()) == nil {
                    current.statusEmoji = nil
                    current.statusText = nil
                    current.statusUntil = nil
                }
                profile = current
                statusText = current.statusText ?? ""
                statusHours = current.statusText != nil || current.statusEmoji != nil
                    ? (current.statusUntil == nil ? -1 : 2) : 2
                pickedColor = Color(hex: current.color) ?? Theme.color(for: myID)
            }
            // Only a real change sets a colour; opening the editor keeps the automatic one.
            .onChange(of: pickedColor) { _, color in
                if color.hex != currentColor.hex { profile.color = color.hex }
            }
            .onChange(of: statusText) { _, text in
                let trimmed = String(text.prefix(Profile.maxStatusLength))
                if trimmed != text { statusText = trimmed; return }
                let value = trimmed.trimmingCharacters(in: .whitespaces)
                guard (value.isEmpty ? nil : value) != profile.statusText else { return }
                profile.statusText = value.isEmpty ? nil : value
                // Own words: the emoji of a preset no longer fits.
                if !Self.statusPresets.contains(where: { String(localized: $0.text) == value }) { profile.statusEmoji = nil }
                statusEdited = true
            }
            .onChange(of: profile.statusText) { _, text in if (text ?? "") != statusText.trimmingCharacters(in: .whitespaces) { statusText = text ?? "" } }
            .onChange(of: photoItem) { _, item in load(item, side: 256, maxBytes: Profile.maxPhotoBytes, square: true) { profile.photo = $0 } }
            .onChange(of: bannerItem) { _, item in load(item, side: 900, maxBytes: Profile.maxBannerBytes, square: false) { profile.banner = $0 } }
        }
    }

    @ViewBuilder private var headerSection: some View {
        Section {
            ProfileHeader(member: preview, subtitle: model.displayName)
                .overlay {
                    if loadingPicture { ProgressView().controlSize(.large) }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder private var pictureSection: some View {
        // Computed outside the picker labels, which are Sendable closures.
        let hasPhoto = profile.photo != nil
        let hasBanner = profile.banner != nil
        Section("Bild") {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(hasPhoto ? "Profilbild ändern" : "Profilbild wählen", systemImage: "person.crop.circle")
            }
            if profile.photo != nil {
                Button("Profilbild entfernen", systemImage: "trash", role: .destructive) { profile.photo = nil }
            }
            PhotosPicker(selection: $bannerItem, matching: .images) {
                Label(hasBanner ? "Bannerbild ändern" : "Bannerbild wählen", systemImage: "photo")
            }
            if profile.banner != nil {
                Button("Bannerbild entfernen", systemImage: "trash", role: .destructive) { profile.banner = nil }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(BannerStyle.allCases) { style in
                        BannerChoice(style: style, isOn: profile.banner == nil && (profile.bannerStyle ?? BannerStyle.meadow.rawValue) == style.rawValue) {
                            profile.bannerStyle = style.rawValue
                            profile.banner = nil
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private var pinSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Theme.memberColors.indices, id: \.self) { i in
                        let color = Theme.memberColors[i]
                        let isOn = currentColor.hex == color.hex
                        Button {
                            profile.color = color.hex
                            pickedColor = color
                        } label: {
                            Circle().fill(color).frame(width: 32, height: 32)
                                .overlay { if isOn { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                    ColorPicker("Eigene Farbe", selection: $pickedColor, supportsOpacity: false)
                        .labelsHidden()
                }
                .padding(.vertical, 2)
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
        } header: {
            Text("Pin")
        } footer: {
            if profile.photo != nil {
                Text("Mit Profilbild zeigt der Pin dein Bild; Emoji und Initialen siehst du, wenn du es entfernst.")
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
                ForEach(Self.statusPresets, id: \.emoji) { preset in
                    let text = String(localized: preset.text)
                    let isOn = profile.statusEmoji == preset.emoji && profile.statusText == text
                    Button {
                        profile.statusEmoji = preset.emoji
                        profile.statusText = text
                        statusEdited = true
                    } label: {
                        Text("\(preset.emoji) \(text)")
                            .font(.subheadline)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(isOn ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
            TextField("Eigener Status", text: $statusText)
            Picker("Wie lange?", selection: Binding(get: { statusHours }, set: { statusHours = $0; statusEdited = true })) {
                Text("1 Std.").tag(1.0)
                Text("2 Std.").tag(2.0)
                Text("Heute").tag(0.0)
                Text("Bis ich es ändere").tag(-1.0)
            }
            if profile.statusText != nil || profile.statusEmoji != nil {
                if !statusEdited, let until = profile.statusUntil {
                    LabeledContent("Läuft ab", value: until.formatted(date: .omitted, time: .shortened))
                }
                Button("Status löschen", role: .destructive) {
                    profile.statusEmoji = nil
                    profile.statusText = nil
                    statusEdited = true
                }
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Bild, Pin und Status sehen alle in deinen Leuchttürmen, Ende-zu-Ende-verschlüsselt.")
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
        if updated.statusText == nil && updated.statusEmoji == nil {
            updated.statusUntil = nil
        } else if statusEdited {
            updated.statusUntil = switch statusHours {
            case -1: nil
            case 0: Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date())
            default: Date().addingTimeInterval(statusHours * 3600)
            }
        }
        Task {
            if await model.saveProfile(updated) { dismiss() }
            saving = false
        }
    }

    /// Loads a picture, scales it down and compresses it until it fits.
    private func load(_ item: PhotosPickerItem?, side: CGFloat, maxBytes: Int, square: Bool, apply: @escaping (Data) -> Void) {
        guard let item else { return }
        loadingPicture = true
        Task {
            defer {
                loadingPicture = false
                photoItem = nil
                bannerItem = nil
            }
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                  let jpeg = Self.compress(image, side: side, maxBytes: maxBytes, square: square)
            else {
                model.errorMessage = String(localized: "Das Bild ließ sich nicht laden. Versuch ein anderes.")
                return
            }
            apply(jpeg)
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

private struct BannerChoice: View {
    let style: BannerStyle
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            style.gradient
                .frame(width: 56, height: 32)
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    if isOn { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary, lineWidth: 2) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.rawValue)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
