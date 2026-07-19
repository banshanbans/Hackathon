import CryptoKit
import Foundation

actor CaptureOutbox {
    private let client: any CaptureSubmissionClient
    private let store: CaptureWorkStore

    init(client: any CaptureSubmissionClient, store: CaptureWorkStore) {
        self.client = client
        self.store = store
    }

    func resume(
        task: ImportedTask,
        work initialWork: CaptureWork,
        claimToken: String
    ) async throws -> CaptureWork {
        var work = initialWork
        guard work.expiresAt > Date(), var round = work.currentRound else {
            throw HandoffClientError.expired
        }

        if !work.captureConsentRecorded {
            _ = try await client.recordConsent(
                sessionID: work.sessionID,
                externalAIConsent: !task.usesFixtureEvaluation,
                claimToken: claimToken,
                idempotencyKey: work.consentIdempotencyKey
            )
            work.captureConsentRecorded = true
            work.externalAIConsentRecorded = !task.usesFixtureEvaluation
            round.networkStep = .upload
            replace(round, in: &work)
            try await store.save(work)
        }

        if round.networkStep == .consent { round.networkStep = .upload }
        if round.networkStep == .upload {
            let data = try await store.selectedFrameData(round)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let media = try await upload(
                data: data,
                sha256: digest,
                work: work,
                claimToken: claimToken
            )
            round.mediaAssetID = media
            round.networkStep = .createCapture
            replace(round, in: &work)
            try await store.save(work)
        }

        if round.networkStep == .createCapture {
            guard let mediaAssetID = round.mediaAssetID else {
                throw CaptureClientError.invalidResponse
            }
            let capture = try await client.createCapture(
                sessionID: work.sessionID,
                round: round,
                mediaAssetID: mediaAssetID,
                claimToken: claimToken
            )
            round.captureID = capture.captureId
            round.networkStep = .evaluate
            replace(round, in: &work)
            try await store.save(work)
        }

        if round.networkStep == .evaluate {
            guard let captureID = round.captureID else {
                throw CaptureClientError.invalidResponse
            }
            let result = try await client.evaluate(
                sessionID: work.sessionID,
                captureID: captureID,
                claimToken: claimToken,
                idempotencyKey: round.evaluationIdempotencyKey
            )
            round.evaluation = CaptureEvaluation(result)
            round.networkStep = .finished
            replace(round, in: &work)
            try await store.save(work)
        }
        return work
    }

    private func upload(
        data: Data,
        sha256: String,
        work: CaptureWork,
        claimToken: String
    ) async throws -> String {
        var lastError: Error?
        for _ in 0 ..< 2 {
            let attempt = "ios-upload-\(UUID().uuidString)"
            do {
                let ticket = try await client.createUpload(
                    sessionID: work.sessionID,
                    byteSize: data.count,
                    sha256: sha256,
                    claimToken: claimToken,
                    idempotencyKey: attempt
                )
                try await client.putJPEG(data, ticket: ticket)
                let asset = try await client.completeUpload(
                    sessionID: work.sessionID,
                    mediaAssetID: ticket.asset.mediaAssetId,
                    claimToken: claimToken,
                    idempotencyKey: "ios-complete-\(ticket.asset.mediaAssetId)"
                )
                return asset.mediaAssetId
            } catch CaptureClientError.uploadURLExpired {
                lastError = CaptureClientError.uploadURLExpired
            }
        }
        throw lastError ?? CaptureClientError.uploadURLExpired
    }

    private func replace(_ round: CaptureRoundWork, in work: inout CaptureWork) {
        guard let index = work.rounds.firstIndex(where: { $0.roundIndex == round.roundIndex }) else {
            return
        }
        work.rounds[index] = round
    }
}
