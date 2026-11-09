import SwiftUI
import HWYDCore

struct SegmentSplitView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let recordingID: UUID
    let segment: TranscriptSegment
    @State private var selectedIndex: Int?
    private var words: [TranscriptWord] { segment.words ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Découper le passage").font(.system(size: Studio.Size.heading, weight: .semibold))
            Text("Choisissez le début de la seconde partie. Vous pourrez ensuite attribuer une voix à chaque passage.")
                .font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segment.splitIndices, id: \.self) { index in
                        Button { selectedIndex = index } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedIndex == index ? "largecircle.fill.circle" : "circle")
                                Text(timeLabel(words[index].start)).font(.system(size: Studio.Size.caption, design: .monospaced))
                                Text(words[index..<min(index + 7, words.count)].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines))
                                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(size: Studio.Size.body)).padding(10)
                                .background(selectedIndex == index ? Studio.line : Studio.surface, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(height: 190)
            if let index = selectedIndex {
                VStack(alignment: .leading, spacing: 10) {
                    Text("PREMIÈRE PARTIE").font(.system(size: Studio.Size.caption, weight: .semibold)).foregroundStyle(Studio.muted)
                    Text(words[..<index].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)).lineLimit(3)
                    Text("SECONDE PARTIE").font(.system(size: Studio.Size.caption, weight: .semibold)).foregroundStyle(Studio.mint)
                    Text(words[index...].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)).lineLimit(3)
                }.font(.system(size: Studio.Size.body)).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Découper") {
                    if let selectedIndex, model.splitSegment(segment, beforeWord: selectedIndex, recordingID: recordingID) { dismiss() }
                }.buttonStyle(StudioButtonStyle(primary: true))
                    .disabled(selectedIndex == nil || model.processingID == recordingID)
            }
        }.padding(26).frame(width: 520).background(Studio.background).foregroundStyle(Studio.text)
    }
}
