import SwiftUI
import HWYDCore

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "Général", calendar = "Calendrier", audio = "Audio et voix", summary = "Synthèse", data = "Données et agents"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "circle.lefthalf.filled"
        case .calendar: "calendar"
        case .audio: "waveform"
        case .summary: "sparkles"
        case .data: "internaldrive"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Personnalisez votre espace de travail."
        case .calendar: "Retrouvez vos réunions et choisissez quand recevoir un rappel."
        case .audio: "Transcription, séparation des voix et personnes mémorisées sur ce Mac."
        case .summary: "Choisissez le modèle qui résume vos sessions, sur ce Mac ou chez un fournisseur."
        case .data: "Retrouvez vos fichiers et contrôlez l’accès de vos outils."
        }
    }
}

/// Settings apply as they change: there is no save button.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKeyDraft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow(text: "Réglages")
                    Text(model.settingsCategory.rawValue).font(.system(size: Studio.Size.title, weight: .semibold))
                    Text(model.settingsCategory.subtitle).font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button { model.showSettings = false } label: { Label("Retour", systemImage: "arrow.left") }
                    .buttonStyle(StudioButtonStyle()).accessibilityLabel("Revenir à la session ou à la bibliothèque")
            }.padding(30)
            Rectangle().fill(Studio.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }.frame(maxWidth: 820, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }.id(model.settingsCategory)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: model.summaryEnabled) { _, _ in model.saveSummarySettings() }
            .onChange(of: model.summaryEndpoint) { _, _ in model.saveSummarySettings() }
            .onChange(of: model.summaryModel) { _, _ in model.saveSummarySettings() }
            .onChange(of: model.summaryContextTokens) { _, _ in model.saveSummarySettings() }
            .onChange(of: model.summaryReasoningDisabled) { _, _ in model.saveSummarySettings() }
            .onChange(of: model.summaryRemoteModel) { _, _ in model.saveSummarySettings() }
            .onChange(of: model.summaryAgentCommand) { _, _ in model.saveSummarySettings() }
            .onChange(of: model.summaryAgentDirectory) { _, _ in model.saveSummarySettings() }
            .onDisappear { model.saveSummarySettings() }
            .task(id: model.settingsCategory == .summary ? model.summaryService.rawValue + String(model.summaryKeyStored) : "") {
                guard model.settingsCategory == .summary else { return }
                if model.summaryService == .agent { model.detectSummaryAgents() }
                else if model.summaryAvailableModels.isEmpty { model.refreshSummaryModels() }
            }
    }
    @ViewBuilder private var content: some View {
        switch model.settingsCategory {
        case .general:
            section("Apparence", symbol: "circle.lefthalf.filled") {
                row("Thème") {
                    Picker("Thème", selection: $model.appearancePreference) {
                        ForEach(AppearancePreference.allCases) { preference in Text(preference.title).tag(preference) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
            }
            section("Découvrir HWYD", symbol: "rectangle.stack") {
                row("Sessions fictives, sans micro") {
                    Button(model.isDemoMode ? "Quitter les exemples" : "Explorer des exemples") {
                        model.showSettings = false
                        if model.isDemoMode { model.leaveDemo() } else { model.enterDemo() }
                    }.buttonStyle(StudioButtonStyle(compact: true)).disabled(model.modelWorkBusy || model.activeCaptureID != nil || model.hasUnsavedChanges)
                }
            }
        case .calendar:
            CalendarSettingsView(calendar: model.calendar).disabled(model.isDemoMode)
        case .audio:
            section("Transcription", symbol: "text.bubble") {
                row("Langue") { Text("Français").font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted) }
                row("Modèle Apple Speech", help: "L’installation peut télécharger le modèle Apple. Aucun audio n’est envoyé pour la transcription.") {
                    installControl(ready: model.speechModelReady, busy: model.isInstallingModel) { model.installSpeechModel() }
                }
            }
            section("Séparation des voix", symbol: "person.2.wave.2") {
                toggleRow("Séparer les voix après transcription", isOn: $model.diarizationEnabled).disabled(model.modelWorkBusy || model.isDemoMode)
                row("Modèles de voix · Community-1", help: "Traitement local par piste. Les modèles se téléchargent une fois ; aucune empreinte personnelle n’est créée sans enrôlement explicite.") {
                    installControl(ready: model.diarizerReady, busy: model.isInstallingDiarizer) { model.installDiarizer() }
                }
            }
            section("Personnes mémorisées", symbol: "person.crop.circle", help: "Les empreintes restent dans le trousseau de ce Mac, jamais dans les exports. Une voix apprise en salle reste distincte de son empreinte en visio. Mémorisez une voix depuis une session.") {
                if model.people.isEmpty {
                    row("Aucune voix mémorisée") { EmptyView() }
                }
                ForEach(model.people) { person in
                    row(person.name) {
                        Text(person.opposed ? "Opposition active" : channels(person)).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                        Button(person.opposed ? "Réessayer l’effacement" : "Effacer et opposer") {
                            var opposed = person; opposed.opposed = true; opposed.consentedAt = nil
                            model.runVoice(command: "forget-voice", person: opposed)
                        }.buttonStyle(StudioButtonStyle(compact: true))
                    }
                }
            }.disabled(model.voiceBusy || model.isDemoMode)
        case .summary:
            section("Synthèse", symbol: "sparkles", help: "Chaque synthèse est lancée manuellement depuis la session. Les étapes validées sont conservées pour reprendre après une interruption.") {
                toggleRow("Activer la synthèse", isOn: $model.summaryEnabled)
                row("Fournisseur", help: "Le serveur local garde le transcript sur ce Mac. Un agent ACP (Claude Code, Codex…) rédige avec votre propre contexte. Avec Mistral, OpenAI, Anthropic ou Google Gemini, le transcript est envoyé au fournisseur à chaque synthèse, une fois sa clé API enregistrée.") {
                    Picker("Fournisseur", selection: Binding(get: { model.summaryService }, set: { model.selectSummaryService($0) })) {
                        ForEach(SummaryService.allCases) { service in Text(service.displayName).tag(service) }
                    }.labelsHidden().frame(width: 200)
                }
                switch model.summaryService {
                case .local: localSummaryRows
                case .agent: agentSummaryRows
                default: remoteSummaryRows
                }
            }.disabled(model.isDemoMode)
        case .data:
            section("Données locales", symbol: "internaldrive") {
                row("Dossier de données") {
                    Button("Ouvrir") { NSWorkspace.shared.open(model.dataDirectory) }.buttonStyle(StudioButtonStyle(compact: true))
                }
            }
            section("Agents et exports", symbol: "externaldrive.connected.to.line.below") {
                toggleRow("Autoriser les agents à modifier notes et noms", help: "MCP reste en lecture seule par défaut. Les écritures exigent aussi --allow-write au lancement du serveur.", isOn: Binding(get: { model.mcpWritesEnabled }, set: { model.setMCPWrites($0) }))
                row("Dossier de publication") {
                    if !model.exportDirectory.isEmpty {
                        Text(model.exportDirectory).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Button("Choisir…") { model.chooseExportDirectory() }.buttonStyle(StudioButtonStyle(compact: true))
                }
            }.disabled(model.isDemoMode)
        }
    }
    @ViewBuilder private var localSummaryRows: some View {
        row("Adresse du serveur local", help: "LM Studio ou Ollama, API OpenAI-compatible et JSON Schema requis. Seules les adresses de boucle locale sont acceptées.") {
            TextField("http://127.0.0.1:1234/v1", text: $model.summaryEndpoint).textFieldStyle(.roundedBorder).frame(width: 280)
        }
        row("Modèle chargé") {
            TextField("Identifiant du modèle", text: $model.summaryModel).textFieldStyle(.roundedBorder).frame(width: 280)
        }
        row("Contexte chargé dans le serveur", help: "Indiquez le contexte chargé dans LM Studio. HWYD traite les longues sessions par portions bornées et rédige chaque sujet à partir de ses sources. Un grand contexte serveur n’augmente pas automatiquement la taille des requêtes. Pour limiter la mémoire, chargez un seul modèle et une seule requête à la fois : ce réglage ne modifie pas la mémoire allouée par le serveur.") {
            Picker("Contexte chargé dans le serveur", selection: $model.summaryContextTokens) {
                Text("16k tokens").tag(16384)
                Text("32k tokens").tag(32768)
                Text("64k tokens").tag(65536)
                Text("128k tokens").tag(131072)
            }.labelsHidden().frame(width: 150)
        }
        toggleRow("Désactiver le raisonnement étendu", help: "Peut réduire le temps de génération. À activer si le modèle ne renvoie pas de synthèse avec les sorties structurées. Le serveur doit accepter cette option.", isOn: $model.summaryReasoningDisabled)
    }
    @ViewBuilder private var agentSummaryRows: some View {
        row("Agent", help: "Agent compatible ACP (Agent Client Protocol) installé et connecté sur ce Mac. La commande s’exécute dans un shell de connexion ; vous pouvez en saisir une autre.") {
            Menu {
                ForEach(ACPAgentPreset.all) { preset in
                    let installed = model.summaryDetectedAgents.contains(preset.command)
                    Button {
                        model.summaryAgentCommand = preset.command
                    } label: {
                        if model.summaryAgentCommand == preset.command { Label(preset.name, systemImage: "checkmark") }
                        else { Text(installed ? preset.name : preset.name + " (non installé)") }
                    }
                }
            } label: {
                Text(ACPAgentPreset.all.first { $0.command == model.summaryAgentCommand }?.name ?? "Autre")
            }.fixedSize()
            TextField("claude-agent-acp", text: $model.summaryAgentCommand).textFieldStyle(.roundedBorder).frame(width: 200)
                .font(.system(size: Studio.Size.caption, design: .monospaced))
                .accessibilityLabel("Commande de l’agent")
        }
        row("Dossier de travail", help: "L’agent démarre dans ce dossier. Choisissez celui où il trouve son contexte : instructions, mémoire, notes.") {
            Text(model.summaryAgentDirectory).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.middle)
            Button("Choisir…") { model.chooseSummaryAgentDirectory() }.buttonStyle(StudioButtonStyle(compact: true))
        }
        Text("L’agent reçoit le titre, le transcript et les noms des voix, et peut consulter son propre contexte pour situer les personnes et les projets. Ce qu’il en tire apparaît dans une section Contexte, à part. Il remet la synthèse à HWYD par l’outil submit_summary ; HWYD refuse ses demandes d’écriture, de suppression ou d’exécution. Les autorisations déjà accordées dans la configuration de l’agent restent les siennes.")
            .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Studio.line.opacity(0.55)).frame(height: 0.5) }
    }
    @ViewBuilder private var remoteSummaryRows: some View {
        let name = model.summaryService.displayName
        row("Clé API", help: "Stockée dans le trousseau de ce Mac, jamais dans les réglages, les exports ou la base. Les requêtes sont facturées sur votre compte \(name).") {
            if model.summaryKeyStored {
                Text("Enregistrée").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                Button("Supprimer") { model.removeSummaryKey() }.buttonStyle(StudioButtonStyle(compact: true))
            } else {
                SecureField("Clé \(name)", text: $apiKeyDraft).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { model.saveSummaryKey(apiKeyDraft); apiKeyDraft = "" }
                Button("Enregistrer") { model.saveSummaryKey(apiKeyDraft); apiKeyDraft = "" }
                    .buttonStyle(StudioButtonStyle(compact: true)).disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        row("Modèle", help: "Liste des modèles proposés par \(name) pour votre clé. Vous pouvez aussi saisir un identifiant. Le contexte des modèles hébergés est bien plus grand que celui d’un serveur local : une session d’une heure tient en quelques requêtes.") {
            if model.summaryModelsLoading { ProgressView().controlSize(.small) }
            TextField(model.summaryKeyStored ? "Choisissez un modèle" : model.summaryService.defaultModel, text: $model.summaryRemoteModel)
                .textFieldStyle(.roundedBorder).frame(width: 220)
                .textInputSuggestions {
                    ForEach(modelSuggestions, id: \.self) { id in Text(id).textInputCompletion(id) }
                }
            Menu {
                ForEach(model.summaryAvailableModels, id: \.self) { id in
                    Button(id) { model.summaryRemoteModel = id }
                }
                if !model.summaryAvailableModels.isEmpty { Divider() }
                Button("Actualiser la liste") { model.refreshSummaryModels() }.disabled(!model.summaryKeyStored || model.summaryModelsLoading)
            } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(model.summaryKeyStored ? "Modèles disponibles chez \(name)" : "Enregistrez une clé pour afficher les modèles")
                .accessibilityLabel("Modèles disponibles")
        }
        Text("À chaque synthèse, le titre, le transcript et les noms des voix sont envoyés à \(name), dont les conditions de traitement et de conservation s’appliquent. Les notes, l’audio et les empreintes vocales restent sur ce Mac.")
            .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Studio.line.opacity(0.55)).frame(height: 0.5) }
    }
    /// Models matching what is typed, at most ten, for the field's completion list.
    private var modelSuggestions: [String] {
        let typed = model.summaryRemoteModel.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = typed.isEmpty ? model.summaryAvailableModels : model.summaryAvailableModels.filter { $0.lowercased().contains(typed) && $0.lowercased() != typed }
        return Array(matches.prefix(10))
    }
    private func channels(_ person: VoicePerson) -> String {
        (person.enrolledChannels ?? []).map { (channel: VoiceChannel) -> String in
            switch channel { case .near: "Proche"; case .room: "Salle"; case .remote: "Visio" }
        }.joined(separator: " · ")
    }
    /// The state comes first; the action stays available to repair an installation.
    @ViewBuilder private func installControl(ready: Bool, busy: Bool, action: @escaping () -> Void) -> some View {
        if busy {
            ProgressView().controlSize(.small)
            Text("Installation…").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
        } else {
            if ready { Label("Installé", systemImage: "checkmark.circle.fill").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.mint) }
            Button(ready ? "Réinstaller" : "Installer", action: action)
                .buttonStyle(StudioButtonStyle(compact: true)).disabled(model.modelWorkBusy || model.isDemoMode)
        }
    }
    private func section<Content: View>(_ title: String, symbol: String, help: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Studio.mint)
                Eyebrow(text: title)
                if let help { HelpButton(text: help) }
            }.frame(minHeight: 22).padding(.bottom, 10)
            content()
        }.padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
    }
    /// One setting per line: label on the left, control on the right.
    private func row<Control: View>(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: Studio.Size.body))
            if let help { HelpButton(text: help) }
            Spacer(minLength: 12)
            control()
        }.frame(minHeight: 26).padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(Studio.line.opacity(0.55)).frame(height: 0.5) }
    }
    private func toggleRow(_ title: String, help: String? = nil, isOn: Binding<Bool>) -> some View {
        row(title, help: help) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Studio.mint)
        }
    }
}
