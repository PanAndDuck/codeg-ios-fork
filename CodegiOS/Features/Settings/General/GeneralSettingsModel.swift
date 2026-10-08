import SwiftUI
import Observation

/// General settings: multi-agent delegation (round-tripped as raw JSON to
/// preserve `agent_defaults`), plus the ask-question and live-feedback toggles.
/// Delegation scalar edits are debounced so a stepper drag doesn't spam the
/// server (and only the final value is persisted).
@MainActor
@Observable
final class GeneralSettingsModel {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var phase: Phase = .loading
    var delegationEnabled = false
    var depthLimit = 3
    var completedCacheMaxMb = 0
    var feedbackEnabled = false
    var questionEnabled = true
    var saveError: String?

    /// The full delegation object as received (snake_case, incl. agent_defaults),
    /// re-sent verbatim with only the three edited scalars overwritten.
    private var delegationRaw: [String: Any] = [:]
    /// Coalescing serial-save state (no debounce: avoids dropping the final value
    /// on quick navigate-away and never cancels an in-flight request).
    private var delegationSaving = false
    private var delegationDirty = false

    private let client: CodegClient?

    init(client: CodegClient?) { self.client = client }

    func load() async {
        guard let client else { phase = .failed("No server selected."); return }
        do {
            let d = try await client.delegationSettingsRaw()
            delegationRaw = d
            delegationEnabled = d["enabled"] as? Bool ?? false
            depthLimit = d["depth_limit"] as? Int ?? 3
            completedCacheMaxMb = d["completed_cache_max_mb"] as? Int ?? 0
            feedbackEnabled = (try? await client.feedbackEnabled()) ?? feedbackEnabled
            questionEnabled = (try? await client.questionEnabled()) ?? questionEnabled
            phase = .loaded
        } catch {
            guard !APIError.isCancellation(error) else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Persist delegation via a coalescing serial sender: one request in flight,
    /// always sending the LATEST scalar values. Rapid stepper changes collapse to
    /// at most a couple of writes, and the final value is never dropped.
    func scheduleDelegationSave() {
        delegationDirty = true
        Task { await drainDelegationSave() }
    }

    private func drainDelegationSave() async {
        guard !delegationSaving, let client else { return }
        delegationSaving = true
        defer { delegationSaving = false }
        while delegationDirty {
            delegationDirty = false
            var settings = delegationRaw
            settings["enabled"] = delegationEnabled
            settings["depth_limit"] = depthLimit
            settings["completed_cache_max_mb"] = completedCacheMaxMb
            do {
                try await client.setDelegationSettingsRaw(settings)
                delegationRaw = settings
            } catch {
                saveError = APIError.userMessage(error)
                await load()
                return
            }
        }
    }

    // Explicit setters (invoked from the Toggles' set-binding, NOT a `.onChange`)
    // so a failure rollback updating the property can't re-trigger a save. Each
    // uses a coalescing serial sender (one request in flight, latest value wins)
    // so rapid toggles can't land out of order on the server. On failure the
    // displayed value is reconciled to the server's truth.

    private var feedbackSaving = false
    private var feedbackPending: Bool?

    func setFeedback(_ on: Bool) {
        feedbackEnabled = on
        feedbackPending = on
        Task { await drainFeedback() }
    }

    private func drainFeedback() async {
        guard !feedbackSaving, let client else { return }
        feedbackSaving = true
        defer { feedbackSaving = false }
        while let target = feedbackPending {
            feedbackPending = nil
            do { try await client.setFeedbackEnabled(target) }
            catch {
                saveError = APIError.userMessage(error)
                feedbackEnabled = (try? await client.feedbackEnabled()) ?? feedbackEnabled
                return
            }
        }
    }

    private var questionSaving = false
    private var questionPending: Bool?

    func setQuestion(_ on: Bool) {
        questionEnabled = on
        questionPending = on
        Task { await drainQuestion() }
    }

    private func drainQuestion() async {
        guard !questionSaving, let client else { return }
        questionSaving = true
        defer { questionSaving = false }
        while let target = questionPending {
            questionPending = nil
            do { try await client.setQuestionEnabled(target) }
            catch {
                saveError = APIError.userMessage(error)
                questionEnabled = (try? await client.questionEnabled()) ?? questionEnabled
                return
            }
        }
    }
}
