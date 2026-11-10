import SwiftUI
import HWYDCore

struct CalendarSettingsView: View {
    @ObservedObject var calendar: CalendarIntegration
    @FocusState private var exclusionsFocused: Bool
    /// Exclusions as last applied, so leaving the field only saves a real change.
    @State private var appliedExclusions: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(Studio.mint)
                Eyebrow(text: String(localized: "Calendriers et rappels"))
                HelpButton(text: String(localized: "Google Calendar passe par macOS : ajoutez votre compte Google dans l’app Calendrier → Ajouter un compte, puis autorisez HWYD. Les comptes Apple et Outlook synchronisés sont aussi disponibles. Aucun événement n’est modifié."))
            }
            Text(calendar.status).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(calendar.busy ? "Connexion…" : "Autoriser les calendriers") { Task { await calendar.connect() } }.disabled(calendar.busy)
                Button("Actualiser") { Task { await calendar.refresh() } }
            }.buttonStyle(StudioButtonStyle())
            if calendar.enabled {
                Toggle("Suivre les calendriers sélectionnés", isOn: Binding(get: { calendar.enabled }, set: { calendar.enabled = $0; calendar.saveSettings() }))
                ForEach(calendar.calendars) { item in
                    Toggle("\(item.title) · \(item.account)", isOn: Binding(get: { calendar.selectedCalendars.contains(item.id) }, set: { enabled in
                        if enabled { calendar.selectedCalendars.insert(item.id) } else { calendar.selectedCalendars.remove(item.id) }
                        calendar.saveSettings()
                    })).font(.system(size: Studio.Size.caption))
                }
                HStack(spacing: 6) {
                    TextField("Mots-clés exclus, séparés par des virgules", text: $calendar.excludedKeywords)
                        .textFieldStyle(.roundedBorder).focused($exclusionsFocused).onSubmit { applyExclusions() }
                    HelpButton(text: String(localized: "Exclusions sur le titre, appliquées en quittant le champ. Journées entières, événements annulés et invitations refusées sont ignorés."))
                }
                HStack(spacing: 6) {
                    Toggle("Rappeler avant les réunions", isOn: Binding(get: { calendar.reminders }, set: { value in
                        if value { Task { await calendar.enableReminders() } }
                        else { calendar.reminders = false; calendar.saveSettings() }
                    })).disabled(calendar.busy)
                    HelpButton(text: String(localized: "« Rejoindre et enregistrer » ouvre la visio et lance la capture ; « Enregistrer sans rejoindre » lance seulement la capture. Sans clic, aucun enregistrement. Les rappels des 7 prochains jours sont préparés tant que HWYD tourne ; un rappel peut s’afficher après sa fermeture."))
                }
                Picker("Prévenir", selection: Binding(get: { calendar.leadMinutes }, set: { calendar.leadMinutes = $0; calendar.saveSettings() })) {
                    Text("Au début").tag(0)
                    ForEach([1, 5, 10, 15], id: \.self) { Text("\($0) min avant").tag($0) }
                }
                Button("Tester une notification") { Task { await calendar.sendTestReminder() } }
                    .buttonStyle(StudioButtonStyle()).disabled(!calendar.reminders)
                Text(calendar.notificationStatus).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
            .onAppear { appliedExclusions = calendar.excludedKeywords }
            .onChange(of: exclusionsFocused) { _, focused in if !focused { applyExclusions() } }
    }
    private func applyExclusions() {
        guard calendar.excludedKeywords != appliedExclusions else { return }
        appliedExclusions = calendar.excludedKeywords
        calendar.saveSettings()
    }
}
struct UpcomingMeetingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var calendar: CalendarIntegration
    var body: some View {
        if calendar.enabled {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: String(localized: "À venir"))
                if calendar.upcoming.isEmpty { Text(calendar.status).font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted) }
                ForEach(Array(calendar.upcoming.prefix(4))) { event in
                    HStack(spacing: 14) {
                        Image(systemName: "calendar").foregroundStyle(Studio.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.system(size: Studio.Size.body, weight: .medium)).lineLimit(2)
                            Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarTitle)").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                        }
                        Spacer()
                        Group {
                            if event.meetingURL != nil {
                                Button(String(localized: "calendar.record", defaultValue: "Enregistrer", comment: "Records an upcoming meeting without joining it")) { calendar.activate(event.id, join: false) }
                                    .buttonStyle(StudioButtonStyle()).help("Lance la capture sans ouvrir la visio")
                                Button("Rejoindre et enregistrer") { calendar.activate(event.id, join: true) }
                                    .buttonStyle(StudioButtonStyle(primary: true)).help("Ouvre la visio et lance la capture")
                            } else {
                                Button(String(localized: "calendar.record", defaultValue: "Enregistrer", comment: "Records an upcoming meeting without joining it")) { calendar.activate(event.id, join: false) }.buttonStyle(StudioButtonStyle())
                            }
                        }.disabled(model.activeCaptureID != nil || model.isStarting)
                    }.padding(14).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
