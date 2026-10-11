import SwiftUI

/// Hold for 3 seconds to alert every circle with the exact position.
struct SOSSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var holding = false
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                if let sentAt = model.sosSentAt {
                    Label("Deine Kreise wurden \(sentAt.formatted(.relative(presentation: .named))) alarmiert.", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.center)
                    Link(destination: URL(string: "tel:112")!) {
                        Label("Notruf 112 anrufen", systemImage: "phone.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    Button("Entwarnung senden", systemImage: "hand.thumbsup") {
                        Task {
                            await model.sendAllClear()
                            dismiss()
                        }
                    }
                    .buttonStyle(.glass)
                } else {
                    Text("Halte den Knopf 3 Sekunden gedrückt. Alle deine Kreise bekommen eine dringende Nachricht mit deinem genauen Ort, auch im Nebel.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    ZStack {
                        Circle()
                            .fill(.red.gradient)
                            .frame(width: 180, height: 180)
                            .scaleEffect(holding ? 0.92 : 1)
                        Circle()
                            .trim(from: 0, to: holding ? 1 : 0)
                            .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 156, height: 156)
                            .animation(holding ? .linear(duration: 3) : .default, value: holding)
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Text("SOS").font(.system(size: 44, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        }
                    }
                    .onLongPressGesture(minimumDuration: 3) {
                        send()
                    } onPressingChanged: { pressing in
                        holding = pressing
                    }
                    .accessibilityLabel("SOS")
                    .accessibilityHint("Drei Sekunden gedrückt halten, um deine Kreise zu alarmieren")
                    .accessibilityAction { send() }
                    Text("Leuchtturm ist kein Notrufdienst. In Lebensgefahr ruf direkt die 112 an.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(24)
            .navigationTitle("SOS")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
        }
        .sensoryFeedback(.warning, trigger: model.sosSentAt)
        .presentationDetents([.large])
    }

    private func send() {
        guard !sending else { return }
        sending = true
        Task {
            await model.sendSOS()
            sending = false
        }
    }
}

/// After an abrupt stop while driving: "Are you OK?" with a countdown.
struct CrashCheckView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "car.side.rear.and.collision.and.car.side.front")
                .font(.system(size: 64))
                .foregroundStyle(.white)
            Text("Alles okay?")
                .font(.largeTitle.bold())
                .foregroundStyle(.white)
            if let deadline = model.crashCheckDeadline {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                    Text("Es sah nach einem Unfall aus. In \(left) Sekunden alarmiert Leuchtturm deine Kreise.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }
            }
            Spacer()
            Button {
                model.cancelCrashCheck()
            } label: {
                Text("Mir geht's gut").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .tint(.white.opacity(0.25))
            Button {
                Task { await model.confirmCrashHelp() }
            } label: {
                Text("Hilfe rufen").font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .tint(.black.opacity(0.35))
        }
        .padding(24)
        .background(.red.gradient)
        .sensoryFeedback(.warning, trigger: model.crashCheckDeadline)
    }
}
