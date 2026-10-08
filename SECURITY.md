# Security

**Status: experimental, unaudited.** Securely has not had an independent security review.
Do not rely on it as your only copy of important secrets.

## Threat model

Protects against:
- Someone with your unlocked Mac but not your finger opening the vault UI.
- A stolen or copied `vault.enc` / `index.enc` (AES-256-GCM, key not stored alongside).
- Casual reads of API keys: every reveal, copy, or agent request needs a fresh fingerprint.

Does **not** protect against:
- Malware or another process running as you, or anyone who can modify the app binary
  or attach a debugger. In the default "gated" mode the master key is released after an
  in-app Touch ID check, which is not cryptographically bound to your fingerprint.
- An attacker with your login password who can unlock the login Keychain.
- Plaintext copies of your files: folder/file/app items are **references to paths**, not encrypted copies.
- OS-level traces of those files (Quick Look thumbnails, Spotlight index, Finder metadata).

## Key storage modes

| Mode | When | Strength |
|---|---|---|
| `hardware` | App signed with a real Apple Developer/Development identity | Master key is a biometry-bound Keychain item (`.biometryCurrentSet`); Touch ID is enforced by the OS. Not yet tested by the author. |
| `gated` | Ad-hoc or self-signed builds | Key in the login Keychain, released after an app-level Touch ID check. Weaker. |

Touch ID templates never leave the Secure Enclave; Securely never sees or stores fingerprint data.
Adding or removing a finger in System Settings invalidates `hardware`-mode keys by design.

## Local AI and agent access

- The assistant only talks to Ollama on `127.0.0.1:11434` and only lists local models.
- Secrets are never sent to the model. `copy_secret` needs a fingerprint and clears the clipboard after 30 s.
- The assistant's file tools are limited to folders you added to the vault.
- **Prompt injection:** file and note contents are untrusted. A malicious document could try to steer
  a local model. Mitigations are scoping and fingerprint-gated secrets, not a guarantee.
- The embedding index (`index.enc`) is encrypted, but chunks of your text are sent to your local Ollama for embedding.

## MCP bridge (agent-to-agent)

- Off by default, switches off whenever the vault locks.
- Unix socket at `~/Library/Application Support/Securely/agent.sock`, mode `0600`, in a `0700` directory.
- Only the same macOS user can connect (`getpeereid` check). **Any process running as you can still connect.**
  When access is on, search and file reads need no approval; only `get_secret` prompts for a fingerprint.
  Turn it off when you don't need it.
- The fingerprint prompt and activity log show the caller's kernel-reported process and its parent
  (e.g. `securely-mcp launched by claude`), not just the self-declared MCP client name, which is untrusted.
- Three denied secret requests in a row switch agent access off.
- Everything an agent returns from the vault is data, not instructions, from the calling agent's point of view as well.

## Built-in guardrails
- Folder items that are too broad (`/`, your home folder, `/Users`, `/Library`, …) are refused, because folder items define what the assistant and agents may read.
- File contents, search hits and listings are passed to the model wrapped as untrusted data.
- Notes written for AirDrop go to a private temp directory that is deleted when the vault locks.

## Known limitations
- Vault contents are decrypted in memory while unlocked; a memory dump of the running app exposes them.
- Revealed or copied secrets pass through the system clipboard (cleared after 30 s for assistant copies); clipboard managers may keep them.
- A prompt-injected local model could still add notes, which are then indexed. It cannot read secrets without a fingerprint.
- The bridge spawns a thread per connection with no rate limit (local denial of service only).
- If the Keychain item is lost (or in `hardware` mode, a finger is added/removed), the vault cannot be decrypted. There is no recovery key yet.
- Hardware-bound mode has not been verified on a signed build.

## Reporting a vulnerability

Please open a private security advisory on the GitHub repository (Security tab → Report a vulnerability).
Do not post exploits in public issues.
