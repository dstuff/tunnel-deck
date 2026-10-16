import Foundation
import Observation
import AppKit
import TunnelCore

@MainActor @Observable final class AppModel {
    var profiles: [VPNProfile]
    var selection: UUID?
    var draft = VPNProfile() { didSet { scheduleAutosave() } }
    var secrets = ProfileSecrets() { didSet { scheduleAutosave() } }
    var notice: String?
    private(set) var persistenceError: String?
    let connection: ConnectionController
    let switcher: ProfileSwitcher
    private var inMemorySecrets: [UUID: ProfileSecrets] = [:]
    private let profileStore: any ProfileStorage
    private var loadError: String?
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

    init(profileStore: any ProfileStorage = ProfileStore(),
         arguments: [String] = CommandLine.arguments) {
        let connection = ConnectionController()
        self.connection = connection
        switcher = ProfileSwitcher(connection: connection)
        self.profileStore = profileStore
        let document: ProfileStore.Document
        do { document = try profileStore.load() }
        catch {
            document = .init()
            loadError = error.localizedDescription
            persistenceError = error.localizedDescription
        }
        profiles = document.profiles
        for profile in profiles {
            inMemorySecrets[profile.id] = document.secrets[profile.id.uuidString] ?? ProfileSecrets()
        }
        let args = arguments
        if loadError == nil, let index = args.firstIndex(of: "--seed"), args.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: args[index + 1])
            if let data = try? Data(contentsOf: url), let seed = try? JSONDecoder().decode(TunnelRequest.self, from: data) {
                var profile = seed.profile
                var seedSecrets = seed.secrets
                if let endpoint = try? VPNEndpoint(server: profile.server, camouflage: seedSecrets.camouflage) {
                    profile.server = endpoint.baseURL
                    seedSecrets.camouflage = endpoint.secret
                }
                profiles.removeAll { $0.id == profile.id }; profiles.insert(profile, at: 0)
                inMemorySecrets[profile.id] = seedSecrets
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
            guard persist(profiles, secrets: inMemorySecrets, selected: id) else { selection = draft.id; return }
        }
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        let wasLoading = isLoading
        isLoading = true
        selection = id; draft = profile
        connection.resetProfileResult()
        secrets = inMemorySecrets[id] ?? ProfileSecrets()
        if let serverInput = secrets.serverInput { draft.server = serverInput }
        notice = nil
        isLoading = wasLoading
    }
    func add(_ kind: VPNProtocol) {
        guard canManageProfiles else { return }
        guard save(showNotice: false) else { return }
        let profile = VPNProfile(name: kind == .openConnect ? "Новый ocserv" : kind.title, kind: kind)
        var updatedSecrets = inMemorySecrets
        updatedSecrets[profile.id] = ProfileSecrets()
        guard persist(profiles + [profile], secrets: updatedSecrets, selected: profile.id) else { return }
        activate(profile.id)
    }
    private func scheduleAutosave() {
        guard !isLoading else { return }
        autosave?.cancel()
        autosave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            _ = self?.save(showNotice: false)
        }
    }
    private func persist(_ updatedProfiles: [VPNProfile], secrets updatedSecrets: [UUID: ProfileSecrets],
                         selected: UUID) -> Bool {
        guard loadError == nil else { persistenceError = loadError; return false }
        var storedSecrets: [String: ProfileSecrets] = [:]
        var retainedSecrets: [UUID: ProfileSecrets] = [:]
        for profile in updatedProfiles {
            let value = updatedSecrets[profile.id] ?? ProfileSecrets()
            storedSecrets[profile.id.uuidString] = value
            retainedSecrets[profile.id] = value
        }
        do {
            try profileStore.save(.init(profiles: updatedProfiles, selectedProfile: selected,
                                        secrets: storedSecrets))
            profiles = updatedProfiles
            inMemorySecrets = retainedSecrets
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Не удалось сохранить настройки: \(error.localizedDescription)"
            return false
        }
    }
    private func activate(_ id: UUID) {
        isLoading = true
        select(id)
        isLoading = false
    }
    @discardableResult func save(showNotice: Bool = true) -> Bool {
        autosave?.cancel(); autosave = nil
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
        var updatedProfiles = profiles
        if let index = updatedProfiles.firstIndex(where: { $0.id == profile.id }) { updatedProfiles[index] = profile }
        var updatedSecrets = inMemorySecrets
        updatedSecrets[profile.id] = savedSecrets
        guard persist(updatedProfiles, secrets: updatedSecrets, selected: profile.id) else { return false }
        if showNotice { notice = "Профиль сохранён локально." }
        return true
    }
    func deleteSelected() {
        guard canManageProfiles, connection.activeProfile != draft.id else { return }
        let id = draft.id
        autosave?.cancel(); autosave = nil
        var updatedProfiles = profiles.filter { $0.id != id }
        var updatedSecrets = inMemorySecrets
        updatedSecrets.removeValue(forKey: id)
        if updatedProfiles.isEmpty { updatedProfiles = [VPNProfile(name: "Мой ocserv")] }
        let selected = updatedProfiles[0].id
        guard persist(updatedProfiles, secrets: updatedSecrets, selected: selected) else { return }
        activate(selected)
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
    var canManageProfiles: Bool { loadError == nil && !connection.state.busy && !switcher.isSwitching }
    var canConnectProfile: Bool {
        !switcher.isSwitching && (!connection.locked || connection.state == .connected)
    }

    func connectProfile(_ id: UUID) {
        guard canConnectProfile, profiles.contains(where: { $0.id == id }),
              connection.activeProfile != id else { return }
        guard save(showNotice: false) else { return }
        switcher.clearError()
        if connection.state == .connected {
            switcher.start(to: id) { [weak self] in self?.selectAndConnect(id) }
        } else {
            selectAndConnect(id)
        }
    }

    private func selectAndConnect(_ id: UUID) {
        select(id)
        guard draft.id == id else { return }
        connect()
    }

    func disconnect() {
        switcher.cancel()
        connection.disconnect()
    }

    func connect() {
        guard !switcher.isSwitching else { return }
        if save(showNotice: false) { connection.connect(profile: draft, secrets: secrets) }
    }

    func check() {
        guard !switcher.isSwitching, save(showNotice: false) else { return }
        connection.check(profile: draft, secrets: secrets)
    }

    @discardableResult
    func importConnection(_ imported: ConnectionImport, name: String, username: String,
                          password: String) -> Bool {
        guard canManageProfiles, save(showNotice: false) else { return false }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = VPNProfile(name: title.isEmpty ? imported.suggestedName : title,
                                 kind: imported.kind, server: imported.server,
                                 username: imported.kind == .openConnect ? username : "")
        var newSecrets = imported.secrets
        newSecrets.password = imported.kind == .openConnect ? password : ""
        var updatedSecrets = inMemorySecrets
        updatedSecrets[profile.id] = newSecrets
        guard persist(profiles + [profile], secrets: updatedSecrets, selected: profile.id) else { return false }
        activate(profile.id)
        notice = "Подключение добавлено и сохранено локально."
        return true
    }
}
