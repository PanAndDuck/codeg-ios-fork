import SwiftUI
import UIKit

/// Add / Edit Server sheet. Refined grouped-glass sections with clear field
/// labels, an inline Test Connection probe, and a Save action gated on
/// validation. On save it calls back with the persisted profile so the caller
/// can select it.
struct ServerEditorSheet: View {
    let store: ServerStore
    /// Called after a successful save with the resulting profile.
    let onSaved: (ServerProfile) -> Void

    @State private var model: ServerEditorModel
    @State private var saveError: LocalizedStringKey?
    @State private var showScanner = false
    @State private var scanError: String?
    @State private var showPairingInput: Bool
    @State private var pairingCode = ""
    @State private var pairingError: String?
    @State private var replacementFingerprint: String?
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case name, url, token, pairing }

    init(
        store: ServerStore,
        editing: ServerProfile? = nil,
        hasExistingToken: Bool = false,
        startWithPairingCode: Bool = false,
        onSaved: @escaping (ServerProfile) -> Void
    ) {
        self.store = store
        self.onSaved = onSaved
        _showPairingInput = State(initialValue: startWithPairingCode)
        _model = State(initialValue: ServerEditorModel(
            editing: editing,
            hasExistingToken: hasExistingToken,
            customHeaders: editing.map { store.customHeaders(for: $0) } ?? [],
            // Resolve the stored token lazily so Test Connection can fall back to
            // it when the field is left blank, without holding the secret.
            resolveExistingToken: { editing.flatMap { store.token(for: $0) } }
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()

                ScrollView {
                    VStack(spacing: 18) {
                        pairingSection
                        connectionSection
                        secondarySection
                        authSection
                        headersSection
                        certificateSection
                        testSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Theme.accent)
                        .disabled(!model.canSave)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showScanner) {
            QRScannerView { code in handleScanned(code) }
        }
        .alert("Couldn’t Save Server", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert("Couldn’t Read QR Code", isPresented: Binding(
            get: { scanError != nil },
            set: { if !$0 { scanError = nil } }
        )) {
            Button("OK", role: .cancel) { scanError = nil }
        } message: {
            Text(LocalizedStringKey(scanError ?? ""))
        }
        .alert("Replace certificate pin?", isPresented: Binding(
            get: { replacementFingerprint != nil },
            set: { if !$0 { replacementFingerprint = nil } }
        )) {
            Button("Cancel", role: .cancel) { replacementFingerprint = nil }
            Button("Replace pin", role: .destructive) {
                // Do not accept a different result if the editor changed while
                // the confirmation was visible.
                if case .certificate(let fingerprint, true) = model.testResult,
                   fingerprint == replacementFingerprint {
                    trustCertificate(replacingPin: true)
                }
                replacementFingerprint = nil
            }
        } message: {
            Text("The certificate changed. This could be a man-in-the-middle attack or a relay certificate rotation. Verify the new SHA-256 fingerprint through a trusted channel before replacing the pin.")
        }
        .confirmationDialog("Use this Relay with your LAN server?", isPresented: Binding(
            get: { model.pendingRelayPairing != nil },
            set: { if !$0 { model.cancelRelayImport() } }
        ), titleVisibility: .visible) {
            Button("Use as secondary Relay") { model.resolveRelayImport(addAsSecondary: true) }
            Button("Replace primary endpoint", role: .destructive) { model.resolveRelayImport(addAsSecondary: false) }
            Button("Cancel", role: .cancel) { model.cancelRelayImport() }
        } message: {
            Text("Keep the LAN address and use this Relay when LAN is unavailable. An existing secondary endpoint will be replaced. Both endpoints share the server token and custom headers.")
        }
    }

    // MARK: - Sections

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                focusedField = nil
                showPairingInput.toggle()
                if !showPairingInput {
                    pairingCode = ""
                    pairingError = nil
                }
            } label: {
                Label("Paste pairing code", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(Theme.accent)

            if showPairingInput {
                EditorSection(title: "Pairing code", footer: "Paste or type the pairing code from codeg. Server URLs and legacy pairing codes are also supported.") {
                    FieldRow(label: "Pairing code") {
                        SecureField("Pairing code", text: $pairingCode)
                            .font(.mono(15))
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                            .focused($focusedField, equals: .pairing)
                            .submitLabel(.done)
                            .onSubmit { importPairingCode(pairingCode) }
                            .onChange(of: pairingCode) { _, _ in pairingError = nil }
                            .accessibilityIdentifier("pairing.code")
                    }
                    HStack {
                        Button("Paste from Clipboard") { pastePairingCode() }
                        Spacer()
                        Button("Import pairing code") { importPairingCode(pairingCode) }
                            .disabled(pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .font(.subheadline)
                    .tint(Theme.accent)
                    .padding(16)
                }
                if let pairingError {
                    Text(LocalizedStringKey(pairingError))
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                        .accessibilityIdentifier("pairing.error")
                }
            }
        }
    }

    private var connectionSection: some View {
        EditorSection(title: "Connection") {
            Picker("Primary endpoint type", selection: $model.primaryIsRelay) {
                Text(verbatim: "LAN").tag(false)
                Text("Relay").tag(true)
            }
            .pickerStyle(.segmented)
            FieldRow(label: "Name") {
                TextField("My codeg server", text: $model.name)
                    .accessibilityIdentifier("server.name")
                    .textContentType(.name)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .name)
                    .onSubmit { focusedField = .url }
                    .onChange(of: model.name) { _, _ in model.fieldsChanged() }
            }

            Divider().overlay(Theme.hairline)

            FieldRow(label: "Server URL") {
                HStack(spacing: 10) {
                    TextField("http://192.168.1.10:3080", text: $model.urlString)
                        .accessibilityIdentifier("server.url")
                        .font(.mono(15))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textContentType(.URL)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .url)
                        .onSubmit { focusedField = .token }
                        .onChange(of: model.urlString) { _, _ in model.fieldsChanged() }
                        .frame(maxWidth: .infinity)

                    // Scan codeg's "show QR" code to fill the address.
                    Button {
                        focusedField = nil
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scan QR code")
                }
            }
        }
    }

    private var authSection: some View {
        EditorSection(
            title: "Authentication",
            footer: model.authFooter
        ) {
            FieldRow(label: "Token") {
                SecureField(model.tokenPlaceholder, text: $model.token)
                    .accessibilityIdentifier("server.token")
                    .font(.mono(15))
                    .textContentType(.password)
                    .submitLabel(.done)
                    .focused($focusedField, equals: .token)
                    .onSubmit { focusedField = nil }
                    .onChange(of: model.token) { _, _ in model.fieldsChanged() }
            }
        }
    }

    private var secondarySection: some View {
        EditorSection(title: "Secondary endpoint (Relay)", footer: "Prefer LAN on Wi-Fi when healthy; otherwise use the Relay. Each endpoint has its own certificate pin.") {
            TextField("https://relay.example:18443", text: $model.secondaryURLString)
                .font(.mono(15))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Secondary endpoint URL")
            if model.hasSecondary {
                Button("Remove secondary endpoint", role: .destructive) { model.removeSecondary() }
            }
        }
    }

    private var headersSection: some View {
        EditorSection(title: "Custom headers", footer: "Header values are stored securely with the token and sent to both endpoints, including WebSocket connections.") {
            ForEach(model.customHeaders.indices, id: \.self) { index in
                VStack(spacing: 8) {
                    HStack {
                        TextField("Header name", text: $model.customHeaders[index].name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.mono(14))
                        Button(role: .destructive) { model.customHeaders.remove(at: index) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel("Remove header")
                    }
                    SecureField("Secret header value", text: $model.customHeaders[index].value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.mono(14))
                }
            }
            Button("Add header") { model.customHeaders.append(HeaderPair(name: "", value: "")) }
            if let error = model.headerValidationError {
                Text(verbatim: error).font(.footnote).foregroundStyle(Theme.danger)
            }
        }
    }

    private var testSection: some View {
        VStack(spacing: 12) {
            if model.hasSecondary {
                Picker("Test endpoint", selection: $model.testEndpoint) {
                    Text("Primary").tag(EndpointSelector.Endpoint.primary)
                    Text("Relay").tag(EndpointSelector.Endpoint.secondary)
                }
                .pickerStyle(.segmented)
            }
            Button {
                focusedField = nil
                Task { await model.testConnection() }
            } label: {
                HStack(spacing: 8) {
                    if model.isTesting {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Text("Test Connection").fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .tint(Theme.accent)
            .disabled(model.isTesting || !model.canTest)

            if let result = model.testResult {
                TestResultRow(result: result)
                    .transition(.move(edge: .top).combined(with: .opacity))
                if case .certificate(let fingerprint, let isMismatch) = result {
                    Text(CertificateFingerprint.display(fingerprint))
                        .font(.mono(13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        if isMismatch {
                            replacementFingerprint = fingerprint
                        } else {
                            trustCertificate()
                        }
                    } label: {
                        Text(isMismatch ? LocalizedStringKey("Replace pin") : LocalizedStringKey("Trust this certificate"))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: model.testResult)
    }

    @ViewBuilder
    private var certificateSection: some View {
        if let pin = model.selectedPin {
            EditorSection(title: "Certificate") {
                DisclosureGroup("Pinned SHA-256 fingerprint") {
                    Text(CertificateFingerprint.display(pin))
                        .font(.mono(13))
                        .textSelection(.enabled)
                        .padding(.top, 8)
                }
                Text("The certificate pin is saved with this server when you tap Save.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if model.selectedTestURL == nil {
                    Text("A pinned certificate requires an HTTPS server URL.")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
            }
        }
    }

    // MARK: - Actions

    private func pastePairingCode() {
        // Read only in response to this tap; iOS owns cross-app paste permission.
        guard let code = UIPasteboard.general.string,
              !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pairingError = "No text was pasted. Allow paste access or enter the pairing code manually."
            return
        }
        importPairingCode(code)
    }

    private func importPairingCode(_ code: String) {
        focusedField = nil
        guard model.applyPairingCode(code) else {
            pairingError = model.scanError
            return
        }
        pairingCode = ""
        pairingError = nil
        showPairingInput = false
    }

    private func trustCertificate(replacingPin: Bool = false) {
        guard model.trustPresentedCertificate(replacingPin: replacingPin) else { return }
        Task { await model.testConnection() }
    }

    private func save() {
        guard model.canSave, let saved = saveProfile() else { return }
        onSaved(saved)
        dismiss()
    }

    /// Fill validated pairing fields, including an optional certificate pin.
    private func handleScanned(_ code: String) {
        if !model.applyScanned(code) {
            scanError = model.scanError
        }
    }

    /// Persist via the store and return the resulting profile. Stores the
    /// normalized URL (so the profile is always usable) and the trimmed token.
    /// Returns `nil` and raises an alert (without dismissing) if secure token
    /// storage failed, so the sheet never reports a save that didn't happen.
    private func saveProfile() -> ServerProfile? {
        let name = model.trimmedName
        let urlString = model.urlStringForSave

        if let existing = model.editing {
            var updated = existing
            updated.name = name
            updated.urlString = urlString
            updated.pinnedCertSHA256 = model.pinnedCertSHA256
            updated.pairingMode = model.pairingMode
            updated.secondaryEndpoint = model.secondaryEndpointForSave
            // Pass the token only if the user re-entered one; nil keeps the
            // stored secret untouched.
            guard store.update(updated, token: model.tokenForSave, customHeaders: model.customHeaders) else {
                saveError = tokenSaveFailureMessage
                return nil
            }
            return store.servers.first { $0.id == updated.id }
        } else {
            // canSave guarantees a non-empty trimmed token here.
            guard let profile = store.add(name: name, urlString: urlString, token: model.trimmedToken,
                                          pinnedCertSHA256: model.pinnedCertSHA256, pairingMode: model.pairingMode,
                                          secondaryEndpoint: model.secondaryEndpointForSave, customHeaders: model.customHeaders) else {
                saveError = tokenSaveFailureMessage
                return nil
            }
            return profile
        }
    }

    private var tokenSaveFailureMessage: LocalizedStringKey {
        "The token couldn’t be saved to the Keychain. Please try again."
    }
}

// MARK: - Building blocks

/// Inline success / failure feedback for the Test Connection probe.
private struct TestResultRow: View {
    let result: ServerEditorModel.TestResult

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            text
                .font(.subheadline)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md, color: tint.opacity(0.35))
    }

    private var symbol: String {
        switch result {
        case .success: "checkmark.circle.fill"
        case .failure, .certificate: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch result {
        case .success: Theme.accent
        case .failure, .certificate: Theme.danger
        }
    }

    private var text: Text {
        switch result {
        case .success(let version): Text("Connected · v\(version)")
        case .failure(let message): Text(verbatim: message)
        case .certificate(_, let isMismatch):
            isMismatch
                ? Text("Certificate changed. Possible man-in-the-middle attack or relay certificate rotation. Verify the fingerprint before replacing the pin.")
                : Text("This certificate is not trusted by the system. Verify its SHA-256 fingerprint through a trusted channel before trusting it.")
        }
    }
}
