import SwiftUI

/// The server management screen (reached via "Manage Servers…" in the Chats /
/// sidebar title menu): saved codeg servers with live connection status and
/// add / edit / delete. Tapping a row makes it the active server.
struct ServerListView: View {
    let store: ServerStore
    @Binding var selectedServerID: ServerProfile.ID?

    @State private var status: ServerStatusModel
    @State private var editorRoute: EditorRoute?
    @State private var pendingDelete: ServerProfile?
    @State private var didInitialLoad = false

    /// Identifies which mode the editor sheet opens in (add vs. edit a profile).
    private enum EditorRoute: Identifiable {
        case add
        case edit(ServerProfile)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let profile): profile.id.uuidString
            }
        }
    }

    init(
        store: ServerStore,
        selectedServerID: Binding<ServerProfile.ID?>
    ) {
        self.store = store
        _selectedServerID = selectedServerID
        _status = State(initialValue: ServerStatusModel(store: store))
    }

    var body: some View {
        ZStack {
            CodegBackground()
            content
        }
        .navigationTitle("Servers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorRoute = .add
                } label: {
                    Image(systemName: "plus")
                }
                .tint(Theme.accent)
                .accessibilityLabel("Add Server")
            }
        }
        .sheet(item: $editorRoute) { route in
            editorSheet(for: route)
        }
        .confirmationDialog(
            "Delete Server",
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { server in
            Button("Delete \(server.name)", role: .destructive) {
                delete(server)
            }
            Button("Cancel", role: .cancel) {}
        } message: { server in
            Text("Remove “\(server.name)” and its stored token from this device. This can't be undone.")
        }
        .task {
            // Probe once when the column first appears; pull-to-refresh re-runs.
            guard !didInitialLoad else { return }
            didInitialLoad = true
            await status.refreshAll()
        }
    }

    // MARK: - Content states

    @ViewBuilder
    private var content: some View {
        if store.servers.isEmpty {
            EmptyStateView(
                icon: "server.rack",
                title: "No Servers",
                message: "Add a codeg server to start browsing its sessions.",
                actionTitle: "Add Server",
                action: { editorRoute = .add }
            )
        } else {
            serverList
        }
    }

    private var serverList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.servers) { server in
                    ServerRow(
                        server: server,
                        endpoint: store.activeEndpoint(for: server),
                        endpointLabel: store.endpointLabel(for: server),
                        status: status.status(for: server.id),
                        isSelected: server.id == selectedServerID,
                        onEdit: { openEditor(for: server) },
                        onTest: { Task { await status.refresh(server) } },
                        onDelete: { pendingDelete = server }
                    )
                    .contentShape(.rect)
                    .onTapGesture {
                        selectedServerID = server.id
                    }
                    // Long-press menu kept for power users; the visible ⋯ button on
                    // each row is the primary, discoverable edit/delete affordance.
                    // (A `.swipeActions` here would be dead — it only works inside a
                    // `List`, and this is a ScrollView + LazyVStack.)
                    .contextMenu {
                        rowMenu(for: server)
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.screenHMargin)
            .padding(.top, 2)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .refreshable { await status.refreshAll() }
    }

    @ViewBuilder
    private func rowMenu(for server: ServerProfile) -> some View {
        Button {
            openEditor(for: server)
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button {
            Task { await status.refresh(server) }
        } label: {
            Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = server
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private func editorSheet(for route: EditorRoute) -> some View {
        switch route {
        case .add:
            ServerEditorSheet(store: store) { profile in
                selectedServerID = profile.id
                Task { await status.refresh(profile) }
            }
        case .edit(let profile):
            ServerEditorSheet(
                store: store,
                editing: profile,
                hasExistingToken: store.token(for: profile) != nil
            ) { updated in
                Task { await status.refresh(updated) }
            }
        }
    }

    private func openEditor(for server: ServerProfile) {
        editorRoute = .edit(server)
    }

    // MARK: - Deletion

    private func delete(_ server: ServerProfile) {
        if let index = store.servers.firstIndex(where: { $0.id == server.id }) {
            deleteServers(at: IndexSet(integer: index))
        }
        pendingDelete = nil
    }

    /// Index-based deletion routed through `store.delete(at:)` — used by both
    /// the confirmation dialog and any `.onDelete` affordance. Clears selection
    /// and prunes cached statuses for the removed rows.
    private func deleteServers(at offsets: IndexSet) {
        let removed = offsets.map { store.servers[$0] }
        if let selected = selectedServerID, removed.contains(where: { $0.id == selected }) {
            selectedServerID = nil
        }
        store.delete(at: offsets)
        for server in removed {
            status.remove(server.id)
        }
    }

    /// Bridges the optional `pendingDelete` to the dialog's `isPresented`.
    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }
}

// MARK: - Row

/// A single server row: name (with an "active" checkmark when selected),
/// host:port, a trailing connection-status indicator (spinner / green dot +
/// version / red dot), and a visible ⋯ menu for Edit / Test / Delete.
private struct ServerRow: View {
    let server: ServerProfile
    let endpoint: ServerEndpoint
    let endpointLabel: String
    let status: ServerStatus
    let isSelected: Bool
    let onEdit: () -> Void
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        GlassRow(isSelected: isSelected) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        EndpointBadge(label: endpointLabel)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                                .accessibilityLabel("Active server")
                        }
                    }
                    Text(verbatim: endpoint.urlString)
                        .font(.mono(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ConnectionStatusView(status: status)

                optionsMenu
            }
        }
    }

    /// Visible per-row actions. A `Menu` carries its own tap target, so it opens
    /// on tap without firing the row's selection `.onTapGesture`.
    private var optionsMenu: some View {
        Menu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(action: onTest) {
                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 36)
                .contentShape(.rect)
        }
        .accessibilityLabel("Server options")
    }
}

/// Trailing status cluster: a colored dot (or spinner while checking) with the
/// server version shown when online.
private struct ConnectionStatusView: View {
    let status: ServerStatus

    var body: some View {
        HStack(spacing: 6) {
            if case .online(let version) = status {
                Text("v\(version)")
                    .font(.mono(11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            indicator
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var indicator: some View {
        switch status {
        case .checking:
            // Gray dot for the unknown state, with a tiny spinner beside it.
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.textTertiary)
                StatusDot(color: Theme.textTertiary)
            }
        case .online:
            StatusDot(color: Theme.accent)
        case .offline:
            StatusDot(color: Theme.danger)
        }
    }

    private var accessibilityLabel: LocalizedStringKey {
        switch status {
        case .checking: "Checking connection"
        case .online(let version): "Online, version \(version)"
        case .offline: "Offline"
        }
    }
}

/// A small connection dot with a soft glow halo for legibility on glass.
private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 3).blur(radius: 1))
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}
