import SwiftUI

/// The lighthouse with a turning beam: shown while something takes a moment
/// (starting up, creating or joining a Leuchtturm).
struct BeaconLoading: View {
    var message: LocalizedStringKey?
    var size: CGFloat = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                // The beam: a soft wedge that circles the lantern.
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(hex: "#FFDC8C")!.opacity(0.0), location: 0.0),
                        .init(color: Color(hex: "#FFDC8C")!.opacity(0.85), location: 0.06),
                        .init(color: Color(hex: "#FFDC8C")!.opacity(0.0), location: 0.16),
                        .init(color: .clear, location: 1.0),
                    ]),
                    center: .center
                )
                .frame(width: size * 2.4, height: size * 2.4)
                .mask(Circle())
                .rotationEffect(.degrees(turning ? 360 : 0))
                // Flattened, so it sweeps across the horizon at the lantern.
                .scaleEffect(x: 1, y: 0.22)
                .opacity(reduceMotion ? 0.6 : 1)
                .offset(y: -size * 0.19)
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
            .frame(width: size * 1.6, height: size * 1.4)
            .accessibilityHidden(true)
            if let message {
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.map { Text($0) } ?? Text("Lädt …"))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}

/// Full-screen version over the app while it starts.
struct BeaconLoadingScreen: View {
    var message: LocalizedStringKey = "Leuchtturm wird geladen …"

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            BeaconLoading(message: message, size: 140)
        }
    }
}
