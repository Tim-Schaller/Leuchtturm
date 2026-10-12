import LeuchtturmCore
import PhotosUI
import SwiftUI
import UIKit

/// The chat of a Leuchtturm: bubbles, replies, reactions, pictures and stickers.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    let details: CircleDetails
    @State private var replyTo: ChatMessage?

    static let reactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    private var messages: [ChatMessage] { details.messages.filter { $0.reactsTo == nil } }
    private var reactions: [String: [ChatMessage]] {
        Dictionary(grouping: details.messages.filter { $0.reactsTo != nil }, by: { $0.reactsTo ?? "" })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if messages.isEmpty {
                            ContentUnavailableView("Noch keine Nachrichten", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("Schreib deinem Leuchtturm. Alles ist Ende-zu-Ende-verschlüsselt."))
                                .padding(.top, 40)
                        }
                        ForEach(messages) { message in
                            MessageRow(
                                message: message, details: details,
                                quoted: message.replyTo.flatMap { id in details.messages.first { $0.id == id } },
                                reactions: reactions[message.id] ?? [],
                                onReply: { replyTo = message },
                                onReact: { emoji in send(emoji, reactsTo: message.id) },
                                onDelete: { delete(message) }
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            ChatComposer(replyTo: $replyTo, details: details)
        }
    }

    private func send(_ emoji: String, reactsTo id: String) {
        let ref = details.ref
        Task { await model.sendChat(emoji, reactsTo: id, in: ref) }
    }

    private func delete(_ message: ChatMessage) {
        let (id, ref) = (message.id, details.ref)
        Task {
            await model.run { try await $0.deleteMessage(id, in: ref) }
            model.noteRemoteChange()
        }
    }
}

private struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let details: CircleDetails
    let quoted: ChatMessage?
    let reactions: [ChatMessage]
    let onReply: () -> Void
    let onReact: (String) -> Void
    let onDelete: () -> Void

    private var isMine: Bool { message.senderID == model.client?.deviceID }
    private var sender: CircleMember? { details.members.first { $0.id == message.senderID } }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 48) } else { Avatar(name: sender?.name, id: message.senderID, size: 28) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text(sender?.name ?? String(localized: "Jemand")).font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let quoted {
                        HStack(spacing: 6) {
                            Rectangle().fill(.tint).frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(details.members.first { $0.id == quoted.senderID }?.name ?? "").font(.caption.bold())
                                Text(quoted.text.isEmpty ? String(localized: "Bild") : quoted.text).font(.caption).lineLimit(2)
                            }
                        }
                        .padding(6)
                        .background(.background.opacity(0.4), in: .rect(cornerRadius: 8))
                    }
                    if let data = message.image, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: message.isSticker ? 120 : 220, maxHeight: message.isSticker ? 120 : 260)
                            .clipShape(.rect(cornerRadius: message.isSticker ? 0 : 12))
                            .accessibilityLabel(message.isSticker ? "Sticker" : "Bild")
                    }
                    if !message.text.isEmpty {
                        Text(message.text).textSelection(.enabled)
                    }
                }
                .padding(message.isSticker && quoted == nil ? 0 : 10)
                .background {
                    if !(message.isSticker && quoted == nil) {
                        RoundedRectangle(cornerRadius: 18).fill(isMine ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.thinMaterial))
                    }
                }
                .contextMenu {
                    Button("Antworten", systemImage: "arrowshape.turn.up.left", action: onReply)
                    ControlGroup {
                        ForEach(ChatView.reactions, id: \.self) { emoji in Button(emoji) { onReact(emoji) } }
                    }
                    if !message.text.isEmpty {
                        Button("Kopieren", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    }
                    if isMine {
                        Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                }
                .onTapGesture(count: 2) { onReact("❤️") }
                if !reactions.isEmpty {
                    let counts = Dictionary(grouping: reactions, by: \.text).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
                    Text(counts.map { $0.1 > 1 ? "\($0.0) \($0.1)" : $0.0 }.joined(separator: " "))
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .glassEffect(.regular, in: .capsule)
                }
                Text(message.timestamp, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary)
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .swipeToReply(isMine: isMine, action: onReply)
    }
}

