import SwiftUI

/// A folder's file browser: the immediate children of `dirPath`, directories
/// first. Directories drill in (pushing another `FolderFilesView`); files open a
/// preview. Used both as the embedded root of the Files tab and as each pushed
/// subdirectory — `embedded` suppresses the background/title the parent already
/// provides.
struct FolderFilesView: View {
    let client: CodegClient
    /// The folder's root — constant across drill-ins, used to make file paths
    /// relative for `read_file_preview`.
    let rootPath: String
    /// Absolute path of the directory shown here (equals `rootPath` at the top).
    let dirPath: String
    var embedded = false

    @State private var items: [DirectoryItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                ZStack {
                    CodegBackground()
                    content
                }
                .navigationTitle((dirPath as NSString).lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { if !loaded { await load() } }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && !loaded {
            LoadingView(label: "Loading files…")
        } else if let error, !loaded {
            InlineErrorView(message: error) { Task { await load() } }
        } else {
            // Loaded (possibly empty) — one refreshable scroll so an empty
            // directory is still pull-to-refreshable and a failed refresh shows a banner.
            loadedList
        }
    }

    /// A directory's contents can be unbounded (a monorepo / `node_modules` runs to
    /// thousands of entries), so this uses a `List` — which *recycles* row cells
    /// (UICollectionView reuse) — rather than a `LazyVStack` inside a grouped card.
    /// A `LazyVStack` still materializes rows lazily, but it never recycles the
    /// views it creates, so on a very large directory `List`'s cell reuse keeps
    /// memory and scrolling bounded where a `LazyVStack` would steadily grow.
    /// (Same recipe as ``SessionSectionFullScreen``.) It still reads as one
    /// continuous inset list:
    /// transparent background over the screen gradient, native separators tinted to
    /// the app hairline and inset under the filename.
    private var loadedList: some View {
        List {
            // Surface a failed refresh without dropping the loaded listing.
            if let error, loaded {
                RefreshErrorBanner(message: error, retry: { Task { await load(force: true) } }, dismiss: { self.error = nil })
                    .listRowInsets(EdgeInsets(top: 4, leading: rowHInset, bottom: 10, trailing: rowHInset))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if sorted.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "Empty Folder",
                    message: "This directory has no files."
                )
                .frame(maxWidth: .infinity, minHeight: 360)
                .listRowInsets(EdgeInsets(top: 0, leading: rowHInset, bottom: 0, trailing: rowHInset))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(sorted) { item in
                    NavigationLink {
                        destination(for: item)
                    } label: {
                        FileRow(item: item)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: rowHInset, bottom: 0, trailing: rowHInset))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.hairline)
                    // Start the separator under the filename, past the icon column.
                    .alignmentGuide(.listRowSeparatorLeading) { _ in FileRowMetrics.separatorInset }
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .refreshable { await load(force: true) }
    }

    /// Embedded (in the detail's Files tab) the parent already insets by the screen
    /// margin, so rows sit flush (0); the pushed sub-directory level draws its own
    /// background and carries the margin itself.
    private var rowHInset: CGFloat { embedded ? 0 : Theme.Layout.screenHMargin }

    /// Directories first, then files; each alphabetical, case-insensitive.
    private var sorted: [DirectoryItem] {
        items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Directories drill into another browser level; files open a preview.
    @ViewBuilder
    private func destination(for item: DirectoryItem) -> some View {
        if item.isDir {
            FolderFilesView(client: client, rootPath: rootPath, dirPath: item.path)
        } else {
            FilePreviewView(client: client, rootPath: rootPath, absPath: item.path)
        }
    }

    private func load(force: Bool = false) async {
        if loaded && !force { return }
        isLoading = true
        error = nil
        do {
            items = try await client.listDirectoryWithFiles(path: dirPath)
            loaded = true
        } catch {
            self.error = APIError.userMessage(error)
        }
        isLoading = false
    }
}

// MARK: - Row

/// Shared metrics so the inset list separator lines up under the filename, past
/// the leading icon column.
private enum FileRowMetrics {
    static let iconWidth: CGFloat = 22
    static let iconGap: CGFloat = 12
    static var separatorInset: CGFloat { iconWidth + iconGap }
}

/// One directory or file entry: a type-tinted icon, the name, and — for files —
/// a trailing size. Borderless: the enclosing `List` provides the surface and the
/// inset separators; directories drill in via the list's native disclosure.
private struct FileRow: View {
    let item: DirectoryItem

    var body: some View {
        HStack(spacing: FileRowMetrics.iconGap) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(iconTint)
                .frame(width: FileRowMetrics.iconWidth)

            Text(item.name)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.isDir, let size = FolderPaths.size(item.size) {
                Text(size)
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var icon: String {
        item.isDir ? "folder.fill" : FileIcon.symbol(for: item.name)
    }
    private var iconTint: Color {
        item.isDir ? Theme.accent : Theme.textSecondary
    }
}

/// Maps a filename to an SF Symbol so the browser reads at a glance. Deliberately
/// small — a handful of common developer file kinds, everything else a generic doc.
enum FileIcon {
    static func symbol(for name: String) -> String {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "swift", "rs", "go", "py", "rb", "java", "kt", "c", "h", "cpp", "cc",
             "js", "jsx", "ts", "tsx", "sh", "bash", "zsh":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "plist", "lock", "ini", "env", "cfg", "conf":
            return "gearshape"
        case "md", "markdown", "txt", "rst", "adoc":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp", "ico", "pdf":
            return "photo"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar":
            return "shippingbox"
        case "html", "htm", "css", "scss", "sass":
            return "globe"
        default:
            // Dotfiles (.gitignore, .env) read as config.
            if lower.hasPrefix(".") { return "gearshape" }
            return "doc"
        }
    }
}

// MARK: - File preview

/// A read-only file viewer: fetches text via `read_file_preview` (path made
/// relative to the folder root) and renders it as monospaced, line-numbered,
/// selectable code on the sunken code surface.
struct FilePreviewView: View {
    let client: CodegClient
    let rootPath: String
    let absPath: String

    @State private var content: String?
    @State private var isLoading = false
    @State private var error: String?

    private var name: String { (absPath as NSString).lastPathComponent }

    var body: some View {
        ZStack {
            CodegBackground()
            content(for: self.content)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let content, !content.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .tint(Theme.accent)
                    .accessibilityLabel("Copy file contents")
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private func content(for text: String?) -> some View {
        if isLoading {
            LoadingView(label: "Loading \(name)…")
        } else if let error {
            InlineErrorView(message: error) { Task { await load() } }
        } else if let text {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                EmptyStateView(icon: "doc", title: "Empty File", message: "This file has no contents.")
            } else {
                // Outer vertical scroll keeps the card top-anchored and lets long
                // files scroll; the card itself hugs its content.
                ScrollView(.vertical) {
                    FileContentView(text: text, relativePath: FolderPaths.relative(absPath, to: rootPath))
                        .padding(.horizontal, Theme.Layout.screenHMargin)
                        .padding(.vertical, 12)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        let relative = FolderPaths.relative(absPath, to: rootPath)
        do {
            content = try await client.readFilePreview(rootPath: rootPath, path: relative).content
        } catch {
            self.error = APIError.userMessage(error)
        }
        isLoading = false
    }
}

/// The scrollable monospaced body of a file, with a left line-number gutter.
/// Horizontally scrollable so long lines don't wrap; vertically capped for very
/// large files so a giant blob can't stall the view.
private struct FileContentView: View {
    let text: String
    let relativePath: String

    /// Guard against pathologically large files dominating the render.
    private static let maxLines = 4000

    private var lines: [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
    private var truncated: Bool { lines.count > Self.maxLines }
    private var shown: ArraySlice<Substring> { lines.prefix(Self.maxLines) }
    private var gutterWidth: CGFloat {
        // Widen the gutter for files with many lines.
        let digits = String(min(lines.count, Self.maxLines)).count
        return CGFloat(digits) * 8 + 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            // Horizontal-only scroll for long lines; the rows themselves lay out
            // at natural height so the surrounding card hugs the content (and the
            // outer vertical ScrollView handles tall files).
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(idx + 1)")
                                .font(.mono(11))
                                .foregroundStyle(Theme.textTertiary.opacity(0.7))
                                .frame(width: gutterWidth, alignment: .trailing)
                                .padding(.trailing, 8)
                            Text(line.isEmpty ? " " : String(line))
                                .font(.mono(12))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .padding(.trailing, 14)
                        }
                        .padding(.vertical, 0.5)
                    }
                    if truncated {
                        Text("… file truncated at \(Self.maxLines) lines")
                            .font(.mono(11))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(Theme.codeSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .hairlineBorder(Theme.Radius.md)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: FileIcon.symbol(for: relativePath))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            (relativePath.isEmpty ? Text("file") : Text(verbatim: relativePath))
                .font(.mono(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Text("\(lines.count) lines")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
