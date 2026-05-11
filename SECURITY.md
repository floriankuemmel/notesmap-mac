# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Preferred channel: **GitHub Security Advisories** — open a private report at
<https://github.com/floriankuemmel/notesmap-mac/security/advisories/new>.
This keeps the report visible only to me and any collaborators I add.

Alternative: email **privacy@kuemmel.com** with subject
`[NotesMap Security]` and a brief description.

NotesMap is an indie open-source project maintained in spare time. Reports are
handled as time allows, no specific response or fix timeline is guaranteed.

## Scope

In scope:
- The `NotesMap` macOS app (Swift / SwiftUI / WKWebView)
- The Sparkle auto-update path (appcast feed, signing, verification)
- The bundled WebView HTML/JS/CSS (`NotesMap/HTML/`)
- The local read-only access to Apple Notes' SQLite store
- The local Ollama integration (HTTP requests to `127.0.0.1:11434`)

Out of scope:
- Apple Notes itself (file a Feedback Assistant report with Apple)
- Ollama (file at <https://github.com/ollama/ollama>)
- Browser-extension or third-party-tool issues

## Update mechanism trust model

NotesMap auto-updates via [Sparkle 2.9.1](https://sparkle-project.org/). The trust chain:

1. **The app binary**: Apple Developer ID code-signed and notarized. Gatekeeper enforces this on first launch.
2. **The DMG**: signed and stapled with the same Developer ID, plus an EdDSA signature over the DMG bytes. The EdDSA private key is held offline (Keychain + 1Password backup). The public key is hardcoded in `Info.plist` (`SUPublicEDKey`).
3. **The appcast feed (`appcast.xml`)**: hosted at `https://raw.githubusercontent.com/<repo>/main/appcast.xml`. The feed itself is **not** signed, but every `<enclosure>` carries a `sparkle:edSignature` that Sparkle verifies against the bundled public key before installing.

What this means in practice:
- An attacker who can write to `main` **cannot ship malicious code via auto-update** — any DMG they reference must still pass EdDSA verification with the legitimately-issued private key.
- An attacker who can write to `main` **can** cause two lower-impact outcomes:
  - Denial of service: remove the feed or remove the latest entry, so users stop seeing updates.
  - Phishing in release notes: insert misleading `<description>` HTML that points users to off-platform downloads. (Sparkle renders release notes as HTML.)

To close those residual risks:
- The repo's `main` branch is protected (no force-push, required PR review, no admin-bypass).
- The Sparkle EdDSA private key never leaves an encrypted store.
- 2FA is enforced on the GitHub account.

If you spot a way to escalate beyond this — e.g. a Sparkle bug, a feed-parsing issue, a way to leverage the appcast HTML in WKWebView, anything — please report it via email rather than disclosing publicly.

## What NotesMap does **not** do

- It never sends your notes anywhere. The SQLite read is local. Embeddings via Ollama go to `127.0.0.1:11434`. There is no telemetry, no analytics, no error-reporting service.
- It only reads the Apple Notes database. It cannot create, edit, or delete notes.
- It opens external URLs in your default browser (it does not navigate the embedded WebView to user-supplied URLs).

## Hardened Runtime, sandbox, and entitlements

NotesMap ships with the macOS Hardened Runtime **enabled** and an **empty** entitlements file (see `NotesMap/NotesMap.entitlements`). Concretely that means:

- **JIT, unsigned executable memory, library-validation bypass, DYLD-env-variable hijacking, debugger attachment** in shipped builds, all blocked by the Hardened Runtime.
- **App Sandbox is intentionally not enabled.** The app reads `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`, which lives in Apple Notes' group container. Sandboxed third-party apps cannot reach that path; only Apple can grant the entitlement that would. macOS's per-folder Full Disk Access permission (granted by you in System Settings → Privacy & Security) is the trust gate instead.
- **Network usage is hardcoded to `http://localhost:11434`** in `Embeddings/EmbeddingService.swift` and `Embeddings/OllamaLabelService.swift`. There are no other network call sites in the app. macOS cannot scope this entitlement-wise outside the sandbox, but you can confirm via Little Snitch or `lsof -i` that no traffic leaves your machine.

Web content runs in a `WKWebView` with a **strict `Content-Security-Policy`** (`default-src 'none'`, no `connect-src`, only `data:` images, see `LinkMapHTMLBuilder.swift → contentSecurityPolicy`), so even an XSS in the link-map page cannot exfiltrate data over the network.

Vendor JavaScript (D3, Three.js, 3d-force-graph, umap-js) is bundled inside the app and **verified at load time** against a SHA-256 manifest in `LinkMapHTMLBuilder.swift → vendorScriptSHA256`. If any of the four files has been swapped, the WebView refuses to render and the user sees a tamper warning.

Web Inspector / DevTools are **only enabled in Debug builds**.
