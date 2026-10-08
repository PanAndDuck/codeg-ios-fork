import SwiftUI

/// Add / Edit a chat channel. Mirrors the web add/edit dialogs:
/// - channel type is chosen on add and immutable on edit (the update call has no
///   type field);
/// - per-type typed config fields (with a raw JSON escape hatch);
/// - the secret token uses "blank = keep" on edit (only sent when re-entered);
///   weixin has no manual token (it connects via QR in the detail screen).
struct ChatChannelEditorSheet: View {
    let editing: ChatChannelInfo?
    let client: CodegClient?
    let onCreate: (_ name: String, _ type: ChannelType, _ configJson: String, _ enabled: Bool, _ dailyReportEnabled: Bool, _ dailyReportTime: String?, _ token: String?) async throws -> Void
    let onUpdate: (_ body: UpdateChatChannelBody, _ token: String?) async throws -> Void

    @State private var name: String
    @State private var type: ChannelType
    @State private var config: ChannelConfig
    @State private var rawMode = false
    @State private var rawText: String
    @State private var token = ""
    @State private var hasToken = false
    @State private var enabled: Bool
    @State private var dailyEnabled: Bool
    @State private var dailyTime: Date
    @State private var isSaving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(
        editing: ChatChannelInfo?,
        client: CodegClient?,
        onCreate: @escaping (String, ChannelType, String, Bool, Bool, String?, String?) async throws -> Void,
        onUpdate: @escaping (UpdateChatChannelBody, String?) async throws -> Void
    ) {
        self.editing = editing
        self.client = client
        self.onCreate = onCreate
        self.onUpdate = onUpdate
        _name = State(initialValue: editing?.name ?? "")
        _type = State(initialValue: editing?.channelType ?? .telegram)
        _config = State(initialValue: ChannelConfig.parse(editing?.configJson))
        _rawText = State(initialValue: editing?.configJson ?? "")
        _enabled = State(initialValue: editing?.enabled ?? true)
        _dailyEnabled = State(initialValue: editing?.dailyReportEnabled ?? false)
        _dailyTime = State(initialValue: Self.parseTime(editing?.dailyReportTime) ?? Self.defaultTime)
    }

