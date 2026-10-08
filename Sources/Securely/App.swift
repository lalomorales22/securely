import SwiftUI

@main
struct SecurelyApp: App {
    @StateObject private var vault: VaultStore
    @StateObject private var agent: Agent
    @StateObject private var rag: RAGIndex
    @StateObject private var bridge: BridgeServer
    init() {
        let v = VaultStore()
        _vault = StateObject(wrappedValue: v)
        let r = RAGIndex(vault: v)
        let b = BridgeServer(vault: v, rag: r)
        _rag = StateObject(wrappedValue: r)
        _agent = StateObject(wrappedValue: Agent(vault: v, rag: r))
        _bridge = StateObject(wrappedValue: b)
        b.start()
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if vault.unlocked { MainView() } else { LockView() }
            }
            .environmentObject(vault).environmentObject(agent).environmentObject(rag).environmentObject(bridge)
            .preferredColorScheme(.dark)
            .frame(minWidth: 960, minHeight: 600)
            .background(Color.black)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
