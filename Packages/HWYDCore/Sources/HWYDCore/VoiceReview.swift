import Foundation

/// A stretch of one voice on its own track, in recording time.
public struct VoiceSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

/// Per-voice review data for one recording. Derived from segments, never persisted.
public struct VoiceOverview: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case unidentified, proposed, confirmed }
    public var speaker: Speaker
    public var segmentCount: Int
    public var speechDuration: Double
    public var spans: [VoiceSpan]
    public var id: UUID { speaker.id }
    public var state: State {
        if speaker.confirmed { return .confirmed }
        return speaker.proposedIdentity == nil ? .unidentified : .proposed
    }
}

/// Back-to-back playback of one voice. `at` is the offset in the playlist, `from`/`to` in the recording.
public struct VoicePlaylist: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var from: Double
        public var to: Double
        public var at: Double
    }
    public private(set) var entries: [Entry] = []
    public private(set) var length: Double = 0
    /// Overlapping spans are merged. A short silence separates distinct passages.
    public init(spans: [VoiceSpan], gap: Double = 0.35) {
        var merged: [VoiceSpan] = []
        for span in spans.filter({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            let span = VoiceSpan(start: max(0, span.start), end: span.end)
            if let last = merged.indices.last, span.start <= merged[last].end { merged[last].end = max(merged[last].end, span.end) }
            else { merged.append(span) }
        }
        var cursor = 0.0
        for (index, span) in merged.enumerated() {
            if index > 0 { cursor += gap }
            entries.append(Entry(from: span.start, to: span.end, at: cursor))
            cursor += span.end - span.start
        }
        length = cursor
    }
    /// Recording time heard after `elapsed` seconds of playlist. Gaps report the next passage.
    public func recordingTime(atElapsed elapsed: Double) -> Double {
        for entry in entries {
            if elapsed < entry.at { return entry.from }
            if elapsed < entry.at + (entry.to - entry.from) { return entry.from + (elapsed - entry.at) }
        }
        return entries.last?.to ?? 0
    }
}

public enum VoiceReviewError: LocalizedError, Equatable {
    case unnamedMerge, opposedPerson, sameVoice
    public var errorDescription: String? {
        switch self {
        case .unnamedMerge: "Ces voix sont sur deux pistes différentes. Nommez d’abord l’une des deux."
        case .opposedPerson: "Cette personne est exclue de la reconnaissance."
        case .sameVoice: "Choisissez une autre voix."
        }
    }
}

extension Recording {
    /// One entry per detected voice, in speaker order.
    public var voiceOverview: [VoiceOverview] {
        var bySpeaker: [UUID: [TranscriptSegment]] = [:]
        for segment in segments { if let id = segment.speakerID { bySpeaker[id, default: []].append(segment) } }
        return speakers.map { speaker in
            let owned = bySpeaker[speaker.id] ?? []
            return VoiceOverview(speaker: speaker, segmentCount: owned.count,
                                 speechDuration: owned.reduce(0) { $0 + max(0, $1.end - $1.start) },
                                 spans: owned.map { VoiceSpan(start: $0.start, end: $0.end) })
        }
    }

    /// The user states that two detected voices are one person.
    /// Same track: segments move to the target and the duplicate cluster disappears.
    /// Different tracks: clusters stay separate (channel categories differ) and share the name.
    /// This is a transcript correction only. It never creates or changes a voice print.
    public mutating func mergeSpeaker(_ sourceID: UUID, into targetID: UUID) throws {
        guard sourceID != targetID else { throw VoiceReviewError.sameVoice }
        guard let s = speakers.firstIndex(where: { $0.id == sourceID }),
              let t = speakers.firstIndex(where: { $0.id == targetID }) else { throw StoreError.notFound }
        let source = speakers[s], target = speakers[t]
        if source.source == target.source {
            for index in segments.indices where segments[index].speakerID == sourceID { segments[index].speakerID = targetID }
            if !target.confirmed && source.confirmed { adoptIdentity(of: source, at: t) }
            speakers.remove(at: s)
        } else {
            guard let identity = target.confirmed ? target : source.confirmed ? source : nil else { throw VoiceReviewError.unnamedMerge }
            adoptIdentity(of: identity, at: s)
            adoptIdentity(of: identity, at: t)
        }
        transcriptVersion += 1
        summary = nil
    }

    /// Names a voice after a known person. Linking is not enrollment: no vector is read or written.
    public mutating func linkSpeaker(_ id: UUID, to person: VoicePerson) throws {
        guard !person.opposed else { throw VoiceReviewError.opposedPerson }
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw StoreError.invalidName }
        speakers[index].label = name; speakers[index].personID = person.id
        speakers[index].confirmed = true; speakers[index].proposedIdentity = nil
        transcriptVersion += 1
        summary = nil
    }

    private mutating func adoptIdentity(of identity: Speaker, at index: Int) {
        speakers[index].label = identity.label; speakers[index].personID = identity.personID
        speakers[index].confirmed = true; speakers[index].proposedIdentity = nil
    }

    /// Segments heard at `time`, on any track.
    public func segmentIDs(at time: Double) -> Set<UUID> {
        Set(segments.lazy.filter { $0.start <= time && time < $0.end }.map(\.id))
    }
}
