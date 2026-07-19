import Foundation
import SoloShotContracts

enum CaptureClientError: LocalizedError, Equatable, Sendable {
    case invalidToken
    case providerUnavailable
    case uploadURLExpired
    case offline
    case invalidResponse
    case payloadTooLarge
    case server(code: String, message: String, recoverable: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidToken: "任务凭据无效，请重新导入。"
        case .providerUnavailable: "方舟评价暂未配置；照片已安全保留，可稍后重试。"
        case .uploadURLExpired: "上传地址已过期，正在申请新地址。"
        case .offline: "当前网络不可用；已选择的照片只保存在本机。"
        case .invalidResponse: "服务响应与当前 App 契约不一致。"
        case .payloadTooLarge: "所选 JPEG 超过 8MB，请重新选择。"
        case let .server(_, message, _): message
        }
    }

    var code: String {
        switch self {
        case .invalidToken: "HANDOFF_INVALID_TOKEN"
        case .providerUnavailable: "PROVIDER_UNAVAILABLE"
        case .uploadURLExpired: "UPLOAD_URL_EXPIRED"
        case .offline: "NETWORK_ERROR"
        case .invalidResponse: "INVALID_JSON"
        case .payloadTooLarge: "PAYLOAD_TOO_LARGE"
        case let .server(code, _, _): code
        }
    }
}

protocol CaptureSubmissionClient: Sendable {
    func recordConsent(
        sessionID: String,
        externalAIConsent: Bool,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> CaptureConsentReceipt
    func createUpload(
        sessionID: String,
        byteSize: Int,
        sha256: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> MediaUploadTicket
    func putJPEG(_ data: Data, ticket: MediaUploadTicket) async throws
    func completeUpload(
        sessionID: String,
        mediaAssetID: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> MediaAsset
    func createCapture(
        sessionID: String,
        round: CaptureRoundWork,
        mediaAssetID: String,
        claimToken: String
    ) async throws -> Capture
    func evaluate(
        sessionID: String,
        captureID: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> ResultEvaluation
}

private struct CaptureAPIEnvelope<Value: Decodable>: Decodable {
    let data: Value
}

private struct CaptureAPIErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
        let recoverable: Bool
    }

    let error: Body
}

private struct ConsentBody: Encodable {
    let schemaVersion = "1.0"
    let captureUploadConsent = true
    let externalAIConsent: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureUploadConsent = "capture_upload_consent"
        case externalAIConsent = "external_ai_consent"
    }
}

private struct UploadBody: Encodable {
    let schemaVersion = "1.0"
    let sessionID: String
    let purpose = "capture"
    let contentType = "image/jpeg"
    let byteSize: Int
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case purpose
        case contentType = "content_type"
        case byteSize = "byte_size"
        case sha256
    }
}

private struct CompleteUploadBody: Encodable {
    let schemaVersion = "1.0"
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
    }
}

private struct CaptureBody: Encodable {
    struct Frame: Encodable {
        let frameID: String
        let timestampMilliseconds: Int?
        let selectionSource: String

        enum CodingKeys: String, CodingKey {
            case frameID = "frame_id"
            case timestampMilliseconds = "timestamp_ms"
            case selectionSource = "selection_source"
        }
    }

    let schemaVersion = "1.0"
    let sessionID: String
    let roundIndex: Int
    let mediaAssetID: String
    let captureMethod: String
    let frameSelection: Frame

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case roundIndex = "round_index"
        case mediaAssetID = "media_asset_id"
        case captureMethod = "capture_method"
        case frameSelection = "frame_selection"
    }
}

private struct EvaluationBody: Encodable {
    let schemaVersion = "1.0"
    let sessionID: String
    let captureID: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case captureID = "capture_id"
    }
}