private extension View {
    /// Swipe a bubble sideways to answer it.
    func swipeToReply(isMine: Bool, action: @escaping () -> Void) -> some View {
        modifier(SwipeToReply(isMine: isMine, action: action))
    }
}

private struct SwipeToReply: ViewModifier {
    let isMine: Bool
    let action: () -> Void
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { value in
                let x = value.translation.width
                if abs(value.translation.height) < 30 { offset = isMine ? min(0, max(-70, x)) : max(0, min(70, x)) }
            }.onEnded { _ in
                if abs(offset) > 50 { action() }
                withAnimation(.spring) { offset = 0 }
            })
            .sensoryFeedback(.impact, trigger: abs(offset) > 50)
    }
}

/// Text field that accepts stickers and Genmoji from the keyboard, photo
/// button and send button.
private struct ChatComposer: View {
    @Environment(AppModel.self) private var model
    @Binding var replyTo: ChatMessage?
    let details: CircleDetails
    @State private var text = NSAttributedString()
    @State private var photo: PhotosPickerItem?
    @State private var sending = false

    var body: some View {
        VStack(spacing: 6) {
            if let replyTo {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("Antwort an \(details.members.first { $0.id == replyTo.senderID }?.name ?? "")").font(.caption.bold())
                        Text(replyTo.text.isEmpty ? String(localized: "Bild") : replyTo.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Antwort abbrechen", systemImage: "xmark.circle.fill") { self.replyTo = nil }
                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photo, matching: .images) {
                    Image(systemName: "photo").font(.title3).frame(width: 36, height: 36)
                }
                .accessibilityLabel("Foto senden")
                StickerTextView(text: $text)
                    .overlay(alignment: .leading) {
                        if text.length == 0 {
                            Text("Nachricht")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(sending || text.length == 0)
                .accessibilityLabel("Senden")
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .onChange(of: photo) { _, item in sendPhoto(item) }
    }

    private func send() {
        let content = text
        let reply = replyTo?.id
        let ref = details.ref
        sending = true
        Task {
            // Stickers and Genmoji go as their own messages, the text as one.
            var plain = ""
            var stickers: [Data] = []
            content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, _ in
                if let glyph = attributes[.adaptiveImageGlyph] as? NSAdaptiveImageGlyph {
                    stickers.append(glyph.imageContent)
                } else {
                    plain += content.attributedSubstring(from: range).string
                }
            }
            var ok = true
            for sticker in stickers {
                let data = sticker.count <= ChatMessage.maxImageBytes ? sticker : UIImage(data: sticker)?.pngData() ?? sticker
                ok = await model.sendChat("", replyTo: reply, image: data, isSticker: true, in: ref) && ok
            }
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ok = await model.sendChat(trimmed, replyTo: reply, in: ref) && ok }
            if ok {
                text = NSAttributedString()
                replyTo = nil
            }
            sending = false
        }
    }

    private func sendPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        let reply = replyTo?.id
        let ref = details.ref
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                  let jpeg = ProfileEditor.compress(image, side: 1280, maxBytes: ChatMessage.maxImageBytes, square: false)
            else { return }
            if await model.sendChat("", replyTo: reply, image: jpeg, in: ref) { replyTo = nil }
            photo = nil
        }
    }
}

/// Pasted text comes in plain (no foreign fonts or colours); pictures and
/// stickers keep the system behaviour.
private final class ComposerTextView: UITextView {
    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        guard !board.hasImages, board.hasStrings, let string = board.string else {
            super.paste(sender)
            return
        }
        insertText(string)
    }
}

/// UITextView that takes stickers and Genmoji from the emoji keyboard.
private struct StickerTextView: UIViewRepresentable {
    @Binding var text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = ComposerTextView()
        view.supportsAdaptiveImageGlyph = true
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = true
        view.delegate = context.coordinator
        view.accessibilityLabel = String(localized: "Nachricht")
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if text.length == 0 && view.attributedText.length > 0 { view.attributedText = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    /// Grows with the text, from one line up to about five.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let line = uiView.font?.lineHeight ?? 20
        return CGSize(width: width, height: min(max(fitting.height, line + 16), line * 5 + 16))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let text: Binding<NSAttributedString>
        init(text: Binding<NSAttributedString>) { self.text = text }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.attributedText
            view.invalidateIntrinsicContentSize()
        }
    }
}
