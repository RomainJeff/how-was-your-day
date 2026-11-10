import SwiftUI
import HWYDCore

struct SessionPlayerView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @State private var scrubTime: Double?
    private var position: Double { scrubTime ?? model.playbackTime }
    private var hasAudio: Bool { !recording.audioChunks.isEmpty }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: Studio.Size.body)).foregroundStyle(Studio.onAccent)
                        .frame(width: 34, height: 34).background(Studio.mint, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!hasAudio).opacity(hasAudio ? 1 : 0.4)
                    .accessibilityLabel(model.isPlaying ? "Mettre en pause" : "Lire les pistes")
                VStack(spacing: 5) {
                    track(.mic, label: String(localized: "Micro"), icon: "mic", color: Studio.mint)
                    track(.system, label: String(localized: "Système"), icon: "speaker.wave.2", color: Studio.muted)
                }
                // Assistive technologies adjust the position here, in 5 s steps.
                VStack(alignment: .trailing, spacing: 2) {
                    Text(timeLabel(position)).foregroundStyle(Studio.text)
                    Text(timeLabel(recording.duration)).foregroundStyle(Studio.muted)
                }.font(.system(size: Studio.Size.caption, design: .monospaced))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Position de lecture")
                    .accessibilityValue("\(timeLabel(position)) sur \(timeLabel(recording.duration))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: seek(by: 5)
                        case .decrement: seek(by: -5)
                        @unknown default: break
                        }
                    }
            }
            if let error = model.waveformError { Text(error).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted) }
        }.padding(12).background(Studio.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Studio.line.opacity(0.6)))
            .padding(.vertical, 4)
            // Keyboard path once the player has focus: arrows move both tracks by 5 s.
            .focusable(hasAudio)
            .onKeyPress(.leftArrow) { seek(by: -5); return .handled }
            .onKeyPress(.rightArrow) { seek(by: 5); return .handled }
    }
    private func seek(by delta: Double) {
        guard hasAudio else { return }
        model.seekPlayback(to: min(recording.duration, max(0, model.playbackTime + delta)))
    }
    private func track(_ source: AudioSource, label: String, icon: String, color: Color) -> some View {
        let available = recording.audioChunks.contains { $0.source == source }
        let audible = model.isTrackAudible(source)
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 18).help(label).accessibilityHidden(true)
            HStack(spacing: 4) {
                trackButton("S", help: String(localized: "Solo"), label: label, active: model.soloTracks.contains(source)) { model.toggleSolo(source) }
                trackButton("M", help: String(localized: "Muet"), label: label, active: model.mutedTracks.contains(source)) { model.toggleMute(source) }
            }.disabled(!available)
            ZStack {
                TrackWaveform(peaks: model.trackEnvelopes[source]?.peaks ?? [], progress: position / max(recording.duration, 1), color: color)
                    .opacity(audible ? 1 : 0.25)
                if model.trackEnvelopes[source] == nil {
                    Text(available ? (model.waveformLoading ? "Calcul de la forme d’onde…" : "Forme d’onde indisponible") : "Aucune piste audio")
                        .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                }
            }.frame(height: 28).frame(maxWidth: .infinity)
                .background(Studio.inset, in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle().fill(Studio.text.opacity(0.65)).frame(width: 1)
                            .offset(x: geo.size.width * min(1, max(0, position / max(1, recording.duration))))
                    }.allowsHitTesting(false)
                }
                .overlay {
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in scrubTime = min(1, max(0, value.location.x / max(1, geo.size.width))) * recording.duration }
                            .onEnded { _ in if let target = scrubTime { model.seekPlayback(to: target); scrubTime = nil } })
                    }.allowsHitTesting(available)
                }
                .accessibilityLabel("Forme d’onde \(label)")
        }
    }
    private func trackButton(_ title: String, help: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: Studio.Size.caption, weight: .semibold)).frame(width: 26, height: 20)
                .foregroundStyle(active ? Studio.onAccent : Studio.muted)
                .background(active ? Studio.mint : Studio.inset, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).help("\(help) : \(label)")
            .accessibilityLabel("\(help) \(label)").accessibilityValue(active ? "Activé" : "Désactivé")
    }
}

struct TrackWaveform: View {
    let peaks: [Float]
    var progress: Double
    var color: Color
    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let bars = max(1, min(peaks.count, Int(size.width / 3)))
            for bar in 0..<bars {
                let first = bar * peaks.count / bars
                let last = max(first + 1, (bar + 1) * peaks.count / bars)
                let peak = peaks[first..<last].max() ?? 0
                // Square root gives quiet speech visibility; silence stays on the baseline.
                let height = max(1, min(1, sqrt(Double(peak))) * (size.height - 6))
                let x = Double(bar) * size.width / Double(bars)
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(Double(bar) / Double(bars) <= progress ? 0.95 : 0.38)))
            }
        }.padding(.horizontal, 4).accessibilityHidden(true)
    }
}
