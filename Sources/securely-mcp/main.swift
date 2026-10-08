import Foundation

// Minimal MCP stdio server that forwards tool calls to the running Securely app over its local socket.
let sockPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Securely/agent.sock").path
var clientName = "mcp-client"

func callApp(_ tool: String, _ args: [String: Any]) -> (String, Bool) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, sockPath, 104) }
    }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { return ("Securely is not running. Open the app and unlock it.", true) }
    guard var req = try? JSONSerialization.data(withJSONObject: ["tool": tool, "args": args, "client": clientName]) else { return ("bad request", true) }
    req.append(10)
    _ = req.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var buf = Data(); var tmp = [UInt8](repeating: 0, count: 65536)
    while true { let n = read(fd, &tmp, tmp.count); if n <= 0 { break }; buf.append(contentsOf: tmp[0..<n]) }
    let j = (try? JSONSerialization.jsonObject(with: buf)) as? [String: Any]
    return (j?["text"] as? String ?? "no response", false)
}

func schema(_ props: [String: String]) -> [String: Any] {
    ["type": "object", "properties": props.mapValues { ["type": "string", "description": $0] }, "required": Array(props.keys)]
}
let tools: [[String: Any]] = [
    ["name": "search_vault", "description": "Search Securely vault items by name/kind. Never returns secrets.", "inputSchema": schema(["query": "text to match"])],
    ["name": "semantic_search", "description": "Semantic (embedding) search over notes and text files in vault folders.", "inputSchema": schema(["query": "natural-language question"])],
    ["name": "spotlight_search", "description": "Spotlight search confined to vault folders.", "inputSchema": schema(["query": "search text"])],
    ["name": "list_folder", "description": "List a directory inside a vault folder.", "inputSchema": schema(["path": "absolute path"])],
    ["name": "read_text_file", "description": "Read up to 20KB of a text file inside a vault folder.", "inputSchema": schema(["path": "absolute path"])],
    ["name": "get_secret", "description": "Request an API key. The user must approve with their fingerprint.", "inputSchema": schema(["name": "API key item name"])],
]

func send(_ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return }
    print(s); fflush(stdout)
}

while let line = readLine() {
    guard let m = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let method = m["method"] as? String else { continue }
    let id = m["id"]
    guard let id else { continue }                       // notifications need no reply
    let params = m["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        if let ci = params["clientInfo"] as? [String: Any], let n = ci["name"] as? String { clientName = n }
        send(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": params["protocolVersion"] as? String ?? "2024-11-05",
              "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "securely", "version": "0.2"]]])
    case "tools/list":
        send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
    case "tools/call":
        let (text, isErr) = callApp(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        send(["jsonrpc": "2.0", "id": id, "result": ["content": [["type": "text", "text": text]], "isError": isErr]])
    case "ping":
        send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
    default:
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]])
    }
}
