import CoreImage.CIFilterBuiltins
import LeuchtturmCore
import SwiftUI
import UIKit

struct InviteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ref: CircleRef
    let circleName: String?

    @State private var validity: Validity = .day
    @State private var link: InviteLink?
    @State private var qrImage: UIImage?
    @State private var working = false

    enum Validity: Int64, CaseIterable, Identifiable {
        case hour = 3600
        case day = 86400
        case week = 604_800

        var id: Int64 { rawValue }
        var label: String {
            switch self {
            case .hour: "1 Stunde"
            case .day: "24 Stunden"
            case .week: "7 Tage"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let link {
                    Section {
                        if let image = qrImage {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240)
                                .padding()
                                .background(.white, in: .rect(cornerRadius: 16))
                                .frame(maxWidth: .infinity)
                                .accessibilityLabel("QR-Code der Einladung")
                        }
                        ShareLink(item: link.url, message: Text("Komm in meinen Leuchtturm-Kreis \(circleName ?? "")")) {
                            Label("Link teilen", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    } footer: {
                        Text("Wer diesen Link oder QR-Code hat, kann beitreten. Teile ihn nur privat, z. B. persönlich oder per verschlüsselter Nachricht.")
                    }
                    #if DEBUG
                    if model.isSimulation {
                        SimulatedRecipients(circleID: ref.circleID, link: link)
                    }
                    #endif
                } else {
                    Section {
                        Picker("Gültig für", selection: $validity) {
                            ForEach(Validity.allCases) { Text($0.label).tag($0) }
                        }
                    } footer: {
                        Text("Jeder mit dem Link kann beitreten, bis er abläuft. Neue Mitglieder siehst du in der Mitgliederliste und kannst sie jederzeit entfernen. Entfernst du jemanden, werden alle offenen Einladungen ungültig.")
                    }
                    Section {
                        Button(action: create) {
                            HStack {
                                Spacer()
                                if working { ProgressView() } else { Text("Einladung erstellen").bold() }
                                Spacer()
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(working)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("Einladen")
            .navigationBarTitleDisplayMode(.inline)
            .errorAlert()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func create() {
        working = true
        let seconds = validity.rawValue
        let ref = ref
        Task {
            if let created = await model.run({ try await $0.createInvite(for: ref, validFor: seconds) }) {
                qrImage = QRCode.image(for: created.url.absoluteString)
                link = created
            }
            working = false
        }
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
