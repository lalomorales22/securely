import Foundation
import Darwin

/// Local Unix-socket endpoint (0600, user-only) that the `securely-mcp` stdio server talks to.
@MainActor
final class BridgeServer: ObservableObject {
    @Published var log: [String] = []
    private let vault: VaultStore
    private let rag: RAGIndex
    private var secretPromptActive = false
    private var denials = 0

    init(vault: VaultStore, rag: RAGIndex) { self.vault = vault; self.rag = rag }

    private func note(_ s: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    func start() {
        let path = vault.supportDir.appendingPathComponent("agent.sock").path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard rc == 0, listen(fd, 8) == 0 else { note("bridge failed to start"); return }
        chmod(path, 0o600)
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                Thread.detachNewThread { self?.serve(c) }
            }
        }
    }

    /// Real process identity (kernel-reported), not the self-declared MCP client name.
    private nonisolated static func describe(_ pid: pid_t) -> String {
        func path(_ p: pid_t) -> String {
            var b = [CChar](repeating: 0, count: 4096)
            return proc_pidpath(p, &b, UInt32(b.count)) > 0 ? String(cString: b) : "pid \(p)"
        }
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let parent = n > 0 ? path(pid_t(info.pbi_ppid)) : "unknown parent"
        return "\((path(pid) as NSString).lastPathComponent) launched by \((parent as NSString).lastPathComponent)"
    }

    private nonisolated func serve(_ fd: Int32) {
        defer { close(fd) }
        // Only the same macOS user may talk to the bridge (socket is also 0600 in a 0700 dir).
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var pid: pid_t = 0; var plen = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, 0 /* SOL_LOCAL */, 0x002 /* LOCAL_PEERPID */, &pid, &plen)
        let origin = Self.describe(pid)
        var buf = Data(); var tmp = [UInt8](repeating: 0, count: 65536)
        while !buf.contains(10) {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 || buf.count > 1_000_000 { break }
            buf.append(contentsOf: tmp[0..<n])
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: buf)) as? [String: Any] else { return }
        var obj2 = obj; obj2["origin"] = origin
        let sem = DispatchSemaphore(value: 0)
        var out = ""
        Task { @MainActor in out = await self.handle(obj2); sem.signal() }
        sem.wait()
        let data = (try? JSONSerialization.data(withJSONObject: ["text": out])) ?? Data()
        _ = (data + Data([10])).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func handle(_ req: [String: Any]) async -> String {
        let tool = req["tool"] as? String ?? ""
        let a = req["args"] as? [String: Any] ?? [:]
        let declared = String((req["client"] as? String ?? "unknown").filter { $0.isLetter || $0.isNumber || " -_.".contains($0) }.prefix(40))
        let client = "\(declared) (\(req["origin"] as? String ?? "unknown process"))"
        let s = { (k: String) in (a[k] as? String) ?? "" }
        guard vault.unlocked else { return "Securely is locked. Ask the user to unlock it." }
        guard vault.agentAccess else { return "Agent access is off. The user must enable it in Securely > Agents." }
        note("\(client) → \(tool)")
        switch tool {
        case "search_vault":
            let q = s("query").lowercased()
            let hits = vault.items.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.kind.rawValue.lowercased().contains(q) }
            return hits.isEmpty ? "no matches" : hits.map {
                "\($0.kind.rawValue): \($0.name)" + ($0.kind == .apiKey || $0.kind == .note ? "" : " -> \($0.value)")
            }.joined(separator: "\n")
        case "semantic_search":
            let hits = await rag.search(s("query"), k: 5)
            return hits.isEmpty ? "no results (index empty or nothing relevant)" :
                hits.map { "[\(String(format: "%.2f", $0.1))] \($0.0.source)\n\($0.0.text)" }.joined(separator: "\n---\n")
        case "spotlight_search":
            let r = await Spotlight.search(s("query"), roots: vault.allowedRoots)
            return r.isEmpty ? "no matches" : r.prefix(30).joined(separator: "\n")
        case "list_folder":
            guard vault.isAllowed(s("path")) else { return "denied: outside vault folders" }
            return ((try? FileManager.default.contentsOfDirectory(atPath: s("path"))) ?? []).sorted().prefix(200).joined(separator: "\n")
        case "read_text_file":
            guard vault.isAllowed(s("path")) else { return "denied: outside vault folders" }
            guard let h = FileHandle(forReadingAtPath: s("path")) else { return "cannot open" }
            defer { try? h.close() }
            return String(data: (try? h.read(upToCount: 20_000)) ?? Data(), encoding: .utf8) ?? "not UTF-8 text"
        case "get_secret":
            guard let it = vault.items.first(where: { $0.kind == .apiKey && $0.name.lowercased() == s("name").lowercased() })
            else { return "no such API key" }
            guard !secretPromptActive else { return "another approval is already pending" }
            secretPromptActive = true; defer { secretPromptActive = false }
            guard let v = await vault.secret(for: it, reason: "\(client) requests API key \"\(it.name)\"") else {
                note("\(client) → get_secret \(it.name): DENIED"); denials += 1
                if denials >= 3 { vault.agentAccess = false; note("Agent access switched off after repeated denials") }
                return "user declined"
            }
            denials = 0
            note("\(client) → get_secret \(it.name): approved")
            return v
        default: return "unknown tool"
        }
    }
}
