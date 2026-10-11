import Foundation
import LeuchtturmCore
import Observation

/// App-wide state. Owns the client once setup is done.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case onboarding
        case ready
    }

    private enum Keys {
        static let displayName = "displayName"
        static let serverURL = "serverURL"
    }

    private(set) var phase: Phase
    private(set) var client: LeuchtturmClient? = nil
    private(set) var displayName: String
    private(set) var serverURL: URL?

    var circles: [CircleSummary] = []
    /// True after the first successful load, so the empty state does not flash.
    private(set) var hasLoadedCircles = false
    var isLoading = false
    var errorMessage: String?
    /// An invite opened via link or QR code, waiting for confirmation.
    var pendingInvite: InviteLink?

    private let defaults = UserDefaults.standard
    private let secrets = KeychainSecretStore()
    /// Registration is idempotent; doing it once per launch heals a restored
    /// iPhone (keys are not migrated, settings are) or a reset server.
    @ObservationIgnored private var registeredThisLaunch = false

    init() {
        let name = defaults.string(forKey: Keys.displayName) ?? ""
        let server = defaults.string(forKey: Keys.serverURL).flatMap(URL.init(string:))
        displayName = name
        serverURL = server
        if let server, !name.isEmpty,
           let client = try? LeuchtturmClient(serverURL: server, secrets: secrets, displayName: name) {
            self.client = client
            phase = .ready
        } else {
            phase = .onboarding
        }
    }

    // MARK: Setup

    /// Creates the device keys (if needed), registers with the server and
    /// stores the settings. Returns false and sets `errorMessage` on failure.
    func setUp(name: String, server: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= LeuchtturmClient.maxNameLength else {
            errorMessage = "Bitte gib einen Namen mit höchstens \(LeuchtturmClient.maxNameLength) Zeichen ein."
            return false
        }
        guard let url = ServerAddress.parse(server) else {
            errorMessage = "Die Serveradresse ist ungültig. Erlaubt ist https:// (http:// nur im lokalen Netz)."
            return false
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try LeuchtturmClient(serverURL: url, secrets: secrets, displayName: trimmed)
            try await client.register()
            registeredThisLaunch = true
            defaults.set(trimmed, forKey: Keys.displayName)
            defaults.set(url.absoluteString, forKey: Keys.serverURL)
            self.client = client
            displayName = trimmed
            serverURL = url
            phase = .ready
            await refresh()
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    // MARK: Circles

    func refresh() async {
        guard let client else { return }
        do {
            if !registeredThisLaunch {
                try await client.register()
                registeredThisLaunch = true
            }
            circles = try await client.circles()
            hasLoadedCircles = true
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func createCircle(name: String) async -> String? {
        guard let client else { return nil }
        do {
            let id = try await client.createCircle(name: name)
            await refresh()
            return id
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    func join(_ link: InviteLink) async -> String? {
        guard let client else { return nil }
        do {
            let id = try await client.join(link)
            await refresh()
            return id
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    /// Runs a client operation and reports errors. Returns nil on failure.
    @discardableResult
    func run<T: Sendable>(_ operation: @Sendable (LeuchtturmClient) async throws -> T) async -> T? {
        guard let client else { return nil }
        do {
            return try await operation(client)
        } catch {
            errorMessage = Self.describe(error)
            return nil
        }
    }

    func handle(url: URL) {
        guard let link = InviteLink(url: url) else { return }
        pendingInvite = link
    }

    // MARK: Settings

    func changeDisplayName(_ name: String) async -> Bool {
        let ok = await run { try await $0.setDisplayName(name) } != nil
        if ok {
            displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(displayName, forKey: Keys.displayName)
        }
        return ok
    }

    /// Deletes the device on the server, then everything local.
    func deleteDevice() async {
        guard await run({ try await $0.deleteDevice() }) != nil else { return }
        resetLocal()
    }

    /// Wipes keys and settings on this device only (e.g. server gone).
    func resetLocal() {
        for account in (try? secrets.accounts()) ?? [] {
            try? secrets.delete(account)
        }
        defaults.removeObject(forKey: Keys.displayName)
        defaults.removeObject(forKey: Keys.serverURL)
        client = nil
        circles = []
        hasLoadedCircles = false
        registeredThisLaunch = false
        displayName = ""
        serverURL = nil
        phase = .onboarding
    }

    // MARK: Errors

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as APIError:
            switch error {
            case let .server(status, code, _):
                switch code {
                case "invalid_invite": return "Die Einladung ist ungültig, abgelaufen oder schon benutzt."
                case "not_found": return "Nicht gefunden. Vielleicht wurdest du aus dem Kreis entfernt."
                case "forbidden": return "Dafür fehlen dir die Rechte."
                case "conflict": return "Der Kreis hat sich gerade geändert. Bitte versuch es noch einmal."
                case "limit_reached": return "Ein Limit ist erreicht (zu viele Mitglieder oder offene Einladungen)."
                case "unknown_device", "unauthorized": return "Der Server kennt dieses Gerät nicht (mehr)."
                default: return "Serverfehler (\(status))."
                }
            case .invalidResponse: return "Der Server hat unerwartet geantwortet."
            case .invalidURL: return "Ungültige Adresse."
            }
        case let error as ClientError:
            switch error {
            case .missingCircleKey: return "Für diesen Kreis fehlt auf diesem Gerät der Schlüssel."
            case .notOwner: return "Das darf nur der Besitzer des Kreises."
            case .unknownMember: return "Dieses Mitglied gibt es nicht."
            case .differentServer: return "Die Einladung gehört zu einem anderen Server."
            case .invalidName: return "Namen müssen 1 bis \(LeuchtturmClient.maxNameLength) Zeichen lang sein."
            }
        case is ProtocolError:
            return "Die Daten konnten nicht entschlüsselt oder geprüft werden."
        case let error as URLError:
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Keine Internetverbindung."
            case .cannotFindHost, .cannotConnectToHost, .timedOut: return "Der Server ist nicht erreichbar."
            case .secureConnectionFailed, .serverCertificateUntrusted: return "Die sichere Verbindung zum Server ist fehlgeschlagen."
            default: return "Netzwerkfehler."
            }
        default:
            return "Unbekannter Fehler."
        }
    }
}
