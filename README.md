# Securely

A dark, Touch ID–gated Finder alternative for macOS. Keep API keys, apps, folders, files and notes
in an encrypted vault, with a **local** AI assistant (Ollama) and semantic search over your content.

> **Experimental and unaudited.** Read [SECURITY.md](SECURITY.md) before trusting it with anything important.

## Features
- Touch ID login: first launch scans your finger, creates a random 256-bit key and an AES-GCM encrypted vault.
- Vault items: folders (with a Finder-style browser), files, apps, API keys, notes.
- Per-secret fingerprint re-auth; auto-lock after 5 idle minutes and on sleep.
- Local assistant with tool calling via Ollama (local models only).
- Local semantic search with `embeddinggemma` (index encrypted at rest), plus Spotlight search scoped to vault folders.
- Quick Look previews and AirDrop sharing (fingerprint-gated; API keys are never shareable).
- MCP server (`securely-mcp`) so other agents (e.g. Claude Code) can query the vault; secrets need per-request fingerprint approval.

## Requirements
- macOS 14+ with Touch ID, Xcode command-line tools (Swift 5.9+)
- [Ollama](https://ollama.com) running locally with a tool-capable chat model (e.g. `llama3.2`) and `ollama pull embeddinggemma`

## Build
```bash
./build.sh
open Securely.app
```
`build.sh` signs with a local identity named **Securely Local Signing** if present, otherwise ad-hoc
(macOS Keychain will then re-prompt after every rebuild). For the hardware-bound key mode, sign with your own
Apple Development identity by changing `ID` in `build.sh`.

## Connect another agent (MCP)
Enable **Agents** in the app toolbar, then:
```bash
claude mcp add securely -- "/path/to/Securely.app/Contents/MacOS/securely-mcp"
```

## Data locations
`~/Library/Application Support/Securely/` holds `vault.enc`, `index.enc` and the MCP socket. Nothing is sent off your machine.

## License
MIT