    private var isEdit: Bool { editing != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The config JSON to persist (built from typed fields, or the raw editor).
    private var configJsonToSave: String? {
        if rawMode {
            guard let normalized = Self.normalizedObjectJSON(rawText) else { return nil }
            return normalized
        }
        return config.toJSON(type: type)
    }

    private var configValid: Bool {
        if rawMode { return Self.normalizedObjectJSON(rawText) != nil }
        switch type {
        case .telegram: return !config.chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .lark:
            return !config.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !config.chatId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .weixin: return true
        }
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty, configValid, !isSaving else { return false }
        // A token is required to create a telegram/lark channel; on edit blank
        // keeps the stored one. Weixin never has a manual token.
        if !isEdit, type.secretLabel != nil, trimmedToken.isEmpty { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        channelSection
                        configSection
                        if type.secretLabel != nil { authSection } else { weixinNote }
                        dailyReportSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(isEdit ? "Edit Channel" : "Add Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Theme.accent)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task {
            if isEdit, let id = editing?.id {
                hasToken = (try? await client?.chatChannelHasToken(channelId: id)) ?? false
            }
        }
        .alert("Couldn’t Save Channel", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Sections

    private var channelSection: some View {
        EditorSection(title: "Channel", footer: isEdit ? "The channel type can’t be changed after creation." : nil) {
            FieldRow(label: "Name") {
                TextField("My channel", text: $name)
            }
            Divider().overlay(Theme.hairline)
            FieldRow(label: "Type") {
                if isEdit {
                    Text(type.displayName)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    SelectField(selection: $type,
                                options: ChannelType.allCases.map { SelectOption(value: $0, label: $0.displayName) })
                }
            }
        }
    }

    @ViewBuilder
    private var configSection: some View {
        EditorSection(title: "Configuration") {
            if rawMode {
                rawEditor
            } else {
                typedConfigFields
            }
            Divider().overlay(Theme.hairline)
            HStack {
                Text("Edit raw JSON").foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { rawMode },
                    set: { on in
                        if on, rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            rawText = config.toJSON(type: type)
                        }
                        rawMode = on
                    }
                ))
                .labelsHidden().tint(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    @ViewBuilder
    private var typedConfigFields: some View {
        switch type {
        case .telegram:
            configField(label: "Chat ID", text: $config.chatId, placeholder: "-100123456789")
        case .lark:
            configField(label: "App ID", text: $config.appId, placeholder: "cli_xxxxx")
            Divider().overlay(Theme.hairline)
            configField(label: "Chat ID", text: $config.chatId, placeholder: "oc_xxxxx")
        case .weixin:
            configField(label: "Base URL", text: $config.baseUrl, placeholder: ChannelConfig.weixinDefaultBaseUrl)
        }
    }

    private func configField(label: LocalizedStringKey, text: Binding<String>, placeholder: String) -> some View {
        FieldRow(label: label) {
            TextField(placeholder, text: text)
                .font(.mono(15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
        }
    }

    private var rawEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $rawText)
                .font(.mono(13))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(light: .black.opacity(0.05), dark: .black.opacity(0.18)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
            if Self.normalizedObjectJSON(rawText) == nil {
                Text("Must be a JSON object.")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var authSection: some View {
        EditorSection(
            title: "Authentication",
            footer: isEdit && hasToken ? "Leave blank to keep the stored \(type.secretLabel ?? "token")." : nil
        ) {
            FieldRow(label: LocalizedStringKey(stringLiteral: type.secretLabel ?? "Token")) {
                SecureField(isEdit && hasToken ? "Keep current" : (type.secretLabel ?? "Token"), text: $token)
                    .font(.mono(15))
                    .textContentType(.password)
            }
        }
    }

    private var weixinNote: some View {
        EditorSection(title: "Authentication", footer: "WeChat connects by scanning a QR code — open the channel after saving and tap “Scan QR to Connect”.") {
            HStack(spacing: 8) {
                Image(systemName: "qrcode").foregroundStyle(Theme.textSecondary)
                Text("No token needed here.").foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    private var dailyReportSection: some View {
        EditorSection(title: "Daily Report", footer: "Send a summary of the day's activity to this channel.") {
            HStack {
                Text("Enabled").foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Toggle("", isOn: $dailyEnabled).labelsHidden().tint(Theme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            if dailyEnabled {
                Divider().overlay(Theme.hairline)
                HStack {
                    Text("Time").foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 8)
                    DatePicker("", selection: $dailyTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .tint(Theme.accent)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
        }
    }

    // MARK: - Save

    private func save() {
        guard canSave, let configJson = configJsonToSave else { return }
        isSaving = true
        let tokenToSend = trimmedToken.isEmpty ? nil : trimmedToken
        let timeString = dailyEnabled ? Self.formatTime(dailyTime) : nil
        Task {
            do {
                if let editing {
                    try await onUpdate(buildUpdateBody(for: editing, configJson: configJson, timeString: timeString), tokenToSend)
                } else {
                    try await onCreate(trimmedName, type, configJson, enabled, dailyEnabled, timeString, tokenToSend)
                }
                dismiss()
            } catch {
                saveError = APIError.userMessage(error)
                isSaving = false
            }
        }
    }

    /// Build the partial update: only changed fields (nil = keep). Config is
    /// compared semantically (normalized) so a key-order difference can't trigger
    /// a spurious write.
    private func buildUpdateBody(for existing: ChatChannelInfo, configJson: String, timeString: String?) -> UpdateChatChannelBody {
        var body = UpdateChatChannelBody(id: existing.id)
        body.name = trimmedName != existing.name ? trimmedName : nil
        body.enabled = enabled != existing.enabled ? enabled : nil
        if Self.normalizedObjectJSON(configJson) != Self.normalizedObjectJSON(existing.configJson) {
            body.configJson = configJson
        }
        body.dailyReportEnabled = dailyEnabled != existing.dailyReportEnabled ? dailyEnabled : nil
        // Time tri-state: set when on & changed; explicitly clear when the report
        // is turned off and a time was stored; otherwise keep.
        if dailyEnabled {
            if timeString != existing.dailyReportTime, let time = timeString {
                body.dailyReportTime = .set(time)
            }
        } else if existing.dailyReportTime != nil {
            body.dailyReportTime = .clear
        }
        return body
    }

    // MARK: - HH:mm helpers

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static var defaultTime: Date {
        Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static func parseTime(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return timeFormatter.date(from: s).map { parsed in
            let c = Calendar.current.dateComponents([.hour, .minute], from: parsed)
            return Calendar.current.date(bySettingHour: c.hour ?? 18, minute: c.minute ?? 0, second: 0, of: Date()) ?? parsed
        }
    }

    private static func formatTime(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// Normalize a JSON-object string to a canonical (sorted-key) form, or nil if
    /// it isn't a JSON object. Used for validation and semantic change detection.
    private static func normalizedObjectJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              obj is [String: Any],
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: out, encoding: .utf8) else { return nil }
        return json
    }
}
