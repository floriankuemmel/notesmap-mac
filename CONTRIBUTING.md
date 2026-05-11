# Contributing to NotesMap

Thanks for taking the time to look at the code. This is a small one-maintainer project, so the contribution flow is intentionally simple.

## Before you start

For anything beyond a typo fix or a one-line bug fix, **open an issue first**. Sketch what you'd like to change and why. That avoids the case where you spend a weekend on a PR and I have to say "sorry, this conflicts with the architecture I'm planning." Five minutes of upfront chat saves both of us.

For tiny fixes (typos, dead code, doc clarifications), feel free to skip the issue and open the PR directly.

## Setup

```bash
git clone https://github.com/floriankuemmel/notesmap-mac
cd notesmap-mac
brew install xcodegen
xcodegen generate
open NotesMap.xcodeproj
```

Build configuration: macOS 14.0 deployment target, Swift 5.9+, Xcode 16.x. Dependencies are pinned in `NotesMap.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (committed for reproducibility).

If you change `project.yml`, run `xcodegen generate` and commit the resulting `NotesMap.xcodeproj/project.pbxproj` diff.

## Making a change

1. Branch off `main`: `git checkout -b your-change`
2. Make focused commits, one logical change per commit
3. Build in **both** Debug and Release before pushing (`xcodebuild -scheme NotesMap -configuration Release build` catches DEBUG-gated regressions)
4. If you touched a vendor JS file, run `scripts/update-vendor-hashes.sh` and paste the output into `LinkMapHTMLBuilder.swift` → `vendorScriptSHA256`
5. Open a PR against `main` with a description that explains *why*, not just *what*

CI runs `xcodebuild` (Debug + Release) and a vendor-hash check on every PR. Both must pass.

## Style

- **Swift**: 4-space indent, 100-column soft limit. Match the surrounding code, no separate formatter is enforced.
- **Comments in code**: German is fine if you're more comfortable. The existing codebase mixes English and German freely. Comments should explain *why*, not *what*.
- **Commit messages**: Imperative mood ("Add CSP header" not "Added CSP header"). First line under 70 chars; body wraps at ~72. No emoji.

## Localization

NotesMap is bilingual (German / English). Every user-facing string lives in `Localized.swift` as a `T2 = (German, English)` tuple.

If you add a UI string:
1. Add a `T2` entry in `Localized.swift` next to related ones
2. Use both translations, no `T2 = ("Hallo", "")` placeholders, the test suite (`LocalizationParityTests`) will fail on empty entries
3. Inside the WebView (HTML/JS), strings flow through `window.NM_LOC` and `Localized.jsLocaleObject(in:)`

## Architecture: things to know

- **Read path**: GRDB on `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` (read-only, opened once, watched via `NoteStoreWatcher`)
- **Write path**: there is none. NotesMap cannot modify Apple Notes
- **Render path**: Swift builds an HTML string in `LinkMapHTMLBuilder.swift`, hands it to a `WKWebView`. JS does the visualization (D3, Three.js, 3d-force-graph)
- **Bridge**: Swift ↔ JS via `webkit.messageHandlers` (refresh, heightmap requests) and `evaluateJavaScript` (data updates, label results)
- **Heightmap**: optional, requires Ollama running locally on port 11434. Embeddings cached in `~/Library/Application Support/NotesMap/embeddings.json` (0600)

## Security

If you find a vulnerability, **please don't open a public issue**. See [`SECURITY.md`](SECURITY.md) for the disclosure channel.

## What I'm unlikely to merge

- **Telemetry / analytics / "anonymous usage data"**, the app's value prop is "your notes never leave your machine." Adding telemetry breaks that promise.
- **Cloud-LLM integrations** (OpenAI, Anthropic, etc.). Ollama is local, that's the line. If you want a cloud-backed fork, fork.
- **Drive-by "modernizations"** that touch hundreds of lines without a concrete behavior change. If a refactor would help a specific upcoming feature, open an issue describing the feature first.
- **Adding dependencies** without a strong justification. Each dep is a build-time + supply-chain cost.

If you're unsure whether something falls in the above, just ask in an issue.

## License

By contributing you agree that your contribution is licensed under the same MIT license as the rest of the project (see [`LICENSE`](LICENSE)).
