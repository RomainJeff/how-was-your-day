import XCTest
@testable import HWYDCore

final class TranscriptionTests: XCTestCase, @unchecked Sendable {
    func testResultsPreserveLatestNotesAndInvalidateSummary() throws {
        var recording = Recording(title: "Test", notes: "Notes pendant le traitement", summary: "Ancienne synthèse")
        recording.audioChunks = [.init(source: .mic, relativePath: "mic.caf", start: 300, duration: 5)]
        let request = TranscriptionRequest(recordingID: recording.id, chunks: recording.audioChunks)
        let segment = TranscriptSegment(start: 301, end: 302, speakerID: nil, source: .mic, text: "Bonjour")
        try recording.applyTranscription(.init(request: request, segments: [segment]))
        XCTAssertEqual(recording.notes, "Notes pendant le traitement")
        XCTAssertEqual(recording.transcriptVersion, 1)
        XCTAssertEqual(recording.transcriptState, .ready)
        XCTAssertNil(recording.summary)
        XCTAssertTrue(recording.speakers.isEmpty)
        XCTAssertNil(recording.segments.first?.speakerID)
    }
    func testRejectsResultFromDifferentAudio() throws {
        var recording = Recording(title: "Test")
        let request = TranscriptionRequest(recordingID: recording.id, chunks: [.init(source: .mic, relativePath: "old.caf", start: 0, duration: 1)])
        XCTAssertThrowsError(try recording.applyTranscription(.init(request: request, segments: [])))
        XCTAssertEqual(recording.transcriptVersion, 0)
    }
    func testOldPayloadWithoutWordsStillDecodes() throws {
        let segment = TranscriptSegment(start: 0, end: 1, speakerID: nil, source: .mic, text: "Bonjour")
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertNil(decoded.words)
    }
    func testPipelineMergesTracksBySessionTimeWithoutInventingSpeakers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(directory: directory)
        let request = TranscriptionRequest(recordingID: UUID(), chunks: [
            .init(source: .mic, relativePath: "mic.caf", start: 300, duration: 5),
            .init(source: .system, relativePath: "system.caf", start: 0, duration: 5)])
        let result = try await TranscriptionPipeline.run(request, store: store, recognizer: FakeRecognizer())
        XCTAssertEqual(result.segments.map(\.start), [1, 301])
        XCTAssertEqual(result.segments.map(\.source), [.system, .mic])
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerID == nil })
    }
    private func detect(_ recognizer: LanguageFake, candidates: [String] = ["fr-FR", "en-US"], fallback: String = "fr-FR") async throws -> TranscriptionResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(directory: directory)
        let request = TranscriptionRequest(recordingID: UUID(), locale: SpeechLanguage.automatic, chunks: [
            .init(source: .mic, relativePath: "mic.caf", start: 0, duration: 5)], candidateLocales: candidates, fallbackLocale: fallback)
        return try await TranscriptionPipeline.run(request, store: store, recognizer: recognizer)
    }
    func testDetectionSwitchesToEnglishWhenTextAndConfidenceAgree() async throws {
        let result = try await detect(LanguageFake(spoken: "en"))
        XCTAssertEqual(result.request.locale, "en-US")
        XCTAssertEqual(result.languageDetection?.method, .detected)
        XCTAssertEqual(result.segments.first?.text, "transcribed in en-US")
    }
    func testDetectionKeepsFallbackForFrenchSpeech() async throws {
        let result = try await detect(LanguageFake(spoken: "fr"))
        XCTAssertEqual(result.request.locale, "fr-FR")
        XCTAssertEqual(result.languageDetection?.method, .detected)
    }
    func testDetectionFallsBackOnSilence() async throws {
        let result = try await detect(LanguageFake(spoken: nil), fallback: "en-US")
        XCTAssertEqual(result.request.locale, "en-US")
        XCTAssertEqual(result.languageDetection?.method, .fallback)
    }
    func testDetectionKeepsFallbackWhenSecondPassIsLessConfident() async throws {
        let result = try await detect(LanguageFake(spoken: "en", englishConfidence: 0.5))
        XCTAssertEqual(result.request.locale, "fr-FR")
    }
    func testSingleCandidateSkipsDetection() async throws {
        let result = try await detect(LanguageFake(spoken: "en"), candidates: ["fr-FR", "fr-CA"])
        XCTAssertEqual(result.request.locale, "fr-FR")
        XCTAssertEqual(result.languageDetection?.method, .fallback)
    }
    func testOneLocalePerLanguagePrefersUserRegionThenCanonical() {
        XCTAssertEqual(SpeechLanguage.oneLocalePerLanguage(["en_AU", "en_GB", "en_US", "fr_CA", "fr_FR"], preferredRegion: "GB"), ["en-GB", "fr-FR"])
        XCTAssertEqual(SpeechLanguage.oneLocalePerLanguage(["fr_CA", "fr_FR", "en_AU"], preferredRegion: "CA"), ["fr-CA", "en-AU"])
        XCTAssertEqual(SpeechLanguage.oneLocalePerLanguage(["en_AU", "en_US"], preferredRegion: nil), ["en-US"])
    }
    func testFallbackFollowsPreferredLanguages() {
        XCTAssertEqual(SpeechLanguage.fallback(installed: ["en_US", "fr_FR"], preferredLanguages: ["en-FR", "fr-FR"]), "en-US")
        XCTAssertEqual(SpeechLanguage.fallback(installed: ["en_US", "fr_FR"], preferredLanguages: ["de-DE"]), "fr-FR")
        XCTAssertEqual(SpeechLanguage.fallback(installed: [], preferredLanguages: ["de-DE"]), "fr-FR")
    }
    func testOldRecordingWithoutSpeechLanguageDecodes() throws {
        var recording = Recording(title: "Ancienne")
        recording.speechLanguage = nil
        let decoded = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(recording))
        XCTAssertNil(decoded.speechLanguage)
    }
}
/// Simulates a recognizer that writes what it hears with the requested model: the right model is
/// confident, the wrong one is not, and the text stays identifiable either way.
private struct LanguageFake: SpeechRecognizing {
    var spoken: String?
    var englishConfidence = 0.94
    func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample {
        guard let spoken else { return SpeechSample(text: "", confidence: nil) }
        let text = spoken == "en" ? "Hi everyone, quick status on the project. The database migration is planned for Thursday and two tickets remain."
                                  : "Bonjour à tous, on fait le point sur le projet. La migration de la base est prévue jeudi et il reste deux tickets."
        let matches = SpeechLanguage.languageCode(of: locale) == spoken
        return SpeechSample(text: text, confidence: matches ? (spoken == "en" ? englishConfidence : 0.96) : 0.85)
    }
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        [.init(start: chunk.start + 1, end: chunk.start + 2, speakerID: nil, source: chunk.source, text: "transcribed in \(locale)")]
    }
}
private struct FakeRecognizer: SpeechRecognizing {
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        [.init(start: chunk.start + 1, end: chunk.start + 2, speakerID: nil, source: chunk.source, text: "Bonjour")]
    }
}
