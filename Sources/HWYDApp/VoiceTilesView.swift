import SwiftUI
import HWYDCore

/// One tile per detected voice: listen to its passages, then name or regroup it once for the whole session.
struct VoiceTilesView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    var body: some View {
        let voices = recording.voiceOverview
        let pending = voices.filter { $0.state != .confirmed }.count
        let playingID = model.playback.voiceID
        let locked = model.voiceEditingLocked
        let known = model.people.filter { !$0.opposed }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Eyebrow(text: voices.isEmpty ? "Voix" : pending == 0 ? "Voix détectées · \(voices.count)" : "Voix détectées · \(pending) à nommer")
                if !voices.isEmpty {
                    Text("Cliquez une voix pour écouter ses passages. Glissez-la sur une autre pour regrouper une même personne.")
                        .font(.system(size: 10)).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Button("Identité des voix…") { model.showVoiceIdentity = true }.buttonStyle(StudioButtonStyle(compact: true))
                    .disabled(recording.isDemo || model.modelWorkBusy)
            }
            if !voices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(voices) { voice in
                            VoiceTile(voice: voice, playing: playingID == voice.id, canPlay: !recording.audioChunks.isEmpty && !voice.spans.isEmpty,
                                      locked: locked, others: recording.speakers.filter { $0.id != voice.id }, people: known,
                                      proposed: voice.speaker.proposedIdentity.flatMap { match in known.first { $0.id == match.personID } })
                        }
                    }.padding(.vertical, 1)
                }
            }
        }
    }
}

private struct VoiceTile: View {
    @EnvironmentObject var model: AppModel
    let voice: VoiceOverview
    let playing: Bool
    let canPlay: Bool
    let locked: Bool
    let others: [Speaker]
    let people: [VoicePerson]
    let proposed: VoicePerson?
    @State private var targeted = false
    private var accent: Color { voice.state == .confirmed ? Studio.mint : Studio.copper }
    var body: some View {
        HStack(spacing: 0) {
            Button { model.toggleVoicePlayback(voice.id) } label: {
                HStack(spacing: 9) {
                    Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 9))
                        .foregroundStyle(playing ? Studio.onAccent : accent)
                        .frame(width: 24, height: 24).background(playing ? Studio.mint : accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(voice.speaker.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(sourceLabel(voice.speaker.source)) · \(speechLabel(voice.speechDuration))").font(.system(size: 10)).foregroundStyle(Studio.muted).lineLimit(1)
                    }
                }.padding(.leading, 10).padding(.trailing, 6).frame(maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canPlay)
                .help(canPlay ? (playing ? "Arrêter l’écoute" : "Écouter uniquement les passages de cette voix") : "Aucun audio pour cette voix")
                .accessibilityLabel(playing ? "Arrêter l’écoute de \(voice.speaker.label)" : "Écouter \(voice.speaker.label)")
            Rectangle().fill(Studio.line).frame(width: 0.5).padding(.vertical, 8)
            Menu { menuContent } label: {
                Text(actionTitle).font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
            } primaryAction: { primaryAction() }
                .menuStyle(.borderlessButton).menuIndicator(.visible).controlSize(.small).font(.system(size: 11, weight: .medium)).tint(accent).fixedSize()
                .padding(.horizontal, 10).frame(maxHeight: .infinity).contentShape(Rectangle())
                .disabled(locked)
                .help(stateHelp)
        }
        .frame(height: 44)
        .background(playing ? Studio.mint.opacity(0.1) : Studio.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? Studio.mint : accent.opacity(voice.state == .confirmed ? 0.35 : 0.7),
                                                                style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: voice.state == .unidentified && !targeted ? [4, 3] : [])))
        .overlay(alignment: .topTrailing) { stateDot.padding(6) }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .draggable(voice.id.uuidString) {
            Label(voice.speaker.label, systemImage: "person.wave.2").font(.system(size: 12, weight: .medium)).padding(8)
                .background(Studio.surface, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard !locked, let first = items.first, let source = UUID(uuidString: first), source != voice.id,
                  others.contains(where: { $0.id == source }) else { return false }
            model.mergeSpeaker(source, into: voice.id)
            return true
        } isTargeted: { targeted = $0 && !locked }
    }
    private var stateDot: some View {
        Circle().fill(voice.state == .confirmed ? Studio.mint : Studio.copper).frame(width: 6, height: 6)
            .opacity(voice.state == .unidentified ? 0.6 : 1)
            .accessibilityLabel(stateHelp)
    }
    private var actionTitle: String {
        switch voice.state { case .unidentified: "Nommer"; case .proposed: proposed == nil ? "Nommer" : "Confirmer"; case .confirmed: "Modifier" }
    }
    private var stateHelp: String {
        switch voice.state {
        case .unidentified: "Voix non identifiée"
        case .proposed: "Proposition à confirmer" + (voice.speaker.proposedIdentity.map { String(format: " (score %.2f)", $0.score) } ?? "")
        case .confirmed: "Voix confirmée"
        }
    }
    private func primaryAction() {
        if voice.state == .proposed, let proposed { model.linkSpeaker(voice.id, to: proposed) }
        else { model.beginSpeakerEdit(voice.speaker) }
    }
    @ViewBuilder private var menuContent: some View {
        if voice.state == .proposed, let proposed {
            Button("Confirmer : \(proposed.name)") { model.linkSpeaker(voice.id, to: proposed) }
        }
        Button("Saisir un nom…") { model.beginSpeakerEdit(voice.speaker) }
        if !others.isEmpty {
            Section("Même personne que") {
                ForEach(others) { other in
                    // Two unnamed voices on different tracks cannot share a name yet.
                    Button("\(other.label) · \(sourceLabel(other.source))") { model.mergeSpeaker(voice.id, into: other.id) }
                        .disabled(other.source != voice.speaker.source && !other.confirmed && !voice.speaker.confirmed)
                }
            }
        }
        if !people.isEmpty {
            Section("Personnes connues") {
                ForEach(people) { person in Button(person.name) { model.linkSpeaker(voice.id, to: person) } }
            }
        }
    }
}

func sourceLabel(_ source: AudioSource) -> String { source == .mic ? "micro" : "système" }
func speechLabel(_ seconds: Double) -> String {
    let value = Int(seconds.rounded())
    return value < 60 ? "\(value) s" : "\(value / 60) min \(String(format: "%02d", value % 60))"
}
