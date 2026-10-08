import SwiftUI
import AppKit
import QuickLookUI

// MARK: Spotlight — metadata-index search confined to vault folders (no system-wide indexing of vault data)
enum Spotlight {
    static func search(_ q: String, roots: [String]) async -> [String] {
        let query = q.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !query.hasPrefix("-"), !roots.isEmpty else { return [] }
        return await Task.detached {
            var out = Set<String>()
            for r in roots {
                let p = Process(); let pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                p.arguments = ["-onlyin", r, query]
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { continue }
                let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
                String(decoding: d, as: UTF8.self).split(separator: "\n").prefix(50).forEach { out.insert(String($0)) }
            }
            return out.sorted()
        }.value
    }
}

// MARK: Quick Look
struct QuickLookView: NSViewRepresentable {
    let url: URL?
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal)!; v.autostarts = true; return v
    }
    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url.map { $0 as NSURL } }
    }
    static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
}

// MARK: AirDrop — fingerprint first, never for API keys
enum Share {
    @MainActor static func airdrop(_ urls: [URL]) async {
        do { try await Auth.authenticate(reason: "Share via AirDrop") } catch { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }
    static var dir: URL { FileManager.default.temporaryDirectory.appendingPathComponent("securely-share", isDirectory: true) }
    /// Notes are written to a temp file for AirDrop; remove them when the vault locks.
    static func cleanup() { try? FileManager.default.removeItem(at: dir) }
    static func noteURL(_ item: Item) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let u = dir.appendingPathComponent(item.name.replacingOccurrences(of: "/", with: "-") + ".txt")
        do { try item.value.write(to: u, atomically: true, encoding: .utf8); return u } catch { return nil }
    }
}

// MARK: Folder browser with Quick Look pane and AirDrop
struct FolderBrowser: View {
    @EnvironmentObject var vault: VaultStore
    let root: String
    @State private var path = ""
    @State private var sel: URL?

    var current: String { path.isEmpty ? root : path }
    var entries: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: current), includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button { goUp() } label: { Image(systemName: "chevron.left") }.disabled(current == root)
                Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer()
                if let s = sel {
                    Button { Task { await Share.airdrop([s]) } } label: { Label("AirDrop", systemImage: "dot.radiowaves.left.and.right") }
                }
            }
            HSplitView {
                List(entries, id: \.self, selection: $sel) { url in
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    Label(url.lastPathComponent, systemImage: isDir ? "folder.fill" : "doc")
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if isDir { path = url.path; sel = nil } else { NSWorkspace.shared.open(url) } }
                }
                .scrollContentBackground(.hidden).frame(minWidth: 180)
                QuickLookView(url: sel).frame(minWidth: 200)
            }
        }
    }

    private func goUp() {
        let up = (current as NSString).deletingLastPathComponent
        path = vault.isAllowed(up) && up.count >= root.count ? up : root; sel = nil
    }
}

// MARK: Agents panel (MCP)
struct AgentsPanel: View {
    @EnvironmentObject var vault: VaultStore
    @EnvironmentObject var bridge: BridgeServer
    @Environment(\.dismiss) var dismiss
    private var bin: String { Bundle.main.bundlePath + "/Contents/MacOS/securely-mcp" }
    private var cmd: String { "claude mcp add securely -- \"\(bin)\"" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent-to-agent (MCP)").font(.title2.bold())
            Toggle("Allow other agents to query this vault while it is unlocked", isOn: $vault.agentAccess)
            Text("Other agents can search, semantically search, and read files inside vault folders. API keys are only released after you approve each request with your fingerprint. Access switches off whenever the vault locks.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Connect Claude Code").bold()
            Text("Key protection: " + (vault.protectionMode == "hardware" ? "hardware-bound (Touch ID enforced by macOS)" : "Touch ID gated (weaker; see SECURITY.md)")).font(.caption).foregroundStyle(.secondary)
            Text(cmd).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(8).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            Button("Copy command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string) }
            Text("Activity").bold()
            List(bridge.log.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
                .scrollContentBackground(.hidden).frame(height: 140)
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent) }
        }
        .padding(20).frame(width: 560).preferredColorScheme(.dark)
    }
}
