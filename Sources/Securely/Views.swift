import SwiftUI
import AppKit

struct LockView: View {
    @EnvironmentObject var vault: VaultStore
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "touchid").font(.system(size: 84, weight: .thin)).foregroundStyle(.white)
            Text("Securely").font(.system(size: 30, weight: .semibold))
            Text(vault.enrolled ? "Touch the sensor to unlock" : "Scan your finger to set it as your login")
                .foregroundStyle(.secondary)
            Button(vault.enrolled ? "Unlock" : "Scan finger & create vault") {
                Task { vault.enrolled ? await vault.unlock() : await vault.enroll() }
            }
            .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black).controlSize(.large)
            if vault.enrolled { Text(vault.protectionMode == "hardware" ? "Key: hardware-bound" : "Key: Touch ID gated")
                .font(.caption2).foregroundStyle(.secondary) }
            if let m = Auth.biometricsAvailable() { Text(m).font(.caption).foregroundStyle(.orange) }
            if let e = vault.error { Text(e).font(.caption).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        .task { if vault.enrolled { await vault.unlock() } }
    }
}

enum Side: Hashable { case all, kind(Kind) }

struct MainView: View {
    @EnvironmentObject var vault: VaultStore
    @State private var side: Side = .all
    private var filter: Kind? { if case .kind(let k) = side { return k }; return nil }
    @State private var selection: Item?
    @State private var search = ""
    @State private var adding = false
    @State private var showAI = true
    @State private var showAgents = false
    @State private var spot: [String] = []
    @State private var sem: [(Chunk, Float)] = []
    @EnvironmentObject var rag: RAGIndex
    @EnvironmentObject var agent: Agent

    var shown: [Item] {
        vault.items.filter { (filter == nil || $0.kind == filter) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $side) {
                Label("All", systemImage: "lock.shield.fill").tag(Side.all)
                ForEach(Kind.allCases) { k in Label(k.label, systemImage: k.symbol).tag(Side.kind(k)) }
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    List(shown, selection: $selection) { item in
                        Label(item.name, systemImage: item.kind.symbol).tag(item)
                            .contextMenu { Button("Remove", role: .destructive) { vault.remove(item); selection = nil } }
                    }
                    .scrollContentBackground(.hidden)
                    if !search.isEmpty && (!spot.isEmpty || !sem.isEmpty) {
                        Divider()
                        List {
                            if !sem.isEmpty { Section("Semantic matches") {
                                ForEach(sem, id: \.0.id) { c, score in
                                    VStack(alignment: .leading) {
                                        Text(c.source).font(.caption.bold()).lineLimit(1).truncationMode(.head)
                                        Text(c.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.help(String(format: "similarity %.2f", score))
                                }
                            } }
                            if !spot.isEmpty { Section("Spotlight") {
                                ForEach(spot, id: \.self) { p in
                                    Text(p).font(.caption).lineLimit(1).truncationMode(.head)
                                        .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                                }
                            } }
                        }.scrollContentBackground(.hidden).frame(maxHeight: 220)
                    }
                    Divider()
                    if let item = selection { DetailView(item: item).id(item.id).frame(height: 380) }
                }
                if showAI { AgentView().frame(minWidth: 300, idealWidth: 340) }
            }
        }
        .searchable(text: $search)
        .toolbar {
            ToolbarItemGroup {
                Button { adding = true } label: { Image(systemName: "plus") }
                Button { showAI.toggle() } label: { Image(systemName: "sparkles") }
                Button { showAgents = true } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                Button { vault.lock() } label: { Image(systemName: "lock.fill") }
            }
        }
        .sheet(isPresented: $adding) { AddView() }
        .sheet(isPresented: $showAgents) { AgentsPanel() }
        .task { await rag.reindex() }
        .task(id: search) {
            guard search.count >= 2 else { spot = []; sem = []; return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            spot = await Spotlight.search(search, roots: vault.allowedRoots)
            sem = search.count >= 3 ? await rag.search(search, k: 4) : []
        }
        .onDisappear { rag.clear(); agent.reset() }
        .onChange(of: selection) { _, _ in vault.touch() }
        .onChange(of: side) { _, _ in selection = nil; vault.touch() }
    }
}

struct DetailView: View {
    @EnvironmentObject var vault: VaultStore
    let item: Item
    @State private var revealed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.name).font(.title2.bold())
            switch item.kind {
            case .apiKey:
                Text(revealed ?? String(repeating: "•", count: 24)).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Button(revealed == nil ? "Reveal (fingerprint)" : "Hide") {
                    Task { revealed = revealed == nil ? await vault.secret(for: item, reason: "Reveal \"\(item.name)\"") : nil }
                }
            case .note:
                ScrollView { Text(item.value).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                Button { if let u = Share.noteURL(item) { Task { await Share.airdrop([u]) } } } label: { Label("AirDrop", systemImage: "dot.radiowaves.left.and.right") }
            case .folder:
                FolderBrowser(root: item.value)
            case .file, .app:
                Text(item.value).foregroundStyle(.secondary)
                QuickLookView(url: URL(fileURLWithPath: item.value)).frame(minHeight: 120)
                Button { Task { await Share.airdrop([URL(fileURLWithPath: item.value)]) } } label: { Label("AirDrop", systemImage: "dot.radiowaves.left.and.right") }
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: item.value)) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.value)]) }
            }
            Spacer(minLength: 0)
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AddView: View {
    @EnvironmentObject var vault: VaultStore
    @Environment(\.dismiss) var dismiss
    @State private var kind: Kind = .apiKey
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to Securely").font(.title2.bold())
            Picker("Type", selection: $kind) { ForEach(Kind.allCases) { Text($0.label).tag($0) } }.pickerStyle(.segmented)
            TextField("Name", text: $name)
            switch kind {
            case .apiKey: SecureField("Secret", text: $value)
            case .note: TextEditor(text: $value).frame(height: 100)
            default:
                HStack {
                    TextField("Path", text: $value)
                    Button("Choose…") { choose() }
                }
            }
            if kind == .folder && VaultStore.tooBroad(value) {
                Text("Too broad — the assistant and agents can read everything inside vault folders. Pick a specific folder.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { vault.add(Item(kind: kind, name: name, value: value)); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || value.isEmpty || (kind == .folder && VaultStore.tooBroad(value)))
            }
        }
        .padding(20).frame(width: 460).preferredColorScheme(.dark)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = kind == .folder || kind == .app
        p.canChooseFiles = kind != .folder
        if kind == .app { p.directoryURL = URL(fileURLWithPath: "/Applications") }
        if p.runModal() == .OK, let u = p.url {
            value = u.path; if name.isEmpty { name = u.deletingPathExtension().lastPathComponent }
        }
    }
}

