import Foundation
import SoloShotContracts

enum HandoffClientError: LocalizedError, Equatable, Sendable {
    case invalidCode
    case expired
    case revoked
    case alreadyClaimed
    case rateLimited
    case invalidToken
    case network
    case invalidResponse
    case server(code: String, message: String, recoverable: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidCode: "任务码格式无效。"
        case .expired: "任务码已过期，请在网页重新生成。"
        case .revoked: "任务码已被撤销。"
        case .alreadyClaimed: "任务已被另一台设备认领。"
        case .rateLimited: "尝试次数过多，请稍后再试。"
        case .invalidToken: "任务凭据无效，请重新导入。"
        case .network: "网络不可用；已缓存任务仍可离线查看。"
        case .invalidResponse: "服务响应与当前 App 契约不一致。"
        case let .server(_, message, _): message
        }
    }

    var code: String {
        switch self {
        case .invalidCode: "VALIDATION_ERROR"
        case .expired: "HANDOFF_EXPIRED"
        case .revoked: "HANDOFF_REVOKED"
        case .alreadyClaimed: "HANDOFF_ALREADY_CLAIMED"
        case .rateLimited: "HANDOFF_RATE_LIMITED"
        case .invalidToken: "HANDOFF_INVALID_TOKEN"
        case .network: "NETWORK_ERROR"
        case .invalidResponse: "INVALID_JSON"
        case let .server(code, _, _): code
        }
    }
}

private struct APIEnvelope<Value: Decodable>: Decodable {
    let data: Value
}

private struct APIErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let code: String
        let message: String
        let recoverable: Bool
    }

    let error: ErrorBody
}

private struct ClaimBody: Encodable {
    let schemaVersion = "1.0"
    let clientInstanceID: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case clientInstanceID = "client_instance_id"
    }
}

actor HandoffAPI {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let standard = ISO8601DateFormatter()
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            return date
        }
    }

    func preview(code: String) async throws -> HandoffTask {
        var request = request(path: "/api/v1/handoffs/\(code)", method: "GET")
        request.timeoutInterval = 5
        return try await send(request, as: HandoffTask.self)
    }

    func listAvailable(limit: Int = 20) async throws -> HandoffListResult {
        var request = request(path: "/api/v1/handoffs", method: "GET")
        request.url = request.url?.appending(
            queryItems: [URLQueryItem(name: "limit", value: String(limit))]
        )
        request.timeoutInterval = 5
        return try await send(request, as: HandoffListResult.self)
    }

    func claim(code: String, clientInstanceID: String) async throws -> HandoffClaimResult {
        var request = request(path: "/api/v1/handoffs/\(code)/claim", method: "POST")
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios-claim-\(UUID().uuidString)", forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try encoder.encode(ClaimBody(clientInstanceID: clientInstanceID))
        return try await send(request, as: HandoffClaimResult.self)
    }

    func complete(code: String, clientInstanceID: String, claimToken: String) async throws -> HandoffTask {
        var request = request(path: "/api/v1/handoffs/\(code)/complete", method: "POST")
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios-complete-\(UUID().uuidString)", forHTTPHeaderField: "Idempotency-Key")
        request.setValue(claimToken, forHTTPHeaderField: "X-Handoff-Claim-Token")
        request.httpBody = try encoder.encode(ClaimBody(clientInstanceID: clientInstanceID))
        return try await send(request, as: HandoffTask.self)
    }

    func downloadReference(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode),
                  data.count <= 8 * 1_024 * 1_024
            else {
                throw HandoffClientError.invalidResponse
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HandoffClientError {
            throw error
        } catch {
            throw HandoffClientError.network
        }
    }

    private func request(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send<Value: Decodable>(
        _ request: URLRequest,
        as type: Value.Type
    ) async throws -> Value {
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw HandoffClientError.invalidResponse
            }
            guard (200 ... 299).contains(http.statusCode) else {
                throw mapAPIError(data: data)
            }
            do {
                return try decoder.decode(APIEnvelope<Value>.self, from: data).data
            } catch {
                throw HandoffClientError.invalidResponse
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HandoffClientError {
            throw error
        } catch {
            throw HandoffClientError.network
        }
    }

    private func mapAPIError(data: Data) -> HandoffClientError {
        guard let body = try? decoder.decode(APIErrorEnvelope.self, from: data) else {
            return .invalidResponse
        }
        return switch body.error.code {
        case "HANDOFF_EXPIRED": .expired
        case "HANDOFF_REVOKED": .revoked
        case "HANDOFF_ALREADY_CLAIMED": .alreadyClaimed
        case "HANDOFF_INVALID_TOKEN": .invalidToken
        case "HANDOFF_RATE_LIMITED": .rateLimited
        default: .server(
            code: body.error.code,
            message: body.error.message,
            recoverable: body.error.recoverable
        )
        }
    }
}
