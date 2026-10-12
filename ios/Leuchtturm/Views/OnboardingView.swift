import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image("Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 120)
                            .accessibilityHidden(true)
                        Text("Willkommen bei Leuchtturm")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
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
                    Text("So sehen dich die Mitglieder deiner Leuchttürme. Nur sie können ihn lesen.")
                }

                Section {
                    Label {
                        model.isSimulation
                            ? Text("Simulation: Alles bleibt im Speicher dieser App, nichts geht an iCloud. Beendest du die App, ist alles weg.")
                            : Text("Gespeichert wird in deiner iCloud. Apple sieht nur verschlüsselte Daten, aber welche iCloud-Konten gemeinsam in einem Leuchtturm sind. Alle Mitglieder brauchen ein iCloud-Konto.")
                    } icon: {
                        Image(systemName: model.isSimulation ? "testtube.2" : "icloud")
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

                #if DEBUG
                if !model.isSimulation {
                    Section {
                        Button("Ohne iCloud ausprobieren", systemImage: "testtube.2") { model.startSimulation() }
                            .frame(maxWidth: .infinity)
                    } footer: {
                        Text("Nur in Test-Builds: eine Simulation mit erfundenen Personen. Nichts geht an iCloud.")
                    }
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background {
                // Mint sky with green hills along the bottom.
                ZStack(alignment: .bottom) {
                    Theme.sky
                    Image("Hills")
                        .resizable()
                        .scaledToFit()
                        .accessibilityHidden(true)
                }
                .ignoresSafeArea()
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func start() {
        guard !model.isLoading else { return }
        Task { _ = await model.setUp(name: name) }
    }
}
