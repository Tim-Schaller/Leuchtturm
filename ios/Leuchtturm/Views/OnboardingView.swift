import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "light.beacon.max")
                            .font(.system(size: 52))
                            .foregroundStyle(.tint)
                        Text("Willkommen bei Leuchtturm")
                            .font(.title2.bold())
                        Text("Teile deinen Standort mit den Menschen, die dir wichtig sind. Alles wird auf deinem iPhone verschlüsselt, bevor es dein Gerät verlässt.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.clear)

                Section {
                    TextField("Dein Name", text: $name)
                        .textContentType(.givenName)
                        .submitLabel(.go)
                        .onSubmit(start)
                } header: {
                    Text("Name")
                } footer: {
                    Text("So sehen dich die Mitglieder deiner Kreise. Nur sie können ihn lesen.")
                }

                Section {
                    Label {
                        Text("Gespeichert wird in deiner iCloud. Apple sieht nur verschlüsselte Daten, aber welche iCloud-Konten gemeinsam in einem Kreis sind. Alle Mitglieder brauchen ein iCloud-Konto.")
                    } icon: {
                        Image(systemName: "icloud")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Wo liegen meine Daten?")
                }

                Section {
                    Button(action: start) {
                        HStack {
                            Spacer()
                            if model.isLoading {
                                ProgressView()
                            } else {
                                Text("Los geht's").bold()
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isLoading || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .navigationTitle(AppInfo.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func start() {
        guard !model.isLoading else { return }
        Task { _ = await model.setUp(name: name) }
    }
}
