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
`build.sh` picks a signing identity in this order: `$SIGN_ID`, an **Apple Development** certificate, a local
**Securely Local Signing** certificate, then ad-hoc. Ad-hoc works, but macOS sees every rebuild as a new app and
asks for your Mac password to release the Keychain item. Use one of the stable options below to avoid that.

### Stable signing identity (recommended)

**Option A: free Apple Development certificate (needs Xcode)**
1. Install Xcode and open **Xcode → Settings → Accounts**, then sign in with your Apple ID.
2. Select the account, click **Manage Certificates…**, click **+**, choose **Apple Development**.
3. Run `security find-identity -v -p codesigning`. You should see `Apple Development: you@example.com (…)` as *valid*.
   - If `build.sh` prints `unable to build chain to self-signed root`, the Apple intermediate certificate is missing.
     Download the **Worldwide Developer Relations** intermediate certificate (G3 or G6, whichever issued yours; see the
     certificate details in Keychain Access) from <https://www.apple.com/certificateauthority/> and double-click it to install.
   - If `codesign` fails with `errSecInternalComponent`, run `./build.sh` from a normal Terminal window and choose
     **Always Allow** when macOS asks to use the certificate's private key.
4. `./build.sh` now signs with it. To force a specific identity: `SIGN_ID="Apple Development: …" ./build.sh`.

**Option B: local self-signed certificate (no Apple ID)**
```bash
cat > cs.cnf <<'EOF2'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Securely Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF2
openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 3650 -config cs.cnf
openssl pkcs12 -export -inkey k.pem -in c.pem -out s.p12 -passout pass:securely \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import s.p12 -k ~/Library/Keychains/login.keychain-db -P securely -T /usr/bin/codesign
rm -f k.pem c.pem s.p12 cs.cnf
```
The first launch after switching identity shows one Keychain prompt: choose **Always Allow**.

> **Hardware-bound key mode is not available from `build.sh` yet.** It needs the data-protection Keychain, which macOS
> only allows for apps with a provisioning profile and `keychain-access-groups` entitlement (an Xcode project). Plain
> command-line builds get `-34018` and Securely falls back to the "Touch ID gated" mode. See [SECURITY.md](SECURITY.md).

## Connect another agent (MCP)
Enable **Agents** in the app toolbar, then:
```bash
claude mcp add securely -- "/path/to/Securely.app/Contents/MacOS/securely-mcp"
```

## Data locations
`~/Library/Application Support/Securely/` holds `vault.enc`, `index.enc` and the MCP socket. Nothing is sent off your machine.

## License
MIT
