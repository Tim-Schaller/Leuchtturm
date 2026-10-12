import LeuchtturmCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var confirmReset = false
    @State private var saving = false
    @State private var editingProfile = false
    @State private var schemaCreated = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Profil gestalten", systemImage: "paintbrush") { editingProfile = true }
                }

                Section {
                    TextField("Dein Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit(saveName)
                    if name.trimmingCharacters(in: .whitespaces) != model.displayName {
                        Button("Name speichern", action: saveName)
                            .disabled(saving)
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Wird in allen deinen Leuchttürmen verschlüsselt aktualisiert.")
                }

                Section {
                    Toggle("Standort teilen", isOn: Binding(
                        get: { model.isSharingLocation },
                        set: { on in Task { await model.setSharingLocation(on) } }
                    ))
                    Toggle("Guten-Morgen-Gruß", isOn: Binding(
                        get: { model.sendsMorningGreeting },
                        set: { model.setMorningGreeting($0) }
                    ))
                    if model.isSharingLocation, let lastSharedAt = model.lastSharedAt {
                        LabeledContent("Zuletzt geteilt") {
                            Text(lastSharedAt, format: .relative(presentation: .named))
                        }
                    }
                    if model.tracker.isDenied {
                        Button("Standortzugriff erlauben", systemImage: "location") { openAppSettings() }
                    } else if model.isSharingLocation && !model.isSimulation {
                        if model.tracker.isAlwaysAllowed {
                            Label("Auch bei geschlossener App", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        } else {
                            Button("Auf „Immer“ stellen", systemImage: "location.circle") {
                                if !model.tracker.requestAlways() { openAppSettings() }
                            }
                        }
                    }
                } header: {
                    Text("Standort")
                } footer: {
                    Text("Dein Standort wird auf diesem iPhone verschlüsselt und nur mit deinen Leuchttürmen geteilt. Mit Standortzugriff „Immer“ sehen sie dich auch, wenn die App geschlossen ist, ohne dauerhaften blauen Hinweis in der Statusleiste. Mit „Beim Verwenden“ teilt die App nur, solange die App offen ist, weil iOS sonst den Hinweis ständig zeigen würde. Steht dein iPhone still, pausiert die Ortung und spart Akku. Ausschalten entfernt deinen Standort sofort aus allen Leuchttürmen. Der Guten-Morgen-Gruß sagt deinen Leuchttürmen Bescheid, wenn du morgens zum ersten Mal unterwegs bist.")
                }

                Section {
                    Toggle("Verlauf teilen", isOn: Binding(
                        get: { model.sharesHistory },
                        set: { on in Task { await model.setSharesHistory(on) } }
                    ))
                    if model.sharesHistory {
                        Picker("Aufbewahren", selection: Binding(
                            get: { model.historyDays },
                            set: { days in Task { await model.setHistoryDays(days) } }
                        )) {
                            ForEach(HistoryDay.retentions, id: \.self) { days in
                                Text(days == 1 ? "Nur heute" : "\(days) Tage").tag(days)
                            }
                        }
                    }
                    Toggle("Fahrten teilen", isOn: Binding(
                        get: { model.sharesTrips },
                        set: { on in Task { await model.setSharesTrips(on) } }
                    ))
                    if StepsMonitor.isAvailable {
                        Toggle("Schritte teilen", isOn: Binding(
                            get: { model.sharesSteps },
                            set: { on in Task { await model.setSharesSteps(on) } }
                        ))
                    }
                    Toggle("Erinnerungen", isOn: Binding(
                        get: { model.keepsMemories },
                        set: { model.setKeepsMemories($0) }
                    ))
                    Toggle("Wetter bei den anderen", isOn: Binding(
                        get: { model.showsWeather },
                        set: { model.setShowsWeather($0) }
                    ))
                    Toggle("Unfallerkennung", isOn: Binding(
                        get: { model.detectsCrashes },
                        set: { model.setDetectsCrashes($0) }
                    ))
                } header: {
                    Text("Verlauf und Fahrten")
                } footer: {
                    Text("Aus, solange du es nicht einschaltest. Dann sehen deine Leuchttürme, wo du an den letzten Tagen unterwegs warst, Ende-zu-Ende-verschlüsselt. Ältere Tage löscht dein iPhone selbst. Ausschalten löscht den ganzen Verlauf sofort.\n\nFahrten erkennt dein iPhone selbst ab 25 km/h und mit dem Bewegungssensor, damit Rad und Bahn nicht zählen. Teilst du sie, sieht dein Leuchtturm Route, Strecke, Höchsttempo, starkes Bremsen und Beschleunigen, während der Fahrt dein Tempo und dich in der Wochen-Bestenliste. Fahrten werden nach 30 Tagen gelöscht, beim Ausschalten sofort.\n\nUnfallerkennung: Hält das Auto schlagartig an, fragt die App „Alles okay?“. Ohne Antwort bekommen deine Leuchttürme nach 60 Sekunden ein SOS mit deinem Ort. Das ist eine Schätzung aus GPS-Daten, kein Notrufdienst.\n\nErinnerungen: Deine eigenen Wege bleiben nur auf diesem iPhone, für „Heute vor einem Jahr“. Wetter: Die App fragt Apple Wetter mit den auf etwa 1 km gerundeten Orten, ohne Namen.")
                }

                if model.sharesTrips {
                    Section {
                        if model.myCars.isEmpty {
                            Text("Noch keine. Sag nach einer Fahrt „Ich bin gefahren“, während dein iPhone per Bluetooth mit dem Auto verbunden war, dann merkt es sich das Auto.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.myCars, id: \.self) { car in
                            Label(car, systemImage: "car.fill")
                        }
                        .onDelete { offsets in
                            for car in offsets.map({ model.myCars[$0] }) { model.removeCar(car) }
                        }
                    } header: {
                        Text("Meine Autos")
                    } footer: {
                        Text("Ist dein iPhone bei einer Fahrt mit CarPlay oder per Bluetooth mit einem dieser Autos verbunden, vermutet die App, dass du gefahren bist. Fahrt ihr zu mehreren, zählt in der Bestenliste nur die Fahrt des Fahrers. Den Namen des Autos sehen deine Leuchttürme bei der Fahrt, Ende-zu-Ende-verschlüsselt.")
                    }
                }

                Section {
                    if let client = model.client {
                        LabeledContent("Sicherheitscode") {
                            Text(client.safetyCode).font(.body.monospaced())
                        }
                    }
                    if !model.isSimulation {
                        Toggle("Schlüssel nur auf diesem Gerät", isOn: Binding(
                            get: { model.keysOnDeviceOnly },
                            set: { model.setKeysOnDeviceOnly($0) }
                        ))
                    }
                } header: {
                    Text("Dieses Gerät")
                } footer: {
                    Text(model.keysOnDeviceOnly
                        ? "Deine Schlüssel liegen nur auf diesem Gerät. Ein neues iPhone oder iPad braucht neue Einladungen."
                        : "Deine Schlüssel reisen mit dem iCloud-Schlüsselbund (von Apple Ende-zu-Ende-verschlüsselt) auf deine anderen Geräte. So funktionieren iPad und ein neues iPhone sofort. Wer es strenger will, schaltet „nur auf diesem Gerät“ ein.")
                }

                Section {
                    ForEach(model.pairedTVs) { tv in
                        LabeledContent {
                            Text("seit \(tv.added, format: .dateTime.day().month().year())")
                        } label: {
                            Label("Apple TV", systemImage: "appletv")
                        }
                        .swipeActions {
                            Button("Trennen", role: .destructive) { Task { await model.unpairTV(tv.id) } }
                        }
                    }
                } header: {
                    Text("Apple TV")
                } footer: {
                    Text("Öffne Leuchtturm auf dem Apple TV und scanne den Code mit der Kamera deines iPhones. Das Apple TV zeigt dann die Karte, Ende-zu-Ende-verschlüsselt über deine eigene iCloud. Es braucht dieselbe iCloud wie du und bekommt keine Schlüssel deiner Leuchttürme.")
                }

                Section {
                    Text("Leuchtturm speichert in iCloud (Apple). Namen von Leuchttürmen und Personen sowie Standorte werden vorher auf dem iPhone verschlüsselt, Apple kann sie nicht lesen. Apple sieht aber, welche iCloud-Konten zusammen in einem Leuchtturm sind und wann Daten geschrieben werden. Die Daten liegen in Apples Rechenzentren, nicht zwingend in der EU. Die Karte selbst kommt von Apple Karten: Beim Laden sieht Apple, welchen Kartenausschnitt du ansiehst, aber nicht, wer wo ist.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Wo liegen meine Daten?")
                }

                Section {
                    Button("Alle meine Daten löschen", role: .destructive) { confirmDelete = true }
                    Button("Nur dieses Gerät zurücksetzen", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Löschen entfernt deine eigenen Leuchttürme für alle, verlässt alle anderen und löscht deine Schlüssel. Das lässt sich nicht rückgängig machen.")
                }

                #if DEBUG
                Section {
                    if model.isSimulation {
                        Button("Simulation beenden", systemImage: "xmark.circle") {
                            model.endSimulation()
                            dismiss()
                        }
                    } else {
                        Button("Simulation starten", systemImage: "testtube.2") {
                            model.startSimulation()
                            dismiss()
                        }
                        Button("iCloud-Schema anlegen", systemImage: "square.stack.3d.up") {
                            Task { schemaCreated = await model.createCloudSchema() }
                        }
                        if schemaCreated {
                            Label("Alle Datentypen sind in Development angelegt.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                } header: {
                    Text("Entwicklung")
                } footer: {
                    Text("Nur in Test-Builds. Die Simulation nutzt weder iCloud noch die echten Schlüssel dieses Geräts, deine echten Daten bleiben unberührt.")
                }
                #endif

                Section {
                    Link(destination: AppInfo.privacyPolicy) {
                        Label("Datenschutzerklärung", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://github.com/Tim-Schaller/Leuchtturm")!) {
                        Label("Quellcode auf GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .onAppear { name = model.displayName }
            .sheet(isPresented: $editingProfile) { ProfileEditor() }
            .confirmationDialog("Wirklich alles löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Alles löschen", role: .destructive) {
                    Task {
                        await model.deleteAllData()
                        if model.phase == .onboarding { dismiss() }
                    }
                }
            }
            .confirmationDialog("Nur dieses Gerät zurücksetzen?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Zurücksetzen", role: .destructive) {
                    model.resetLocal()
                    dismiss()
                }
            } message: {
                Text("Löscht die Schlüssel auf diesem iPhone. Deine Leuchttürme in iCloud bleiben bestehen, du kannst sie danach aber nicht mehr lesen und brauchst neue Einladungen.")
            }
        }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }

    private func saveName() {
        guard !saving else { return }
        saving = true
        let value = name
        Task {
            _ = await model.changeDisplayName(value)
            saving = false
        }
    }
}