actor CaptureAPI: CaptureSubmissionClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
            }
            return date
        }
    }

    func recordConsent(
        sessionID: String,
        externalAIConsent: Bool,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> CaptureConsentReceipt {
        var request = apiRequest(
            path: "/api/v1/sessions/\(sessionID)/capture-consent",
            method: "POST",
            claimToken: claimToken,
            idempotencyKey: idempotencyKey
        )
        request.httpBody = try encoder.encode(ConsentBody(externalAIConsent: externalAIConsent))
        return try await send(request, as: CaptureConsentReceipt.self)
    }

    func createUpload(
        sessionID: String,
        byteSize: Int,
        sha256: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> MediaUploadTicket {
        guard byteSize <= 8_000_000 else { throw CaptureClientError.payloadTooLarge }
        var request = apiRequest(
            path: "/api/v1/media/uploads",
            method: "POST",
            claimToken: claimToken,
            idempotencyKey: idempotencyKey
        )
        request.httpBody = try encoder.encode(UploadBody(
            sessionID: sessionID,
            byteSize: byteSize,
            sha256: sha256
        ))
        return try await send(request, as: MediaUploadTicket.self)
    }

    func putJPEG(_ data: Data, ticket: MediaUploadTicket) async throws {
        guard let url = URL(string: ticket.uploadUrl) else {
            throw CaptureClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.httpBody = data
        for (name, value) in ticket.uploadHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CaptureClientError.invalidResponse
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw CaptureClientError.uploadURLExpired
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw CaptureClientError.server(
                    code: "UPLOAD_FAILED",
                    message: "候选帧上传失败。",
                    recoverable: true
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CaptureClientError {
            throw error
        } catch {
            throw CaptureClientError.offline
        }
    }

    func completeUpload(
        sessionID: String,
        mediaAssetID: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> MediaAsset {
        var request = apiRequest(
            path: "/api/v1/media/uploads/\(mediaAssetID)/complete",
            method: "POST",
            claimToken: claimToken,
            idempotencyKey: idempotencyKey
        )
        request.httpBody = try encoder.encode(CompleteUploadBody(sessionID: sessionID))
        return try await send(request, as: MediaAsset.self)
    }

    func createCapture(
        sessionID: String,
        round: CaptureRoundWork,
        mediaAssetID: String,
        claimToken: String
    ) async throws -> Capture {
        guard let selected = round.selectedCandidate,
              let selection = round.selectionSource
        else {
            throw CaptureWorkStoreError.missingSelectedFrame
        }
        var request = apiRequest(
            path: "/api/v1/captures",
            method: "POST",
            claimToken: claimToken,
            idempotencyKey: round.captureIdempotencyKey
        )
        request.httpBody = try encoder.encode(CaptureBody(
            sessionID: sessionID,
            roundIndex: round.roundIndex,
            mediaAssetID: mediaAssetID,
            captureMethod: round.captureMethod.rawValue,
            frameSelection: .init(
                frameID: selected.id,
                timestampMilliseconds: selected.timestampMilliseconds,
                selectionSource: selection.rawValue
            )
        ))
        return try await send(request, as: Capture.self)
    }

    func evaluate(
        sessionID: String,
        captureID: String,
        claimToken: String,
        idempotencyKey: String
    ) async throws -> ResultEvaluation {
        var request = apiRequest(
            path: "/api/v1/evaluations",
            method: "POST",
            claimToken: claimToken,
            idempotencyKey: idempotencyKey
        )
        request.timeoutInterval = 45
        request.httpBody = try encoder.encode(EvaluationBody(sessionID: sessionID, captureID: captureID))
        return try await send(request, as: ResultEvaluation.self)
    }

    private func apiRequest(
        path: String,
        method: String,
        claimToken: String,
        idempotencyKey: String
    ) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(claimToken, forHTTPHeaderField: "X-Handoff-Claim-Token")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        return request
    }

    private func send<Value: Decodable>(_ request: URLRequest, as type: Value.Type) async throws -> Value {
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw CaptureClientError.invalidResponse
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw mapError(data)
            }
            guard let value = try? decoder.decode(CaptureAPIEnvelope<Value>.self, from: data).data else {
                throw CaptureClientError.invalidResponse
            }
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CaptureClientError {
            throw error
        } catch {
            throw CaptureClientError.offline
        }
    }

    private func mapError(_ data: Data) -> CaptureClientError {
        guard let body = try? decoder.decode(CaptureAPIErrorEnvelope.self, from: data).error else {
            return .invalidResponse
        }
        return switch body.code {
        case "HANDOFF_INVALID_TOKEN": .invalidToken
        case "PROVIDER_UNAVAILABLE": .providerUnavailable
        default: .server(code: body.code, message: body.message, recoverable: body.recoverable)
        }
    }
}

extension CaptureEvaluation {
    init(_ evaluation: ResultEvaluation) {
        self.init(
            evaluationID: evaluation.evaluationId,
            captureID: evaluation.captureId,
            issueCode: evaluation.issueCode?.rawValue,
            topIssue: evaluation.topIssue,
            nextInstruction: evaluation.nextInstruction,
            needsRetake: evaluation.needsRetake,
            goalSatisfied: evaluation.goalSatisfied,
            publishReadiness: evaluation.publishReadiness,
            confidence: evaluation.confidence,
            executionMode: evaluation.executionMode?.rawValue ?? "fallback"
        )
    }
}
