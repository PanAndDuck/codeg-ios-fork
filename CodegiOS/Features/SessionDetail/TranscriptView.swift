import SwiftUI

// MARK: - Scroll action (environment)

/// A scroll capability the transcript publishes into the environment so any
/// descendant (an assistant reply's "scroll to question" button) can move the
/// viewport without threading the `ScrollViewProxy` down by hand.
struct TranscriptScrollAction {
    let perform: (String, UnitPoint) -> Void
    func callAsFunction(_ id: String, anchor: UnitPoint = .top) { perform(id, anchor) }
}

private struct TranscriptScrollKey: EnvironmentKey {
    static let defaultValue = TranscriptScrollAction { _, _ in }
}

extension EnvironmentValues {
    var transcriptScroll: TranscriptScrollAction {
        get { self[TranscriptScrollKey.self] }
        set { self[TranscriptScrollKey.self] = newValue }
    }
}

// MARK: - Transcript

/// One reveal can exhaust the small local render tail and need a server page in
/// the same action; waiting for another near-top transition can strand paging.
enum TranscriptPaging {
    static func earlierPage(turns: [MessageTurn], renderedStart: Int, hasEarlier: Bool) -> (start: Int, fetchFromServer: Bool) {
        var start = min(max(0, renderedStart - 150), max(0, turns.count - 1))
        while start > 0, turns[start].role == .assistant { start -= 1 }
        return (start, start == 0 && hasEarlier)
    }
}

/// The scrollable transcript, rendered as a **vertical timeline**: a continuous
/// rail runs top-to-bottom and every event — each user message, reasoning block,
/// tool call, tool group, assistant text segment, and system note — is a node on
/// it (`TranscriptTimeline.buildPersisted` flattens persisted + optimistic pending
/// turns and `buildLive` the live streaming turn, into `[TimelineNode]`). An
/// optional leading `header` scrolls away above the first node.
///
/// Backed by `List` (UICollectionView-backed) so it recycles cells and only
/// realizes on-screen rows — the iOS-native counterpart to the web client's
/// `virtua` windowing — which suits the timeline well (many small per-part rows).
/// `.defaultScrollAnchor(.bottom)` puts the first paint at the newest node.
///
/// To keep opening a very long session fast, only a **window** of the most recent
/// turns is built and rendered initially; older turns are revealed as the user
/// scrolls up (see the windowing section below). This bounds the on-open work —
/// decode aside, both node construction and the initial `List` layout become
/// O(window) rather than O(history).
struct TranscriptView<Header: View>: View {
    let turns: [MessageTurn]
    let pendingUserTurns: [MessageTurn]
    let liveTurn: LiveTurn?
    /// When the live turn was rebuilt from a reattach snapshot, it is the
    /// authoritative complete in-flight reply; the persisted partial copy the
    /// agent is concurrently writing into `turns` is hidden so it isn't doubled.
    var liveOwnsInFlightReply: Bool = false
    /// The session's agent, for the agent-branded marker on assistant nodes.
    let agent: AgentType
    /// A cheap, monotonic version of the view model's `turns`, bumped on every
    /// mutation. The persisted node tier is memoized on it (plus the window /
    /// pending / suppression signals), so a streamed token — which re-runs this
    /// view via `scrollTick` — no longer rebuilds and re-hashes the whole visible
    /// transcript to follow the scroll.
    let turnsVersion: Int
    /// Bumped on streamed content growth; the transcript follows it ONLY while
    /// pinned to the bottom.
    let scrollTick: Int
    /// Bumped on the user's own send / initial load; forces a re-pin regardless
    /// of the current scroll position.
    let stickTick: Int
    /// Reports whether the viewport is parked at the bottom. The owning view uses
    /// it to show/hide the floating "jump to latest" button (which lives above the
    /// compose bar, not here, so it is reliably tappable).
    let onPinnedChange: (Bool) -> Void
    var hasEarlierTurns: Bool = false
    var isFetchingEarlier: Bool = false
    var earlierTurnsError: String? = nil
    var historyResetTick: Int = 0
    var onLoadEarlier: () async -> Void = {}
    /// Scrolls with the content as the first element (header above the first
    /// node). Kept generic so the transcript stays agnostic of the header's type.
    @ViewBuilder var header: () -> Header

