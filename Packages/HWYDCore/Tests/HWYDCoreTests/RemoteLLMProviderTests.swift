import XCTest
@testable import HWYDCore

/// Wire-format checks for hosted summary providers. No network call is made.
final class RemoteLLMProviderTests: XCTestCase {
    private let ids = [UUID(), UUID()]
    private let prompt = "EXTRACT:\n" + #"[{"id":"S1","speaker":"Camille","text":"Je rédigerai l'annonce."},{"id":"S2","speaker":"Jordan","text":"On valide."}]"#

    private func body(_ service: SummaryService) throws -> (URLRequest, [String: Any]) {
        let provider = try RemoteLLMProvider(service: service, model: "fixture", apiKey: " secret ")
        let request = try provider.makeRequest(prompt: prompt, evidenceIDs: ids, planning: true).request
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        return (request, object)
    }
    private func containsKey(_ value: Any, _ key: String) -> Bool {
        if let object = value as? [String: Any] { return object[key] != nil || object.values.contains { containsKey($0, key) } }
        if let array = value as? [Any] { return array.contains { containsKey($0, key) } }
        return false
    }

    func testRejectsMissingKeyAndModel() {
        XCTAssertThrowsError(try RemoteLLMProvider(service: .openai, model: "m", apiKey: "  "))
        XCTAssertThrowsError(try RemoteLLMProvider(service: .openai, model: " ", apiKey: "k"))
        XCTAssertThrowsError(try RemoteLLMProvider(service: .local, model: "m", apiKey: "k"))
    }

