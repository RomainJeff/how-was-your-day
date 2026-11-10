import Foundation
import AVFoundation
import Speech
import NaturalLanguage

public struct TranscriptWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}

public struct TranscriptionRequest: Codable, Sendable {
    public var recordingID: UUID
    public var locale: String
    public var chunks: [AudioChunk]
    public var diarize: Bool?
    public var echoCancellation: Bool?
    /// With `locale == SpeechLanguage.automatic`, the languages the pipeline may detect. One locale per language.
    public var candidateLocales: [String]?
    /// Locale used when detection is not conclusive (silence, too little speech, single candidate).
    public var fallbackLocale: String?
    public init(recordingID: UUID, locale: String = "fr-FR", chunks: [AudioChunk], diarize: Bool = false,
                candidateLocales: [String]? = nil, fallbackLocale: String? = nil) {
        self.recordingID = recordingID; self.locale = locale; self.chunks = chunks; self.diarize = diarize
        self.candidateLocales = candidateLocales; self.fallbackLocale = fallbackLocale
    }
}
/// How the transcription locale was chosen when the session asked for automatic detection.
public struct LanguageDetection: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        /// The text of a sample agreed with the candidate's own confidence.
        case detected
        /// Too little speech, a single candidate, or an inconclusive sample.
        case fallback
    }
    public var locale: String
    public var method: Method
    /// Mean word confidence of the retained locale on the sample, when measured.
    public var confidence: Double?
    public init(locale: String, method: Method, confidence: Double? = nil) { self.locale = locale; self.method = method; self.confidence = confidence }
}
public struct TranscriptionProvenance: Codable, Equatable, Sendable {
    public var engine: String
    public var diarizationEngine: String?
    public var echoCancellationEngine: String?
    public var locale: String
    public var createdAt: Date
    /// Present when the locale was detected rather than chosen.
    public var languageDetection: LanguageDetection?
}
public struct TranscriptionResult: Codable, Sendable {
    public var identityWarning: String?
    public var request: TranscriptionRequest
    public var engine: String
    public var diarizationEngine: String?
    public var echoCancellationEngine: String?
    public var createdAt: Date
    public var segments: [TranscriptSegment]
    public var speakers: [Speaker]?
    public var languageDetection: LanguageDetection?
    public init(request: TranscriptionRequest, segments: [TranscriptSegment]) {
        self.request = request; self.segments = segments; engine = "apple-speech-transcriber-v1"; createdAt = Date()
    }
}
public enum TranscriptionError: LocalizedError {
    case unavailable, unsupportedLocale(String), missingAssets(String), invalidAudio, staleResult
    public var errorDescription: String? {
        switch self {
        case .unavailable: "La transcription Apple n’est pas disponible sur ce Mac."
        case .unsupportedLocale(let locale): "La langue \(locale) n’est pas prise en charge par SpeechTranscriber sur ce Mac."
        case .missingAssets(let locale): "Le modèle \(locale) doit être installé. Installez cette langue dans Réglages, Audio et voix."
        case .invalidAudio: "Aucune tranche audio valide à transcrire."
        case .staleResult: "Le résultat ne correspond plus aux fichiers de cette session."
        }
    }
}
public protocol SpeechRecognizing: Sendable {
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment]
    /// Transcribes at most the first `seconds` of a chunk for language detection.
    func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample
}
public struct SpeechSample: Sendable, Equatable {
    public var text: String
    /// Mean word confidence in 0...1, nil when the engine reports none.
    public var confidence: Double?
    public init(text: String, confidence: Double?) { self.text = text; self.confidence = confidence }
}
extension SpeechRecognizing {
    public func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample {
        let text = try await transcribe(file: file, chunk: chunk, locale: locale).filter { $0.start - chunk.start < seconds }.map(\.text).joined(separator: " ")
        return SpeechSample(text: text, confidence: nil)
    }
}
public actor AppleSpeechRecognizer: SpeechRecognizing {
    public init() {}
    private func module(locale: String, confidence: Bool = false) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else {
            throw TranscriptionError.unsupportedLocale(locale)
        }
        return SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                 attributeOptions: confidence ? [.audioTimeRange, .transcriptionConfidence] : [.audioTimeRange])
    }
    public func sample(file: URL, chunk: AudioChunk, locale: String, seconds: Double) async throws -> SpeechSample {
        let transcriber = try await module(locale: locale, confidence: true)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw TranscriptionError.missingAssets(locale) }
        let source = try AVAudioFile(forReading: file)
        let frames = AVAudioFrameCount(min(Double(source.length), seconds * source.processingFormat.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames) else { return SpeechSample(text: "", confidence: nil) }
        try source.read(into: buffer, frameCount: frames)
        // The excerpt stays in the pipeline's temporary directory and is removed right after analysis.
        let excerpt = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-language-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: excerpt) }
        do {
            let output = try AVAudioFile(forWriting: excerpt, settings: source.fileFormat.settings, commonFormat: source.processingFormat.commonFormat, interleaved: source.processingFormat.isInterleaved)
            try output.write(from: buffer)
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> SpeechSample in
            var text: [String] = [], confidences: [Double] = []
            for try await result in transcriber.results where result.isFinal {
                text.append(String(result.text.characters))
                for run in result.text.runs { if let value = run.transcriptionConfidence { confidences.append(value) } }
            }
            return SpeechSample(text: text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                                confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count))
        }
        do {
            _ = try await analyzer.analyzeSequence(from: try AVAudioFile(forReading: excerpt))
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch {
            await analyzer.cancelAndFinishNow(); collector.cancel(); _ = try? await collector.value
            throw error
        }
    }
    public func install(locale: String) async throws {
        let transcriber = try await module(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }
    public func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        let transcriber = try await module(locale: locale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { throw TranscriptionError.missingAssets(locale) }
        let audio = try AVAudioFile(forReading: file)
        guard audio.length > 0 else { return [] }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                guard start.isFinite, end.isFinite, start >= 0, end >= start else { throw TranscriptionError.invalidAudio }
                var segment = TranscriptSegment(start: chunk.start + start, end: chunk.start + end, speakerID: nil, source: chunk.source, text: text)
                segment.words = result.text.runs.compactMap { run in
                    guard let range = run.audioTimeRange, range.start.seconds.isFinite, range.end.seconds.isFinite else { return nil }
                    return TranscriptWord(text: String(result.text[run.range].characters), start: chunk.start + range.start.seconds, end: chunk.start + range.end.seconds)
                }
                segments.append(segment)
            }
            return segments
        }
        do {
            _ = try await analyzer.analyzeSequence(from: audio)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            _ = try? await collector.value
            throw error
        }
    }
    /// Locales usable by this process and locales it can install, in BCP 47 form. Apple Speech
    /// reserves assets per application: a language present on the Mac for another app still needs
    /// an install here, so only the calling process can answer. The app asks the pipeline helper.
    public static func locales() async -> SpeechLocales {
        guard SpeechTranscriber.isAvailable else { return SpeechLocales(installed: [], supported: []) }
        var installed: [String] = []
        for locale in await SpeechTranscriber.installedLocales {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            if await AssetInventory.status(forModules: [module]) == .installed { installed.append(SpeechLanguage.normalized(locale.identifier)) }
        }
        let supported = await SpeechTranscriber.supportedLocales.map { SpeechLanguage.normalized($0.identifier) }
        return SpeechLocales(installed: installed.sorted(), supported: supported.sorted())
    }
    public static func diagnostics() async -> String {
        let supported = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        return "available=\(SpeechTranscriber.isAvailable)\nsupported=\(supported.joined(separator: ","))\ninstalled=\(installed.joined(separator: ","))"
    }
}

