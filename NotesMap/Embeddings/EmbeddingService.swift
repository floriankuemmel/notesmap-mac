// EmbeddingService.swift, HTTP-Client für Ollama's `/api/embeddings`.
//
// Ollama läuft lokal auf Port 11434 und bietet einen simplen REST-Endpoint.
// Wir nutzen ein passendes Embedding-Modell (Default: `bge-m3`:
// multilingual, 1024-dim, ~1.2 GB auf Platte). Ein Call = ein Embedding.
//
// Keine Concurrency-Magie hier, der Service ist stateless-`Sendable`.
// Der EmbeddingManager (actor) orchestriert Batch-Runs.

import Foundation

struct EmbeddingService: Sendable {
    let baseURL: URL
    let model: String
    let timeout: TimeInterval

    init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        model: String = "bge-m3",
        timeout: TimeInterval = 60
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    enum ServiceError: Error, LocalizedError, Sendable {
        case ollamaUnreachable(String)
        case modelNotLoaded(String)
        case httpError(Int, String)
        case decodingFailed
        case emptyEmbedding

        var errorDescription: String? {
            switch self {
            case .ollamaUnreachable(let reason):
                return "\(Localized.string(\.errOllamaUnreachable)) \(reason)"
            case .modelNotLoaded(let model):
                return String(format: Localized.string(\.errModelNotLoaded), model, model)
            case .httpError(let code, let body):
                return String(format: Localized.string(\.errOllamaHTTP), code, String(body.prefix(200)))
            case .decodingFailed:
                return Localized.string(\.errEmbeddingDecodeFail)
            case .emptyEmbedding:
                return Localized.string(\.errEmptyEmbedding)
            }
        }
    }

    /// Prüft, ob Ollama läuft UND das Modell geladen ist.
    /// Ruft `GET /api/tags` auf, liefert die Liste installierter Modelle.
    func checkAvailability() async -> Result<Void, ServiceError> {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 5
        req.httpMethod = "GET"

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                return .failure(.ollamaUnreachable("Antwort != 200."))
            }
            // Parse Modellnamen aus der Antwort (grobes Matching per Substring).
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("\"name\":\"\(model):") || body.contains("\"name\":\"\(model)\"") {
                return .success(())
            }
            return .failure(.modelNotLoaded(model))
        } catch {
            return .failure(.ollamaUnreachable(error.localizedDescription))
        }
    }

    /// Embeddet einen Text in einen Float-Vektor.
    /// Für bge-m3 ist dim=1024.
    func embed(_ text: String) async throws -> [Float] {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/embeddings"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Req: Encodable { let model: String; let prompt: String }
        let body = Req(model: model, prompt: text)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ServiceError.ollamaUnreachable(Localized.string(\.errInvalidHTTP))
        }
        guard http.statusCode == 200 else {
            let s = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.httpError(http.statusCode, s)
        }

        struct Resp: Decodable { let embedding: [Double]? }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        guard let emb = r.embedding, !emb.isEmpty else {
            throw ServiceError.emptyEmbedding
        }
        return emb.map { Float($0) }
    }
}
