import Foundation
import Observation
import AppKit
import TunnelCore

@MainActor @Observable final class AppModel {
    var profiles: [VPNProfile]
    var selection: UUID?
    var draft = VPNProfile() { didSet { scheduleAutosave() } }
    var secrets = ProfileSecrets() { didSet { scheduleAutosave() } }
    var rememberSecrets = true { didSet { scheduleAutosave() } }
    var notice: String?
    private(set) var persistenceError: String?
    let connection = ConnectionController()
    private var inMemorySecrets: [UUID: ProfileSecrets] = [:]
    private var profilesWithoutSecrets: Set<UUID>
    private let profileStore: ProfileStore
    private let secretStore: any ProfileSecretStorage
    private var isLoading = true
    @ObservationIgnored private var autosave: Task<Void, Never>?

    var openConnectAddress: String {
        get {
            if draft.server.contains("?") || secrets.camouflage.isEmpty { return draft.server }
            return draft.server + "?" + secrets.camouflage
        }
        set {
            draft.server = newValue
            // The complete address replaces the previous secret, including when removed.
            secrets.camouflage = ""
            secrets.serverInput = nil
        }
    }

    init(profileStore: ProfileStore = ProfileStore(), secretStore: any ProfileSecretStorage = SecretStore(),
         arguments: [String] = CommandLine.arguments) {
        self.profileStore = profileStore
        self.secretStore = secretStore
        let document = profileStore.load()
        profiles = document.profiles
        profilesWithoutSecrets = document.profilesWithoutSecrets
        let args = arguments
        if let index = args.firstIndex(of: "--seed"), args.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: args[index + 1])
            if let data = try? Data(contentsOf: url), let seed = try? JSONDecoder().decode(TunnelRequest.self, from: data) {
                var profile = seed.profile
                if let endpoint = try? VPNEndpoint(server: profile.server, camouflage: seed.secrets.camouflage) {
                    profile.server = endpoint.baseURL
                }
                profiles.removeAll { $0.id == profile.id }; profiles.insert(profile, at: 0)
                inMemorySecrets[profile.id] = seed.secrets
            }
            try? FileManager.default.removeItem(at: url)
        }
        if profiles.isEmpty { profiles = [VPNProfile(name: "Мой ocserv")] }
        let selected = document.selectedProfile.flatMap { id in profiles.first(where: { $0.id == id })?.id }
        select(selected ?? profiles[0].id)
        isLoading = false
    }
    func select(_ id: UUID?) {
        guard let id, profiles.contains(where: { $0.id == id }) else { return }
        if !isLoading {
            if draft.id == id { return }
            guard save(showNotice: false) else { selection = draft.id; return }
        }
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        let wasLoading = isLoading
        isLoading = true
        selection = id; draft = profile
        connection.resetProfileResult()
        let saved = secretStore.load(id)
        secrets = inMemorySecrets[id] ?? saved ?? ProfileSecrets()
        if let serverInput = secrets.serverInput { draft.server = serverInput }
        rememberSecrets = !profilesWithoutSecrets.contains(id)
        notice = nil
        isLoading = wasLoading
        if !isLoading { persistSelection() }
    }
    func add(_ kind: VPNProtocol) {
        guard !connection.locked else { return }
        guard save(showNotice: false) else { return }
        let profile = VPNProfile(name: kind == .openConnect ? "Новый ocserv" : kind.title, kind: kind)
        profiles.append(profile); select(profile.id)
        _ = save(showNotice: false)
    }
    private func scheduleAutosave() {
        guard !isLoading else { return }
        autosave?.cancel()
        autosave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            _ = self?.save(showNotice: false)
        }
    }
    private func persistSelection() {
        do {
            try profileStore.save(.init(profiles: profiles, selectedProfile: draft.id,
                                        profilesWithoutSecrets: profilesWithoutSecrets))
            persistenceError = nil
        } catch { persistenceError = "Не удалось сохранить настройки: \(error.localizedDescription)" }
    }
    @discardableResult func save(showNotice: Bool = true) -> Bool {
        autosave?.cancel(); autosave = nil
        do {
            // Normalize the stored copy so editing the URL does not move the cursor.
            var profile = draft
            var savedSecrets = secrets
            savedSecrets.serverInput = nil
            if draft.kind == .openConnect && !draft.server.isEmpty {
                if let endpoint = try? VPNEndpoint(server: draft.server, camouflage: secrets.camouflage) {
                    profile.server = endpoint.baseURL; savedSecrets.camouflage = endpoint.secret
                } else {
                    // Saving a draft must work before it is valid enough to connect.
                    profile.server = ""
                    savedSecrets.serverInput = draft.server
                }
            }
            if rememberSecrets {
                try secretStore.save(savedSecrets, id: profile.id)
                profilesWithoutSecrets.remove(profile.id)
            } else {
                try secretStore.delete(profile.id)
                profilesWithoutSecrets.insert(profile.id)
            }
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
            inMemorySecrets[profile.id] = savedSecrets
            try profileStore.save(.init(profiles: profiles, selectedProfile: profile.id,
                                        profilesWithoutSecrets: profilesWithoutSecrets))
            persistenceError = nil
            if showNotice { notice = "Профиль сохранён." }
            return true
        } catch { persistenceError = "Не удалось сохранить настройки: \(error.localizedDescription)"; return false }
    }
    func deleteSelected() {
        guard !connection.locked else { return }
        let id = draft.id
        do { try secretStore.delete(id) }
        catch { persistenceError = error.localizedDescription; return }
        autosave?.cancel(); autosave = nil
        profiles.removeAll { $0.id == id }; inMemorySecrets.removeValue(forKey: id)
        profilesWithoutSecrets.remove(id)
        if profiles.isEmpty { profiles = [VPNProfile(name: "Мой ocserv")] }
        isLoading = true
        select(profiles[0].id)
        isLoading = false
        _ = save(showNotice: false)
    }
    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = draft.kind == .amneziaWG ? "Выберите конфигурацию AmneziaWG" : "Выберите конфигурацию Xray"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 256_000 else { throw VPNError("Файл слишком большой.") }
            secrets.configuration = try String(contentsOf: url, encoding: .utf8)
            if draft.kind == .xray, let name = try? XrayConfiguration(secrets.configuration).displayName, !name.isEmpty { draft.name = name }
            notice = "Конфигурация загружена. Нажмите «Проверить»."
        } catch { notice = error.localizedDescription }
    }
    func connect() { if save() { connection.connect(profile: draft, secrets: secrets) } }
    func check() { connection.check(profile: draft, secrets: secrets) }
}