public struct SpeechLocales: Codable, Equatable, Sendable {
    public var installed: [String]
    public var supported: [String]
    public init(installed: [String], supported: [String]) { self.installed = installed; self.supported = supported }
}

public enum TranscriptionPipeline {
    public static func run(_ request: TranscriptionRequest, store: SessionStore, recognizer: any SpeechRecognizing, audioOverrides: [UUID: URL] = [:]) async throws -> TranscriptionResult {
        guard !request.chunks.isEmpty, request.chunks.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.duration.isFinite && $0.duration > 0 }) else { throw TranscriptionError.invalidAudio }
        var resolved = request
        var detection: LanguageDetection?
        if request.locale == SpeechLanguage.automatic {
            let found = try await detectLanguage(request, store: store, recognizer: recognizer, audioOverrides: audioOverrides)
            resolved.locale = found.locale; detection = found
        }
        var segments: [TranscriptSegment] = []
        for chunk in request.chunks.sorted(by: { $0.start < $1.start }) {
            try Task.checkCancellation()
            segments += try await recognizer.transcribe(file: audioOverrides[chunk.id] ?? store.audioURL(for: chunk), chunk: chunk, locale: resolved.locale)
        }
        segments.sort { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
        var result = TranscriptionResult(request: resolved, segments: segments)
        result.languageDetection = detection
        return result
    }
    /// Seconds read from the start of each track for detection.
    static let detectionSeconds: Double = 90
    /// Below this many letters, a sample says nothing reliable about its language.
    static let detectionMinimumLetters = 40
    /// Chooses among the candidate locales from the first seconds of each track. The sample is first
    /// transcribed with the fallback locale; its text identifies the language even when the
    /// recognizer is wrong (a French model writes English speech as recognizable English words).
    /// When the text points elsewhere, the sample is transcribed again with that candidate, and the
    /// higher mean word confidence decides. Anything inconclusive keeps the fallback.
    static func detectLanguage(_ request: TranscriptionRequest, store: SessionStore, recognizer: any SpeechRecognizing,
                               audioOverrides: [UUID: URL]) async throws -> LanguageDetection {
        let candidates = SpeechLanguage.oneLocalePerLanguage(request.candidateLocales ?? [])
        let fallback = request.fallbackLocale ?? candidates.first ?? SpeechLanguage.defaultLocale
        guard candidates.count > 1 else { return .init(locale: candidates.first ?? fallback, method: .fallback) }
        let samples = [AudioSource.mic, .system].compactMap { source in request.chunks.filter { $0.source == source }.min(by: { $0.start < $1.start }) }
        func listen(_ locale: String) async throws -> SpeechSample {
            var texts: [String] = [], weighted = 0.0, weight = 0.0
            for chunk in samples {
                try Task.checkCancellation()
                let sample = try await recognizer.sample(file: audioOverrides[chunk.id] ?? store.audioURL(for: chunk), chunk: chunk, locale: locale, seconds: detectionSeconds)
                texts.append(sample.text)
                if let confidence = sample.confidence { let letters = Double(sample.text.count); weighted += confidence * letters; weight += letters }
            }
            return SpeechSample(text: texts.joined(separator: " "), confidence: weight > 0 ? weighted / weight : nil)
        }
        let first = try await listen(fallback)
        guard first.text.filter(\.isLetter).count >= detectionMinimumLetters else { return .init(locale: fallback, method: .fallback, confidence: first.confidence) }
        let recognizerNL = NLLanguageRecognizer()
        recognizerNL.languageConstraints = candidates.map { NLLanguage(rawValue: SpeechLanguage.languageCode(of: $0)) }
        recognizerNL.processString(first.text)
        guard let (language, probability) = recognizerNL.languageHypotheses(withMaximum: 1).first,
              let guess = candidates.first(where: { SpeechLanguage.languageCode(of: $0) == language.rawValue }) else {
            return .init(locale: fallback, method: .fallback, confidence: first.confidence)
        }
        if SpeechLanguage.languageCode(of: guess) == SpeechLanguage.languageCode(of: fallback) {
            return .init(locale: fallback, method: .detected, confidence: first.confidence)
        }
        let second: SpeechSample
        do { second = try await listen(guess) }
        catch TranscriptionError.missingAssets { return .init(locale: fallback, method: .fallback, confidence: first.confidence) }
        switch (first.confidence, second.confidence) {
        case let (a?, b?): return b >= a ? .init(locale: guess, method: .detected, confidence: b) : .init(locale: fallback, method: .detected, confidence: a)
        default: return probability >= 0.8 ? .init(locale: guess, method: .detected, confidence: second.confidence) : .init(locale: fallback, method: .fallback, confidence: first.confidence)
        }
    }
}
extension Recording {
    public mutating func applyTranscription(_ result: TranscriptionResult) throws {
        guard id == result.request.recordingID, audioChunks == result.request.chunks, state != .recording else { throw TranscriptionError.staleResult }
        transcription = .init(engine: result.engine, diarizationEngine: result.diarizationEngine, echoCancellationEngine: result.echoCancellationEngine, locale: result.request.locale, createdAt: result.createdAt, languageDetection: result.languageDetection)
        segments = result.segments; speakers = result.speakers ?? []; absorbedSpeakers = nil; transcriptVersion += 1; transcriptState = .ready; summary = nil
    }
}
