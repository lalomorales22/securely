import Foundation
import CryptoKit

struct Chunk: Codable, Identifiable {
    var id = UUID()
    var source: String      // file path or "note:Title"
    var stamp: String       // mtime / content hash, for incremental reindex
    var text: String
    var vec: Data           // normalized Float32 embedding
}

private struct IndexFile: Codable { var model: String; var chunks: [Chunk] }

/// Local semantic index over notes and text files in vault folders.
/// Embeddings come from Ollama (local) and are stored encrypted with the vault key.
@MainActor
final class RAGIndex: ObservableObject {
    @Published var chunks: [Chunk] = []
    @Published var status = "Index not built"
    @Published var busy = false
    var model: String { UserDefaults.standard.string(forKey: "embedModel") ?? "embeddinggemma" }
    private let vault: VaultStore
    private let base = URL(string: "http://127.0.0.1:11434")!
    nonisolated private static let exts: Set<String> = ["txt","md","markdown","swift","py","js","ts","tsx","jsx","json","yaml","yml",
        "toml","csv","log","html","css","c","h","m","mm","rs","go","java","sh","rb","sql","xml","tex","ini","conf"]

    init(vault: VaultStore) { self.vault = vault }

    func clear() { chunks = []; status = "Locked" }

    private var indexURL: URL { vault.supportDir.appendingPathComponent("index.enc") }

    // MARK: embedding
    private func embed(_ texts: [String]) async throws -> [Data] {
        var req = URLRequest(url: base.appendingPathComponent("api/embed"))
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        let (d, _) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        if let e = j?["error"] as? String { throw NSError(domain: "embed", code: 1, userInfo: [NSLocalizedDescriptionKey: e]) }
        guard let vs = j?["embeddings"] as? [[Double]], vs.count == texts.count else { throw URLError(.cannotParseResponse) }
        return vs.map { v in
            var f = v.map(Float.init)
            let n = sqrt(f.reduce(0) { $0 + $1 * $1 }); if n > 0 { f = f.map { $0 / n } }
            return f.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    private static func floats(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }

    // MARK: persistence
    private func loadFromDisk() {
        guard chunks.isEmpty, let blob = try? Data(contentsOf: indexURL), let plain = vault.unseal(blob),
              let f = try? JSONDecoder().decode(IndexFile.self, from: plain), f.model == model else { return }
        chunks = f.chunks
    }
    private func saveToDisk() {
        guard let plain = try? JSONEncoder().encode(IndexFile(model: model, chunks: chunks)),
              let sealed = vault.seal(plain) else { return }
        try? sealed.write(to: indexURL, options: .atomic)
    }

    // MARK: indexing
    private struct Source { let name: String; let stamp: String; let text: String }

    private static func chunk(_ s: String, size: Int = 900, overlap: Int = 150) -> [String] {
        let c = Array(s); if c.count <= size { return [s] }
        var out: [String] = []; var i = 0
        while i < c.count { out.append(String(c[i..<min(i + size, c.count)])); i += size - overlap }
        return out
    }


    nonisolated private static func scan(_ roots: [String]) -> [Source] {
        var out: [Source] = []
        for r in roots {
            guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: r),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let u = en.nextObject() as? URL {
                let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                guard rv?.isRegularFile == true, (rv?.fileSize ?? 0) < 300_000, exts.contains(u.pathExtension.lowercased()),
                      let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
                out.append(Source(name: u.path, stamp: "\(rv?.contentModificationDate?.timeIntervalSince1970 ?? 0)", text: t))
                if out.count >= 2000 { return out }
            }
        }
        return out
    }

    func reindex() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        loadFromDisk()
        status = "Scanning…"
        let roots = vault.allowedRoots
        let notes = vault.items.filter { $0.kind == .note }.map {
            Source(name: "note:\($0.name)", stamp: SHA256.hash(data: Data($0.value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined(), text: $0.value)
        }
        let files = await Task.detached { Self.scan(roots) }.value

        let all = notes + files
        let current = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.stamp) })
        chunks.removeAll { current[$0.source] != $0.stamp }               // drop deleted / changed
        let have = Set(chunks.map(\.source))
        let todo = all.filter { !have.contains($0.name) }
        var pending: [(Source, String)] = todo.flatMap { s in Self.chunk(s.text).map { (s, $0) } }
        var done = 0; let total = pending.count
        do {
            while !pending.isEmpty {
                status = "Embedding \(done)/\(total)…"
                let batch = Array(pending.prefix(16)); pending.removeFirst(batch.count)
                let vecs = try await embed(batch.map { "title: none | text: \($0.1)" })
                for (i, b) in batch.enumerated() {
                    chunks.append(Chunk(source: b.0.name, stamp: b.0.stamp, text: b.1, vec: vecs[i]))
                }
                done += batch.count
            }
            saveToDisk()
            status = "\(chunks.count) chunks · \(Set(chunks.map(\.source)).count) sources"
        } catch {
            saveToDisk()
            status = "Index error: \(error.localizedDescription)"
        }
    }

    // MARK: search
    func search(_ query: String, k: Int = 5) async -> [(Chunk, Float)] {
        loadFromDisk()
        guard !chunks.isEmpty, let qv = try? await embed(["task: search result | query: \(query)"]).first else { return [] }
        let q = Self.floats(qv)
        return chunks.map { c -> (Chunk, Float) in
            let v = Self.floats(c.vec); var s: Float = 0
            for i in 0..<min(q.count, v.count) { s += q[i] * v[i] }
            return (c, s)
        }.sorted { $0.1 > $1.1 }.prefix(k).filter { $0.1 > 0.3 }
    }
}
