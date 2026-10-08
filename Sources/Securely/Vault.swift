import Foundation
import CryptoKit
import Security
import AppKit

enum Kind: String, Codable, CaseIterable, Identifiable {
    case folder, file, app, apiKey, note
    var id: String { rawValue }
    var label: String {
        switch self {
        case .folder: "Folders"; case .file: "Files"; case .app: "Apps"
        case .apiKey: "API Keys"; case .note: "Notes"
        }
    }
    var symbol: String {
        switch self {
        case .folder: "folder.fill"; case .file: "doc.fill"; case .app: "app.fill"
        case .apiKey: "key.fill"; case .note: "note.text"
        }
    }
}

struct Item: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: Kind
    var name: String
    /// path for folder/file/app, secret for apiKey, text for note
    var value: String
    var created = Date()
}

enum KeyStore {
    static let service = "ai.securely.vault", account = "master"

    /// Prefer a biometry-bound data-protection keychain item (needs a properly
    /// signed app). Falls back to the login keychain, still gated by Touch ID in-app.
    static func store(_ key: SymmetricKey) -> String {
        let data = key.withUnsafeBytes { Data($0) }
        delete()
        if let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                    .biometryCurrentSet, nil) {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecValueData as String: data, kSecAttrAccessControl as String: ac,
                                    kSecUseDataProtectionKeychain as String: true]
            if SecItemAdd(q as CFDictionary, nil) == errSecSuccess { return "hardware" }
        }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(q as CFDictionary, nil)
        return "gated"
    }

    static func load(mode: String) -> SymmetricKey? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if mode == "hardware" { q[kSecUseDataProtectionKeychain as String] = true }
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return SymmetricKey(data: d)
    }

    static func delete() {
        for dp in [true, false] {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                           kSecAttrAccount as String: account,
                           kSecUseDataProtectionKeychain as String: dp] as CFDictionary)
        }
    }
}

@MainActor
final class VaultStore: ObservableObject {
    @Published var items: [Item] = []
    @Published var unlocked = false
    @Published var error: String?
    @Published var agentAccess = false

    private var key: SymmetricKey?
    private var idleTimer: Timer?
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Securely", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("vault.enc")
    }()

    var enrolled: Bool { FileManager.default.fileExists(atPath: url.path) }
    var protectionMode: String { UserDefaults.standard.string(forKey: "keyMode") ?? "gated" }

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }

    /// First run: scan the finger, then create the master key and an empty vault.
    func enroll() async {
        do {
            try await Auth.authenticate(reason: "Scan your finger to set it as your Securely login")
            let k = SymmetricKey(size: .bits256)
            UserDefaults.standard.set(KeyStore.store(k), forKey: "keyMode")
            key = k; items = []
            try save()
            open()
        } catch { self.error = error.localizedDescription }
    }

    func unlock() async {
        do {
            try await Auth.authenticate(reason: "Unlock Securely")
            guard let k = KeyStore.load(mode: protectionMode) else {
                error = "Vault key missing from Keychain"; return
            }
            let blob = try Data(contentsOf: url)
            let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: blob), using: k)
            items = try JSONDecoder().decode([Item].self, from: plain)
            key = k
            open()
        } catch { self.error = error.localizedDescription }
    }

    private func open() {
        unlocked = true; error = nil; touch()
    }

    func lock() {
        Share.cleanup(); unlocked = false; agentAccess = false; items = []; key = nil; idleTimer?.invalidate()
    }

    /// Call on user activity; auto-locks after 5 idle minutes.
    func touch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.lock() }
        }
    }

    func save() throws {
        guard let key else { return }
        let plain = try JSONEncoder().encode(items)
        let sealed = try AES.GCM.seal(plain, using: key).combined!
        try sealed.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Folder items define what the assistant and agents may read, so refuse "/", home, and other huge roots.
    static func tooBroad(_ path: String) -> Bool {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/", "/Users", "/Volumes", "/System", "/Library", "/private", "/etc", home, home + "/Library"].contains(p)
    }

    func add(_ item: Item) {
        if item.kind == .folder && Self.tooBroad(item.value) { error = "That folder is too broad; pick a specific folder."; return }
        items.append(item); persist()
    }
    func remove(_ item: Item) { items.removeAll { $0.id == item.id }; persist() }
    private func persist() { do { try save() } catch { self.error = error.localizedDescription }; touch() }

    /// Per-secret re-auth: reading a secret always needs a fresh fingerprint.
    func secret(for item: Item, reason: String) async -> String? {
        do { try await Auth.authenticate(reason: reason); return item.value }
        catch { self.error = error.localizedDescription; return nil }
    }

    /// Roots the browser and the agent may read: folders the user added to the vault.
    var allowedRoots: [String] {
        items.filter { $0.kind == .folder }.map { URL(fileURLWithPath: $0.value).resolvingSymlinksInPath().path }
    }
    func isAllowed(_ path: String) -> Bool {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return allowedRoots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }
}

extension VaultStore {
    var supportDir: URL { url.deletingLastPathComponent() }
    func seal(_ d: Data) -> Data? { key.flatMap { try? AES.GCM.seal(d, using: $0).combined } }
    func unseal(_ d: Data) -> Data? {
        guard let key, let box = try? AES.GCM.SealedBox(combined: d) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