    private let bottomAnchor = "transcript-bottom-anchor"

    /// Whether the viewport is parked at (or near) the bottom. Drives the
    /// auto-follow (only follow streamed tokens when true). Starts true so a fresh
    /// open follows.
    @State private var stuckToBottom = true
    @State private var isUserScrolling = false
    /// Geometry is bookkeeping, not render state: scrolling must not rebuild
    /// the node list just to record the frames of realized cells.
    private final class ViewportMemo {
        var rowFrames: [String: CGRect] = [:]
        var height: CGFloat = 0
    }
    @State private var viewport = ViewportMemo()
    @State private var earlierAnchor: (id: String, anchor: UnitPoint)?

    private struct RowFramesKey: PreferenceKey {
        static var defaultValue: [String: CGRect] { [:] }
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, new in new })
        }
    }

    /// Layout changes must not be mistaken for the user scrolling into history.
    private struct ScrollMetrics: Equatable {
        var atBottom: Bool
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var bottomInset: CGFloat
        var offsetY: CGFloat

        init(_ geometry: ScrollGeometry) {
            contentHeight = geometry.contentSize.height
            containerHeight = geometry.containerSize.height
            bottomInset = geometry.contentInsets.bottom
            offsetY = geometry.contentOffset.y
            atBottom = contentHeight
                - (geometry.contentOffset.y + containerHeight - bottomInset) <= 80
        }
    }

    // MARK: Windowing
    //
    // A very long transcript (thousands of turns) is expensive to open: the whole
    // history is decoded, every turn is flattened into nodes, and `List` lays out
    // the full set before the first frame — on a 6k-turn session that's hundreds of
    // ms of on-main work, exactly the cost the web client avoids by virtualizing.
    // So we only build + render a *window* of the most recent turns initially, and
    // load older ones when the user scrolls up. `build` + the `List` layout become
    // O(window) instead of O(history), so open time stops growing with length.
    // Explicit paging expands that rendered history; the node memo and List's
    // cell recycling avoid repeated work between history mutations.
    //
    // `windowStartTurn` is the local index into `turns` where rendering begins;
    // `nil` means "not yet expanded" → the window is anchored to the tail and
    // follows new turns. A network prepend expands this to zero, and a server
    // compaction resets it to nil.

    /// How many trailing turns to show on first open. Enough to fill the viewport
    /// with room to spare; small enough that layout is instant.
    private let initialTurnWindow = 50
    /// Distance from the top (pt) at which to begin loading older turns — generous
    /// so history is ready before the user reaches the very top.
    private let loadEarlierThreshold: CGFloat = 600

    @State private var windowStartTurn: Int?
    /// Re-entrancy guard so a burst of near-top scroll events loads one page, not many.
    @State private var isLoadingEarlier = false

    // MARK: Node memoization
    //
    // `body` re-runs on every streamed token (the scroll-follow bumps `scrollTick`),
    // but the *persisted* node tier changes only when `turns` / the window / pending
    // / in-flight suppression change — never per token. Rebuilding it per token is
    // O(all visible text): `MessageRender.adaptTurn`'s value-keyed cache hashes each
    // `MessageTurn`'s full content on lookup (`MessageTurn` is content-`Hashable`).
    // So the persisted tier is memoized behind this cheap, content-free key and only
    // rebuilt when the key changes. The live tier is always rebuilt fresh (cheap,
    // and required so live tool / plan state doesn't freeze — see `buildLive`).
    //
    // The cache lives in a reference holder (a plain class) so it survives the
    // per-token re-instantiation of this struct at its fixed position, and so the
    // `nodes` accessor can update it without tripping `@State` invalidation: we
    // mutate the holder's fields, never reassign the `@State`. Safe because `body`
    // and the builders are `@MainActor`, so every access is serialized.
    private struct PersistedKey: Equatable {
        var turnsVersion: Int
        var effectiveStart: Int
        var pendingIDs: [String]
        var suppressInFlight: Bool
        var agent: AgentType
    }
    private final class PersistedMemo {
        var key: PersistedKey?
        var nodes: [TimelineNode] = []
    }
    @State private var persistedMemo = PersistedMemo()

    /// The first turn index currently shown. When not explicitly expanded, anchors
    /// to the tail (most recent `initialTurnWindow` turns), snapped back to a
    /// user/system boundary so an assistant reply is never split and keeps its
    /// originating question in-window (jump-to-question stays correct).
    private var effectiveStart: Int {
        if let s = windowStartTurn { return min(max(0, s), turns.count) }
        guard turns.count > initialTurnWindow else { return 0 }
        return snappedStart(turns.count - initialTurnWindow)
    }

    /// Whether the window reaches the true start of the conversation (everything
    /// loaded). Only then is the scrollaway `header` shown and the rail's top capped.
    private var headLoaded: Bool { effectiveStart == 0 && !hasEarlierTurns }

    /// Walk back from `desired` to the nearest non-assistant (user/system) turn so
    /// the window never starts in the middle of a merged assistant reply.
    private func snappedStart(_ desired: Int) -> Int {
        guard !turns.isEmpty else { return 0 }
        var i = min(max(0, desired), turns.count - 1)
        while i > 0, turns[i].role == .assistant { i -= 1 }
        return i
    }

    /// The flattened timeline: a memoized **persisted** tier + a fresh **live**
    /// tier. The persisted tier is expensive (it hashes every visible turn's content
    /// through `adaptTurn`'s cache), so it is reused whenever the cheap `PersistedKey`
    /// is unchanged — which is every streamed token. The live tier is rebuilt each
    /// pass (cheap; keeps live tool / plan cards updating). Rail endpoints are
    /// terminated on the *combined* list so the tail's `connectBottom` lands on the
    /// live node while a reply streams.
    private var nodes: [TimelineNode] {
        let start = effectiveStart
        let suppressInFlight = liveTurn != nil && liveOwnsInFlightReply
        let key = PersistedKey(
            turnsVersion: turnsVersion,
            effectiveStart: start,
            pendingIDs: pendingUserTurns.map(\.id),
            suppressInFlight: suppressInFlight,
            agent: agent
        )

        let persisted: [TimelineNode]
        if persistedMemo.key == key {
            persisted = persistedMemo.nodes
        } else {
            let slice = start == 0 ? turns : Array(turns[start...])
            persisted = TranscriptTimeline.buildPersisted(
                turns: slice, pending: pendingUserTurns, agent: agent,
                suppressInFlight: suppressInFlight
            )
            persistedMemo.key = key
            persistedMemo.nodes = persisted
        }

        var all = persisted
        if let liveTurn {
            all.append(contentsOf: TranscriptTimeline.buildLive(liveTurn, agent: agent))
        }
        // Terminate the rail at its endpoints, on the *combined* list. The top
        // terminates only when the window starts at the true beginning of the
        // conversation; otherwise the spine continues up into the not-yet-loaded
        // turns.
        if !all.isEmpty {
            if headLoaded { all[0].connectTop = false }
            all[all.count - 1].connectBottom = false
        }
        return all
    }

    /// Save an actually visible row and its viewport-relative position. Restoring
    /// that stable id handles variable-height message rows without relying on an
    /// estimated content-height delta from List's recycled cells.
    private func loadEarlier(_ proxy: ScrollViewProxy) {
        let cur = effectiveStart
        guard !headLoaded, !isLoadingEarlier, !isFetchingEarlier else { return }
        stuckToBottom = false
        onPinnedChange(false)
        if let row = viewport.rowFrames.filter({ $0.value.maxY > 0 && $0.value.minY < viewport.height })
            .min(by: { abs($0.value.minY) < abs($1.value.minY) }) {
            let available = viewport.height - row.value.height
            earlierAnchor = (row.key, UnitPoint(x: 0.5, y: abs(available) > 1 ? row.value.minY / available : 0))
        }
        let page = TranscriptPaging.earlierPage(turns: turns, renderedStart: cur, hasEarlier: hasEarlierTurns)
        isLoadingEarlier = true
        windowStartTurn = page.start
        Task { @MainActor in
            if page.fetchFromServer { await onLoadEarlier() }
            // Let the new rows enter List's layout before restoring the anchor.
            await Task.yield()
            restoreEarlierAnchor(proxy)
            try? await Task.sleep(for: .milliseconds(80))
            restoreEarlierAnchor(proxy)
            isLoadingEarlier = false
        }
    }

    private func restoreEarlierAnchor(_ proxy: ScrollViewProxy) {
        guard !stuckToBottom, let earlierAnchor else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(earlierAnchor.id, anchor: earlierAnchor.anchor) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // Top of the list. When the whole history is loaded, the `header`
                // scrolls above the first node (no gutter marker, standard margin).
                // While older turns are still windowed out, show a compact spinner
                // there during a load instead — the rail keeps `connectTop` so the
                // spine reads as continuing up into the not-yet-loaded history.
                if headLoaded {
                    header()
                        .modifier(TimelineRowChrome(top: 12, leading: TimelineMetrics.rowTrailingInset))
                } else {
                    VStack(spacing: 8) {
                        if isLoadingEarlier || isFetchingEarlier {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("Load earlier messages")
                        } else {
                            Button("Load earlier messages") { loadEarlier(proxy) }
                        }
                        if let earlierTurnsError {
                            Text(earlierTurnsError).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .modifier(TimelineRowChrome(top: 14, leading: TimelineMetrics.rowTrailingInset))
                }

                ForEach(nodes) { node in
                    TimelineRailRow(
                        marker: node.marker,
                        connectTop: node.connectTop,
                        connectBottom: node.connectBottom,
                        startsGroup: node.startsGroup
                    ) {
                        NodeBody(node: node)
                    }
                    .modifier(TimelineRowChrome())
                    // Fade newly-inserted nodes in (the optimistic user bubble on
                    // send, the thinking tick, each streamed segment) instead of a
                    // hard cut. Pure opacity only — a geometric transition would
                    // seam the continuous rail. Driven by the `.animation(value:)`
                    // on the transcript in `SessionDetailView`.
                    .transition(.opacity)
                    .id(node.id)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: RowFramesKey.self,
                                value: [node.id: geometry.frame(in: .named("transcript-viewport"))])
                        }
                    }
                }

                // Zero-height anchor we scroll to (a little top inset keeps the
                // last node off the compose bar). Outside the rail (no gutter).
                Color.clear
                    .frame(height: 1)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .id(bottomAnchor)
            }
            .listStyle(.plain)
            .coordinateSpace(name: "transcript-viewport")
            .onPreferenceChange(RowFramesKey.self) { viewport.rowFrames = $0 }
            .scrollContentBackground(.hidden)
            // Let the 1pt anchor row actually be 1pt (List's default min row
            // height would otherwise pad it to ~44).
            .environment(\.defaultMinListRowHeight, 1)
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Publish a scroll capability so a reply's "scroll to question" button
            // (deep inside a row) can move the viewport to the user message.
            .environment(\.transcriptScroll, TranscriptScrollAction { id, anchor in
                earlierAnchor = nil
                stuckToBottom = false
                onPinnedChange(false)
                withAnimation(Theme.Motion.scroll) {
                    proxy.scrollTo(id, anchor: anchor)
                }
            })
            .onScrollPhaseChange { _, phase, context in
                if phase == .tracking || phase == .interacting { earlierAnchor = nil }
                let wasUserScrolling = isUserScrolling
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                if isUserScrolling || wasUserScrolling {
                    let atBottom = ScrollMetrics(context.geometry).atBottom
                    stuckToBottom = atBottom
                    onPinnedChange(atBottom)
                }
            }
            // Keep following through keyboard/compose inset changes and late
            // List row measurement. Only a user scroll can unpin the viewport;
            // shrinking its visible area or inserting rows cannot revoke intent.
            .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0) } action: { old, new in
                viewport.height = new.containerHeight
                if isUserScrolling {
                    if old.offsetY != new.offsetY { earlierAnchor = nil }
                    stuckToBottom = new.atBottom
                    onPinnedChange(new.atBottom)
                } else if stuckToBottom {
                    if old.contentHeight != new.contentHeight
                        || old.containerHeight != new.containerHeight
                        || old.bottomInset != new.bottomInset {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                } else if earlierAnchor != nil, old.contentHeight != new.contentHeight {
                    // Images/markdown may finish measuring after the first layout.
                    // Keep the reading anchor until the next intentional scroll.
                    restoreEarlierAnchor(proxy)
                } else if new.atBottom, !isLoadingEarlier {
                    stuckToBottom = true
                    onPinnedChange(true)
                }
            }
            // Reveal older turns as the user scrolls toward the top. Mapped to a
            // Bool so `action` fires only when crossing into the near-top zone (not
            // every pixel); inserting rows above shifts the user out of the zone, so
            // it re-arms naturally for the next page on the next upward scroll.
            .onScrollGeometryChange(for: Bool.self) { geo in
                (geo.contentOffset.y + geo.contentInsets.top) < loadEarlierThreshold
            } action: { _, nearTop in
                // `!stuckToBottom` rejects the transient near-top geometry reported
                // while the list is still settling onto the bottom anchor at open —
                // otherwise a fresh open would immediately page in older history.
                if nearTop, !stuckToBottom, !headLoaded, !isLoadingEarlier { loadEarlier(proxy) }
            }
            .onChange(of: historyResetTick) { _, _ in
                windowStartTurn = nil
                earlierAnchor = nil
            }
            // Streamed growth: follow instantly, but ONLY while pinned. A single
            // plain `scrollTo` per tick (no re-assert) — the content is already
            // moving, so anything heavier stacks and stutters.
            .onChange(of: scrollTick) { _, _ in
                guard stuckToBottom else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            // Force re-pin (user send / initial load / jump-to-latest tap),
            // regardless of scroll state. Routed through `scrollToBottom`, which
            // re-asserts on the next runloop: the first pass can stop short when
            // rich content (code blocks / markdown) is still measuring taller, so
            // a far jump would otherwise land above the true bottom.
            .onChange(of: stickTick) { _, _ in
                earlierAnchor = nil
                stuckToBottom = true
                onPinnedChange(true)
                scrollToBottom(proxy)
            }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    /// Reassert a far jump after List has realized its destination rows.
    /// Subsequent layout changes are followed by the geometry observer above.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard stuckToBottom, !isUserScrolling else { return }
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }
}

/// Shared chrome for a timeline row: transparent background, no separators, and
/// the timeline's leading/trailing insets (the leading one lines the gutter marker
/// up with the nav bar's leading button). Vertical insets are 0 — the per-node
/// vertical rhythm is baked into `TimelineRailRow` so the continuous rail
/// background spans the inter-node spacing (a `listRowInsets` gap would break the
/// spine). The header row passes a small `top` since it has no rail of its own.
private struct TimelineRowChrome: ViewModifier {
    var top: CGFloat = 0
    /// Leading inset. Defaults to the rail's wider inset (which lines the gutter
    /// marker up with the nav button); the marker-less header overrides it to the
    /// standard symmetric margin.
    var leading: CGFloat = TimelineMetrics.rowLeadingInset

    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: top,
                leading: leading,
                bottom: 0,
                trailing: TimelineMetrics.rowTrailingInset
            ))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