    func testOpenAICompatibleServices() throws {
        for service in [SummaryService.mistral, .openai, .gemini] {
            let (request, body) = try body(service)
            XCTAssertEqual(request.url, service.baseURL!.appendingPathComponent("chat/completions"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let format = try XCTUnwrap(body["response_format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertFalse(containsKey(format, "maxItems"))
            XCTAssertFalse(containsKey(format, "minItems"))
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains(ids[0].uuidString))
            if service == .openai {
                XCTAssertNil(body["temperature"]); XCTAssertNil(body["max_tokens"])
                XCTAssertEqual(body["max_completion_tokens"] as? Int, RemoteLLMProvider.outputTokens)
            } else {
                XCTAssertEqual(body["max_tokens"] as? Int, RemoteLLMProvider.outputTokens)
            }
        }
    }

    func testAnthropicMessagesRequest() throws {
        let (request, body) = try body(.anthropic)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(body["temperature"])
        XCTAssertTrue((body["system"] as? String)?.contains("FORMAT DE SORTIE OBLIGATOIRE") == true)
        let format = try XCTUnwrap((body["output_config"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertFalse(containsKey(format, "maxItems"))
    }

    func testLargeWindowsDropOnlyTheEvidenceEnum() throws {
        let provider = try RemoteLLMProvider(service: .openai, model: "fixture", apiKey: "k")
        XCTAssertGreaterThan(provider.requestCharacterCeiling, SummaryPipeline.maximumInputCharacters)
        let many = (0...RemoteLLMProvider.evidenceEnumLimit).map { _ in UUID() }
        let request = try provider.makeRequest(prompt: prompt, evidenceIDs: many, planning: true).request
        let text = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertFalse(text.contains(#""S1","S10""#))
        XCTAssertTrue(text.contains(#""enum":["Camille","Jordan"]"#))
        let few = String(decoding: try XCTUnwrap(provider.makeRequest(prompt: prompt, evidenceIDs: ids, planning: true).request.httpBody), as: UTF8.self)
        XCTAssertTrue(few.contains(#""enum":["S1","S2"]"#))
    }

    func testResponsesAreLimitedAndTranslated() throws {
        let provider = try RemoteLLMProvider(service: .anthropic, model: "fixture", apiKey: "k")
        let stage = try provider.makeRequest(prompt: "ROUTE:\n[]", evidenceIDs: ids, planning: true).stage
        let output = #"{"overview":"Fil [S1]","key_points":[],"decisions":[{"text":"Hors sujet","evidence_segment_ids":["S1"]}],"action_items":[],"details":[{"title":"Thème","text":"Périmètre [S2]","evidence_segment_ids":["S1","S2"]}]}"#
        let response = try JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn", "content": [["type": "text", "text": output]]])
        let content = try SummaryStageRequest.decode(RemoteLLMProvider.content(of: response, service: .anthropic), references: stage.references, limits: stage.schema)
        XCTAssertEqual(content.overview, "Fil")
        XCTAssertTrue(content.decisions.isEmpty, "ROUTE allows no decision, as constrained decoding would enforce")
        XCTAssertEqual(content.details?.first?.text, "Périmètre")
        XCTAssertEqual(content.details?.first?.evidence_segment_ids, ids)
    }

    func testTruncatedRefusedAndErrorResponses() throws {
        let truncated = try JSONSerialization.data(withJSONObject: ["stop_reason": "max_tokens", "content": []])
        XCTAssertThrowsError(try RemoteLLMProvider.content(of: truncated, service: .anthropic)) { XCTAssertEqual(($0 as? SummaryFailure)?.errorDescription, SummaryFailure.outputTruncated.errorDescription) }
        let refused = try JSONSerialization.data(withJSONObject: ["stop_reason": "refusal", "content": []])
        XCTAssertThrowsError(try RemoteLLMProvider.content(of: refused, service: .anthropic))
        let length = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["content": "{"]]]])
        XCTAssertThrowsError(try RemoteLLMProvider.content(of: length, service: .openai))
        XCTAssertEqual(RemoteLLMProvider.errorDetail(Data(#"{"error":{"message":"Invalid schema"}}"#.utf8)), "Invalid schema")
        XCTAssertEqual(RemoteLLMProvider.errorDetail(Data(#"[{"error":{"message":"Quota"}}]"#.utf8)), "Quota")
        XCTAssertEqual(RemoteLLMProvider.errorDetail(Data(#"{"message":"Unauthorized"}"#.utf8)), "Unauthorized")
    }

    func testModelCatalogRequests() throws {
        let anthropic = try SummaryModelCatalog.makeRequest(service: .anthropic, apiKey: "k")
        XCTAssertEqual(anthropic.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(anthropic.value(forHTTPHeaderField: "x-api-key"), "k")
        let gemini = try SummaryModelCatalog.makeRequest(service: .gemini, apiKey: "k")
        XCTAssertEqual(gemini.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000")
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), "k")
        XCTAssertFalse(gemini.url!.absoluteString.contains("key="))
        let openai = try SummaryModelCatalog.makeRequest(service: .openai, apiKey: "k")
        XCTAssertEqual(openai.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(openai.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertThrowsError(try SummaryModelCatalog.makeRequest(service: .mistral, apiKey: " "))
    }

    func testModelCatalogKeepsTextModels() throws {
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        XCTAssertEqual(try SummaryModelCatalog.parse(data(["data": [["id": "gpt-5-mini"], ["id": "text-embedding-3-large"], ["id": "o4-mini"], ["id": "whisper-1"], ["id": "gpt-4o-realtime-preview"], ["id": "dall-e-3"]]]), service: .openai),
                       ["gpt-5-mini", "o4-mini"])
        XCTAssertEqual(try SummaryModelCatalog.parse(data(["data": [["id": "mistral-medium-latest", "capabilities": ["completion_chat": true]], ["id": "mistral-embed", "capabilities": ["completion_chat": false]], ["id": "mistral-medium-latest", "capabilities": ["completion_chat": true]]]]), service: .mistral),
                       ["mistral-medium-latest"])
        XCTAssertEqual(try SummaryModelCatalog.parse(data(["models": [["name": "models/gemini-flash-latest", "supportedGenerationMethods": ["generateContent"]], ["name": "models/gemini-embedding-001", "supportedGenerationMethods": ["embedContent"]], ["name": "models/imagen-4", "supportedGenerationMethods": ["predict"]]]]), service: .gemini),
                       ["gemini-flash-latest"])
        XCTAssertEqual(try SummaryModelCatalog.parse(data(["data": [["id": "claude-opus-5-5"], ["id": "claude-haiku-5-5"]]]), service: .anthropic),
                       ["claude-haiku-5-5", "claude-opus-5-5"])
        XCTAssertThrowsError(try SummaryModelCatalog.parse(Data("[]".utf8), service: .openai))
    }
}
