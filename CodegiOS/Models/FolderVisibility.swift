import Foundation

/// Pure folder-visibility + branch-switch routing, ported from the codeg web
/// client (`src/lib/folder-display.ts`, `src/lib/branch-switch.ts`,
/// `src/components/conversations/sidebar-conversation-*`).
///
/// Worktree folders carry a `parentId` (their root repo). The web hides a
/// worktree folder from the folder list when its root is also open and merges
/// its conversations into the root's group; the branch switcher resolves a chosen
/// branch to where it's checked out and routes the switch accordingly. These
/// helpers are deterministic (no I/O), so the list view models and the session
/// detail view model can share them and they're trivially testable.
enum FolderVisibility {
    /// Map each open worktree-child folder id → its (open) parent id. A child is
    /// only redirected when its parent is ALSO in `open`: a worktree whose root is
    /// closed stands on its own. Port of `sidebar-conversation-list` `childToParent`.
    static func childToParent(_ open: [FolderDetail]) -> [Int: Int] {
        let openIds = Set(open.map(\.id))
        var map: [Int: Int] = [:]
        for f in open {
            if let pid = f.parentId, openIds.contains(pid) {
                map[f.id] = pid
            }
        }
        return map
    }

    /// The folders that get their own list row / group: every open folder NOT
    /// hidden as a worktree child of an open parent. (`list_open_folder_details`
    /// already excludes `chat` folders server-side; we defend against it anyway.)
    /// Input order is preserved — callers re-sort for display.
    static func visibleFolders(_ open: [FolderDetail]) -> [FolderDetail] {
        let hidden = childToParent(open)
        return open.filter { hidden[$0.id] == nil && $0.kind != .chat }
    }

    /// The folder id a conversation should be grouped under: its worktree's root
    /// when the worktree is hidden, else its own folder. Port of
    /// `groupByFolderWithReuse`'s redirect.
    static func mergedFolderId(_ folderId: Int, childToParent: [Int: Int]) -> Int {
        childToParent[folderId] ?? folderId
    }

    /// Top-level folders only (`parentId == nil`) — the new-session folder picker
    /// must not target a worktree directly. Port of `filterTopLevelFolders`.
    static func filterTopLevel(_ folders: [FolderDetail]) -> [FolderDetail] {
        folders.filter { $0.parentId == nil && $0.kind != .chat }
    }

    /// The root repo folder for `folder` (itself when top-level, or when the
    /// parent isn't in `all`). Port of `resolveRootFolder`.
    static func resolveRoot(_ folder: FolderDetail, in all: [FolderDetail]) -> FolderDetail {
        guard let pid = folder.parentId else { return folder }
        return all.first { $0.id == pid } ?? folder
    }

    /// Display name for `folder`: the root repo's name when `folder` is a
    /// worktree, else its own name. Port of `resolveFolderDisplayName`.
    static func displayName(of folder: FolderDetail, in all: [FolderDetail]) -> String {
        guard let pid = folder.parentId else { return folder.name }
        return all.first { $0.id == pid }?.name ?? folder.name
    }

    // MARK: - Branch switch routing

    /// Where a branch switch should land. Port of `branch-switch.ts`'s
    /// `BranchSwitchPlan`.
    enum BranchSwitchPlan: Equatable {
        /// Already on this branch in this folder — nothing to do.
        case noop
        /// Branch is checked out in an already-registered folder → open a session there.
        case navigateRegistered(folderId: Int)
        /// Branch is in an unregistered worktree dir → register it (parented to
        /// `rootId`), then open a session there.
        case navigateExternal(path: String, rootId: Int)
        /// Branch isn't checked out in any worktree (or it's a remote pick) →
        /// `git checkout` in the repo root.
        case checkoutInRoot(root: FolderDetail)
    }

    /// Decide how to switch `active` to `branch`, given the worktree `resolution`
    /// (`nil` for a remote pick or when resolution failed) and the full folder
    /// set. Port of `planBranchSwitch`.
    static func planBranchSwitch(
        active: FolderDetail,
        resolution: WorktreeResolution?,
        allFolders: [FolderDetail],
        isRemote: Bool
    ) -> BranchSwitchPlan {
        let root = resolveRoot(active, in: allFolders)
        // Remote selection or "not checked out anywhere" → checkout in the root.
        guard !isRemote, let resolution, let path = resolution.path else {
            return .checkoutInRoot(root: root)
        }
        if resolution.folderId == active.id { return .noop }
        if let folderId = resolution.folderId { return .navigateRegistered(folderId: folderId) }
        return .navigateExternal(path: path, rootId: root.id)
    }
}
