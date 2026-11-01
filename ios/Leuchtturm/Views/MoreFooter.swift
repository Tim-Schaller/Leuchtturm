import SwiftUI

/// A section footer with one short line; the full explanation opens with
/// „Mehr“, so the screens stay calm and nothing is hidden for good.
struct MoreFooter: View {
    let short: LocalizedStringResource
    let more: LocalizedStringResource
    @State private var open = false

    init(_ short: LocalizedStringResource, more: LocalizedStringResource) {
        self.short = short
        self.more = more
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(short)
            if open {
                Text(more).transition(.opacity)
            }
            Button(open ? "Weniger" : "Mehr") {
                withAnimation(.snappy) { open.toggle() }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tint)
            .buttonStyle(.plain)
        }
    }
}
