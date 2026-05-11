// WebView.swift: dünne SwiftUI-Hülle um WKWebView.
//
// Wir bauen die Link-Map-HTML komplett in Swift (LinkMapHTMLBuilder) und
// laden sie via loadHTMLString in die WebView. Der baseURL-Trick erlaubt
// zukünftiges Nachladen von Ressourcen aus dem App-Bundle (z.B. Images).

import SwiftUI
import WebKit

/// WKWebView-Subklasse, die Escape (keyCode 53) abfängt und an JS weiterleitet.
/// Hintergrund: 3d-force-graph / Three.js Canvases schlucken `keydown` im DOM.
/// Wenn WKWebView First Responder ist, geht das Event über `keyDown(with:)`,
/// dort können wir es abfangen, bevor es im WebContent landet.
final class EscapeCatchingWebView: WKWebView {
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI-NSViewRepresentable macht den View nicht automatisch zum
        // First Responder. Ohne das bekommt `keyDown(with:)` gar keine Events.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        // keyCode 53 = Escape (macOS virtual key code).
        if event.keyCode == 53 {
            evaluateJavaScript(
                "window.__onEscapeFromNative && window.__onEscapeFromNative();",
                completionHandler: nil
            )
            return
        }
        super.keyDown(with: event)
    }
}

