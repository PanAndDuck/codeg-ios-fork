import SwiftUI
import Observation

/// Global (cross-channel) chat behavior: the command prefix, the bot's reply
/// language, which events get forwarded, and outbound webhooks. Each control
/// persists on change via a coalescing serial sender in the model.
struct ChatGlobalSettingsView: View {
    @State private var model: ChatGlobalSettingsModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(client: CodegClient?) {
        _model = State(initialValue: ChatGlobalSettingsModel(client: client))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .screenTitle("Message Settings", compact: horizontalSizeClass == .compact)
        .task { await model.load() }
        .alert("Couldn’t Save", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK", role: .cancel) { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            LoadingView(label: "Loading…")
        case .failed(let message):
            InlineErrorView(message: message) { Task { await model.load() } }
        case .loaded:
            ScrollView {
                VStack(spacing: 18) {
                    prefixSection
                    languageSection
                    eventsSection
                    webhooksSection
                }
                .padding(.horizontal, Theme.Layout.screenHMargin)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
        }
    }

    private var prefixSection: some View {
        EditorSection(title: "Command Prefix", footer: "1–3 non-alphanumeric characters (e.g. /, !, .). Messages starting with this are treated as commands.") {
            FieldRow(label: "Prefix") {
                // Save-on-change get/set binding (the setter persists via the
                // coalescing sender, which only sends valid values) — so there's
                // no "typed but never submitted" gap on navigate-away.
                TextField("/", text: Binding(get: { model.prefix }, set: { model.setPrefix($0) }))
                    .font(.mono(15))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
            }
            if !model.prefixValid {
                Text("Must be 1–3 non-alphanumeric characters.")
                    .font(.caption).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
    }

    private var languageSection: some View {
        EditorSection(title: "Reply Language", footer: "The language the bot replies in.") {
            FieldRow(label: "Language") {
                SelectField(selection: Binding(
                    get: { model.language },
                    set: { model.language = $0; model.saveLanguage() }
                ), options: ChatLanguageCatalog.options.map { SelectOption(value: $0.code, label: $0.label) })
            }
        }
    }

    private var eventsSection: some View {
        EditorSection(title: "Forwarded Events", footer: "Which agent events are sent to your channels and webhooks.") {
            ForEach(Array(ChatEventCatalog.all.enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider().overlay(Theme.hairline) }
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Fixed event labels/notes localize via a runtime catalog lookup.
                        Text(LocalizedStringKey(stringLiteral: event.label)).foregroundStyle(Theme.textPrimary)
                        if let note = event.note {
                            Text(LocalizedStringKey(stringLiteral: note)).font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { model.enabledEvents.contains(event.id) },
                        set: { model.setEvent(event.id, $0) }
                    ))
                    .labelsHidden().tint(Theme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
    }

    private var webhooksSection: some View {
        EditorSection(title: "Webhooks", footer: "Forwarded events are POSTed to each enabled URL.") {
            if model.webhooks.isEmpty {
                Text("No webhooks.")
                    .font(.subheadline).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 11)
            }
            ForEach(model.webhooks) { hook in
                HStack(spacing: 8) {
                    // Save-on-change get/set bindings (coalesced) so a typed-but-
                    // unsubmitted URL still persists on navigate-away.
                    TextField("https://example.com/hook", text: Binding(
                        get: { hook.url },
                        set: { model.setWebhookURL(id: hook.id, $0) }
                    ))
                    .font(.mono(13))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    Toggle("", isOn: Binding(
                        get: { hook.enabled },
                        set: { model.setWebhookEnabled(id: hook.id, $0) }
                    ))
                    .labelsHidden().tint(Theme.accent)
                    Button {
                        model.removeWebhook(id: hook.id)
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(Theme.danger.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider().overlay(Theme.hairline)
            }
            Button {
                model.addWebhook()
            } label: {
                Label("Add Webhook", systemImage: "plus").font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }
}

/// A webhook with a stable UI identity (the wire type has none).
struct WebhookItem: Identifiable, Equatable {
    let id = UUID()
    var url: String
    var enabled: Bool
}

/// Loads + persists the global chat settings. Each setting saves through its own
/// coalescing serial sender (one request in flight, latest value wins, never
/// drops the final value); on failure the displayed value reconciles to server
/// truth.
@MainActor
@Observable
final class ChatGlobalSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    var prefix = "/"
    var language = "en"
    var enabledEvents: Set<String> = ChatEventCatalog.defaultEnabled
    var webhooks: [WebhookItem] = []
    var saveError: String?

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    var prefixValid: Bool {
        (1...3).contains(prefix.count) && prefix.allSatisfy { !$0.isLetter && !$0.isNumber }
    }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        do {
            prefix = try await client.chatCommandPrefix()
            language = try await client.chatMessageLanguage()
            let filter = try await client.chatEventFilter()
            enabledEvents = filter.map(Set.init) ?? ChatEventCatalog.defaultEnabled
            webhooks = try await client.chatEventWebhooks().map { WebhookItem(url: $0.url, enabled: $0.enabled) }
            phase = .loaded
        } catch {
            guard !APIError.isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Prefix

    /// Save-on-change from the field's set binding; `savePrefix` itself only sends
    /// when the value is valid, so invalid intermediate input is never persisted.
    func setPrefix(_ value: String) {
        prefix = value
        savePrefix()
    }

    // MARK: - Event toggles

    func setEvent(_ id: String, _ on: Bool) {
        if on { enabledEvents.insert(id) } else { enabledEvents.remove(id) }
        saveFilter()
    }

    // MARK: - Webhook edits

    func addWebhook() { webhooks.append(WebhookItem(url: "", enabled: true)) }

    func removeWebhook(id: UUID) {
        webhooks.removeAll { $0.id == id }
        saveWebhooks()
    }

    func setWebhookEnabled(id: UUID, _ on: Bool) {
        guard let idx = webhooks.firstIndex(where: { $0.id == id }) else { return }
        webhooks[idx].enabled = on
        saveWebhooks()
    }

    func setWebhookURL(id: UUID, _ url: String) {
        guard let idx = webhooks.firstIndex(where: { $0.id == id }) else { return }
        webhooks[idx].url = url
        saveWebhooks()
    }

    // MARK: - Coalescing serial senders

    private var prefixSaving = false
    private var prefixPending = false
    func savePrefix() {
        guard prefixValid else { return }
        prefixPending = true
        Task { await drainPrefix() }
    }
    private func drainPrefix() async {
        guard !prefixSaving, let client else { return }
        prefixSaving = true
        defer { prefixSaving = false }
        while prefixPending {
            prefixPending = false
            let value = prefix
            do { try await client.setChatCommandPrefix(value) }
            catch {
                saveError = APIError.userMessage(error)
                prefix = (try? await client.chatCommandPrefix()) ?? prefix
                return
            }
        }
    }

    private var languageSaving = false
    private var languagePending = false
    func saveLanguage() {
        languagePending = true
        Task { await drainLanguage() }
    }
    private func drainLanguage() async {
        guard !languageSaving, let client else { return }
        languageSaving = true
        defer { languageSaving = false }
        while languagePending {
            languagePending = false
            let value = language
            do { try await client.setChatMessageLanguage(value) }
            catch {
                saveError = APIError.userMessage(error)
                language = (try? await client.chatMessageLanguage()) ?? language
                return
            }
        }
    }

    private var filterSaving = false
    private var filterPending = false
    func saveFilter() {
        filterPending = true
        Task { await drainFilter() }
    }
    private func drainFilter() async {
        guard !filterSaving, let client else { return }
        filterSaving = true
        defer { filterSaving = false }
        while filterPending {
            filterPending = false
            // Send null when the selection equals the server default — preserves
            // "null = default" instead of pinning an explicit snapshot.
            let value: [String]? = (enabledEvents == ChatEventCatalog.defaultEnabled) ? nil : Array(enabledEvents)
            do { try await client.setChatEventFilter(value) }
            catch {
                saveError = APIError.userMessage(error)
                // Reconcile to server truth. Use do/catch (not try?) so a server
                // `null` (= default set) is distinguished from a failed re-read
                // (`try?` would flatten both to nil and keep the optimistic value).
                do {
                    let serverFilter = try await client.chatEventFilter()   // [String]?
                    enabledEvents = serverFilter.map(Set.init) ?? ChatEventCatalog.defaultEnabled
                } catch {
                    // Re-read failed — leave the optimistic value as-is.
                }
                return
            }
        }
    }

    private var webhooksSaving = false
    private var webhooksPending = false
    func saveWebhooks() {
        webhooksPending = true
        Task { await drainWebhooks() }
    }
    private func drainWebhooks() async {
        guard !webhooksSaving, let client else { return }
        webhooksSaving = true
        defer { webhooksSaving = false }
        while webhooksPending {
            webhooksPending = false
            // Drop blank URLs (trim) — don't persist empty rows.
            let value = webhooks
                .map { WebhookConfig(url: $0.url.trimmingCharacters(in: .whitespacesAndNewlines), enabled: $0.enabled) }
                .filter { !$0.url.isEmpty }
            do { try await client.setChatEventWebhooks(value) }
            catch {
                saveError = APIError.userMessage(error)
                if let fresh = try? await client.chatEventWebhooks() {
                    webhooks = fresh.map { WebhookItem(url: $0.url, enabled: $0.enabled) }
                }
                return
            }
        }
    }
}
