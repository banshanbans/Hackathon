import Combine
import Foundation
import SoloShotContracts

enum AppFlowState: Equatable {
    case launch
    case taskImport
    case importing
    case referenceSummary(ImportedTask)
    case recoverableError(message: String, code: String)
}

@MainActor
final class AppFlowModel: ObservableObject {
    @Published private(set) var state: AppFlowState = .launch
    @Published var codeInput = ""
    @Published private(set) var preview: HandoffTask?

    private let api: HandoffAPI
    private let secrets: KeychainStore
    private let tasks: ImportedTaskStore
    private var operation: Task<Void, Never>?

    init(
        api: HandoffAPI? = nil,
        secrets: KeychainStore = KeychainStore(),
        tasks: ImportedTaskStore = ImportedTaskStore()
    ) {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SoloShotAPIBaseURL") as? String
        let baseURL = URL(string: configured ?? "http://127.0.0.1:8000")!
        self.api = api ?? HandoffAPI(baseURL: baseURL)
        self.secrets = secrets
        self.tasks = tasks
    }

    deinit {
        operation?.cancel()
    }

    func start() async {
        if let cached = try? await tasks.loadUnchecked(), cached.expiresAt <= Date() {
            try? await tasks.clear()
            try? await secrets.removeClaimToken(code: cached.code)
            state = .taskImport
        } else if let cached = try? await tasks.load() {
            state = .referenceSummary(cached)
            if !cached.completionConfirmed {
                retryCompletion(for: cached)
            }
        } else {
            state = .taskImport
        }
    }

    func receive(_ url: URL) {
        do {
            codeInput = try DeepLinkParser.parse(url)
            loadPreview()
        } catch {
            state = .recoverableError(
                message: HandoffClientError.invalidCode.localizedDescription,
                code: HandoffClientError.invalidCode.code
            )
        }
    }

    func loadPreview() {
        operation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try DeepLinkParser.normalizeCode(codeInput)
                let safePreview = try await api.preview(code: code)
                try Task.checkCancellation()
                preview = safePreview
                codeInput = code
                state = .taskImport
            } catch is CancellationError {
                return
            } catch {
                show(error)
            }
        }
    }

    func confirmClaim() {
        guard preview?.status == .created else {
            show(HandoffClientError.invalidCode)
            return
        }
        operation?.cancel()
        state = .importing
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try DeepLinkParser.normalizeCode(codeInput)
                let clientID = try await secrets.clientInstanceID()
                let claim = try await api.claim(code: code, clientInstanceID: clientID)
                var imported = try ImportedTask.from(claim)
                try await secrets.saveClaimToken(claim.claimToken, code: code)
                try await tasks.save(imported)

                // The summary becomes visible immediately after the app-owned JSON is durable.
                state = .referenceSummary(imported)
                do {
                    _ = try await api.complete(
                        code: code,
                        clientInstanceID: clientID,
                        claimToken: claim.claimToken
                    )
                    imported.completionConfirmed = true
                    try await tasks.save(imported)
                    state = .referenceSummary(imported)
                } catch {
                    // The durable task remains usable offline. Launch recovery retries complete.
                }

                if let access = claim.referenceAccess,
                   let url = URL(string: access.downloadUrl)
                {
                    await cacheReference(url: url, task: imported)
                }
            } catch is CancellationError {
                state = .taskImport
            } catch {
                show(error)
            }
        }
    }

    func cancelImport() {
        operation?.cancel()
        operation = nil
        state = .taskImport
    }

    func retry() {
        preview = nil
        state = .taskImport
        if !codeInput.isEmpty {
            loadPreview()
        }
    }

    private func retryCompletion(for task: ImportedTask) {
        operation = Task { [weak self] in
            guard let self,
                  let token = try? await secrets.claimToken(code: task.code)
            else { return }
            do {
                let clientID = try await secrets.clientInstanceID()
                _ = try await api.complete(
                    code: task.code,
                    clientInstanceID: clientID,
                    claimToken: token
                )
                var updated = task
                updated.completionConfirmed = true
                try await tasks.save(updated)
                state = .referenceSummary(updated)
            } catch {
                // Offline cached summary remains the source of truth.
            }
        }
    }

    private func cacheReference(url: URL, task: ImportedTask) async {
        do {
            let data = try await api.downloadReference(from: url)
            let filename = try await tasks.saveReference(data, code: task.code)
            var updated = task
            updated.localReferenceFilename = filename
            try await tasks.save(updated)
            state = .referenceSummary(updated)
        } catch {
            // Explicit placeholder in the summary; the ShotPlan remains available.
        }
    }

    private func show(_ error: Error) {
        let mapped = error as? HandoffClientError ?? .network
        state = .recoverableError(
            message: mapped.localizedDescription,
            code: mapped.code
        )
    }
}
