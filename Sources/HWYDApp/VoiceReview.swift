import Foundation
import Observation
import HWYDCore

/// Fast-changing playback values. Observation tracks them per property, so a 5 Hz clock
/// only invalidates the views that read `time`, not every `AppModel` observer.
@Observable @MainActor final class PlaybackState {
    var time: Double = 0
    var isPlaying = false
    /// Speaker whose passages play back to back, if any.
    var voiceID: UUID?
    /// Segments heard at `time`. Updated only when the set changes.
    var activeSegmentIDs: Set<UUID> = []
    /// Incremented on each user-started playback, so the transcript resumes following.
    var generation = 0
}

extension AppModel {
    var voiceEditingLocked: Bool {
        guard let item = selected else { return true }
        return item.id == processingID || item.state == .recording
    }
    func updatePlaybackFocus() {
        let ids = selected?.segmentIDs(at: playbackTime) ?? []
        if ids != playback.activeSegmentIDs { playback.activeSegmentIDs = ids }
    }
    /// Plays only this voice's passages, on its own track. A second click stops.
    func toggleVoicePlayback(_ speakerID: UUID) {
        if playback.voiceID == speakerID { stopPlayback(); return }
        guard let item = selected, let store, !item.audioChunks.isEmpty else {
            notice = "Aucun fichier audio disponible pour cette session."; return
        }
        guard let voice = item.voiceOverview.first(where: { $0.id == speakerID }), !voice.spans.isEmpty else {
            notice = "Aucun passage attribué à cette voix."; return
        }
        stopPlayback()
        do {
            try player.start(playlist: VoicePlaylist(spans: voice.spans), source: voice.speaker.source, chunks: item.audioChunks, store: store)
            playbackTime = player.position; isPlaying = true
            playback.voiceID = speakerID; playback.generation += 1
            updatePlaybackFocus()
        } catch { errorMessage = "Lecture impossible : \(error.localizedDescription)" }
    }
    /// "This voice is the same person as that one." Transcript correction only, no enrollment.
    func mergeSpeaker(_ sourceID: UUID, into targetID: UUID) {
        guard let id = selectedID, !voiceEditingLocked, var item = selected else { return }
        let sourceLabel = item.speakers.first { $0.id == sourceID }?.label ?? ""
        do {
            try item.mergeSpeaker(sourceID, into: targetID)
            if playback.voiceID == sourceID { stopPlayback() }
            update(id) { $0 = item }
            let name = item.speakers.first { $0.id == targetID }?.label ?? ""
            notice = "\(sourceLabel) regroupée avec \(name) dans cette session. Aucune empreinte vocale créée."
        } catch { errorMessage = error.localizedDescription }
    }
    /// Names a voice after a known person. Does not enroll and does not read any voice print.
    func linkSpeaker(_ speakerID: UUID, to person: VoicePerson) {
        guard let id = selectedID, !voiceEditingLocked, var item = selected else { return }
        do {
            try item.linkSpeaker(speakerID, to: person)
            update(id) { $0 = item }
            notice = "Voix nommée \(person.name) dans toute cette session. Aucune empreinte vocale créée."
        } catch { errorMessage = error.localizedDescription }
    }
}