struct AgentView: View {
    @EnvironmentObject var agent: Agent
    @EnvironmentObject var rag: RAGIndex
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "sparkles"); Text("Assistant (local)").bold(); Spacer()
                Picker("", selection: $agent.model) { ForEach(agent.models, id: \.self) { Text($0).tag($0) } }
                    .labelsHidden().frame(width: 140)
            }.padding(10)
            HStack {
                Text(rag.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(rag.busy ? "Indexing…" : "Reindex") { Task { await rag.reindex() } }.controlSize(.small).disabled(rag.busy)
            }.padding(.horizontal, 10).padding(.bottom, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(agent.lines) { l in
                            Text(l.role == "tool" ? "⚙︎ \(l.text)" : l.text)
                                .font(l.role == "tool" ? .caption.monospaced() : .body)
                                .foregroundStyle(l.role == "error" ? .red : l.role == "tool" ? .secondary : .primary)
                                .padding(8).frame(maxWidth: .infinity, alignment: l.role == "you" ? .trailing : .leading)
                                .background(l.role == "you" ? Color.white.opacity(0.12) : Color.white.opacity(0.04),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .id(l.id)
                        }
                    }.padding(10)
                }
                .onChange(of: agent.lines.count) { _, _ in
                    if let last = agent.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                TextField(agent.models.isEmpty ? "Ollama not reachable on :11434" : "Ask about your vault…", text: $input)
                    .onSubmit(submit).textFieldStyle(.roundedBorder)
                if agent.busy { ProgressView().controlSize(.small) }
            }.padding(10)
        }
        .background(Color(white: 0.04))
        .task { await agent.refreshModels() }
    }

    private func submit() {
        let t = input.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        input = ""; Task { await agent.send(t) }
    }
}