struct WebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Developer-Tools (Right-Click → Inspect Element + Safari-Web-Inspector)
        // werden NUR in Debug-Builds aktiviert. In Release-Builds bleibt der Inspektor
        // aus, damit ein End-User (oder ein versehentlicher Klick) den DOM-Inhalt
        // nicht beliebig verändern oder Notiz-Inhalte aus der WebView extrahieren kann.
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        // JS → Swift Brücke:
        //  - "refreshRequest": Refresh-Button im Header
        //  - "heightmapRequest": User aktiviert die Höhenkarten-Ansicht
        //  - "heightmapLabelsRequest": 3D-Ansicht schickt Peak-Cluster für Ollama-Labels
        // Alle laufen über den gleichen Coordinator; userContentController(_:didReceive:)
        // routet per message.name.
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "refreshRequest")
        userContent.add(context.coordinator, name: "heightmapRequest")
        userContent.add(context.coordinator, name: "heightmapLabelsRequest")
        config.userContentController = userContent

        let webView = EscapeCatchingWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")  // Kein weißer Flash beim Laden
        webView.navigationDelegate = context.coordinator
        // Safari-Web-Inspector kann nur an `isInspectable`-WebViews andocken.
        // Wie oben: nur in Debug-Builds.
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif

        webView.loadHTMLString(html, baseURL: baseURL)
        context.coordinator.attach(webView: webView)
        return webView
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Handler explizit entfernen, damit der Coordinator frei wird (sonst
        // retained der UserContentController den Delegate dauerhaft).
        let ucc = webView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "refreshRequest")
        ucc.removeScriptMessageHandler(forName: "heightmapRequest")
        ucc.removeScriptMessageHandler(forName: "heightmapLabelsRequest")
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Wenn sich die HTML ändert (z.B. nach Refresh) → neu laden.
        if context.coordinator.lastLoadedHTML != html {
            context.coordinator.lastLoadedHTML = html
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(initialHTML: html)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastLoadedHTML: String
        private weak var webViewRef: WKWebView?
        private var observers: [NSObjectProtocol] = []

        init(initialHTML: String) {
            self.lastLoadedHTML = initialHTML
            super.init()

            // Inkrementelle Data-Updates: LinkMapModel postet den JSON-Payload
            // per Notification; wir speisen ihn ins laufende JS ein.
            observers.append(NotificationCenter.default.addObserver(
                forName: .linkMapDataUpdated,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self = self,
                      let payload = note.userInfo?["payload"] as? String,
                      let webView = self.webViewRef else { return }
                // Payload ist valides JSON, und JSON ist valides JS-Literal.
                // Wir hängen es direkt an window.__applyDataUpdate(...). Die
                // if-Prüfung schützt gegen Updates, die vor dem Init des JS
                // eintrudeln (Race zwischen WebView-Load und sofortigem Refresh).
                let js = "if (window.__applyDataUpdate) { window.__applyDataUpdate(\(payload)); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            })

            // Heightmap-Progress: nur UI-Updates im Heightmap-Overlay.
            observers.append(NotificationCenter.default.addObserver(
                forName: .linkMapHeightmapProgress,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self = self,
                      let webView = self.webViewRef,
                      let info = note.userInfo else { return }
                let payload: [String: Any] = [
                    "phase": info["phase"] as? String ?? "",
                    "done": info["done"] as? Int ?? 0,
                    "total": info["total"] as? Int ?? 0,
                    "message": info["message"] as? String ?? ""
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let jsonString = String(data: data, encoding: .utf8) else { return }
                let js = "if (window.__heightmapProgress) { window.__heightmapProgress(\(jsonString)); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            })

            // Heightmap-Ready: Payload ist fertig → JS rendert.
            observers.append(NotificationCenter.default.addObserver(
                forName: .linkMapHeightmapReady,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self = self,
                      let payload = note.userInfo?["payload"] as? String,
                      let webView = self.webViewRef else { return }
                let js = "if (window.__applyHeightmap) { window.__applyHeightmap(\(payload)); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            })

            // Heightmap-Error: User-sichtbare Fehlermeldung im Overlay.
            observers.append(NotificationCenter.default.addObserver(
                forName: .linkMapHeightmapError,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self = self,
                      let webView = self.webViewRef,
                      let msg = note.userInfo?["message"] as? String else { return }
                // Message ist ein String, über JSON-Serialisierung jagen,
                // damit Sonderzeichen / Quotes escaped sind.
                guard let data = try? JSONSerialization.data(
                        withJSONObject: ["message": msg]),
                      let jsonString = String(data: data, encoding: .utf8) else { return }
                let js = "if (window.__heightmapError) { window.__heightmapError(\(jsonString)); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            })

            // Heightmap-Labels-Ready: Swift hat (einige) Ollama-Labels generiert.
            // Payload ist bereits ein fertiger JSON-String: {"epoch":N,"labels":[…]}.
            observers.append(NotificationCenter.default.addObserver(
                forName: .linkMapHeightmapLabelsReady,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self = self,
                      let payload = note.userInfo?["payload"] as? String,
                      let webView = self.webViewRef else { return }
                let js = "if (window.__applyHeightmapPeakLabels) { window.__applyHeightmapPeakLabels(\(payload)); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            })
        }

        /// Vom makeNSView aufgerufen, damit wir die WKWebView-Referenz haben,
        /// um Data-Updates per evaluateJavaScript zu pushen.
        func attach(webView: WKWebView) {
            self.webViewRef = webView
        }

        deinit {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        // JS → Swift-Routing:
        //  - "refreshRequest": Header-Refresh-Button → silentRefresh
        //  - "heightmapRequest": User klickt Höhenkarte → Embedding-Batch starten
        //  - "heightmapLabelsRequest": 3D-View sendet Peak-Cluster → Ollama-Labels
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "refreshRequest":
                NotificationCenter.default.post(
                    name: .linkMapRefreshRequested,
                    object: nil
                )
            case "heightmapRequest":
                NotificationCenter.default.post(
                    name: .linkMapHeightmapRequested,
                    object: nil
                )
            case "heightmapLabelsRequest":
                // Body kommt als [String: Any] rein. Wir reichen ihn 1:1 als
                // userInfo weiter, ContentView/LinkMapModel parsed dann.
                guard let body = message.body as? [String: Any] else { break }
                NotificationCenter.default.post(
                    name: .linkMapHeightmapLabelsRequested,
                    object: nil,
                    userInfo: body
                )
            default:
                break
            }
        }

        // Externe Links (applenotes:…) nicht in der WebView öffnen, sondern im System.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Initial load + Datenschemata durchlassen
            if url.scheme == "about" || url.scheme == "data" || url.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }

            // applenotes:, https:, mailto: etc. → System öffnen
            if let scheme = url.scheme, scheme != "file" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
