import Foundation
import SoloShotContracts
import XCTest
@testable import SoloShot

private final class CaptureMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        throw NSError(domain: "CaptureAPITests", code: 1)
    }

    stream.open()
    defer { stream.close() }
    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            throw stream.streamError ?? NSError(domain: "CaptureAPITests", code: 2)
        }
        if count == 0 { break }
        body.append(buffer, count: count)
    }
    return body
}

final class CaptureAPITests: XCTestCase {
    override func tearDown() {
        CaptureMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testConsentKeepsClaimTokenInHeaderAndSendsExplicitBooleans() async throws {
        CaptureMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/ss_ios/capture-consent")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Handoff-Claim-Token"), "secret-claim")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "stable-consent")
            let body = try requestBodyData(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["capture_upload_consent"] as? Bool, true)
            XCTAssertEqual(object["external_ai_consent"] as? Bool, true)
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("secret-claim"))
            let response = Data("""
            {"data":{"schema_version":"1.0","session_id":"ss_ios","capture_upload_consent_at":"2026-07-19T00:00:00Z","external_ai_consent_at":"2026-07-19T00:00:00Z"}}
            """.utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                response
            )
        }

        let receipt = try await api().recordConsent(
            sessionID: "ss_ios",
            externalAIConsent: true,
            claimToken: "secret-claim",
            idempotencyKey: "stable-consent"
        )
        XCTAssertEqual(receipt.sessionId, "ss_ios")
    }

    func testProviderUnavailableUsesStableRecoverableMapping() async throws {
        CaptureMockURLProtocol.handler = { request in
            let response = Data("""
            {"error":{"code":"PROVIDER_UNAVAILABLE","message":"Ark unavailable","recoverable":true}}
            """.utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                response
            )
        }
        do {
            _ = try await api().evaluate(
                sessionID: "ss_ios",
                captureID: "cap_ios",
                claimToken: "secret-claim",
                idempotencyKey: "stable-evaluation"
            )
            XCTFail("Expected provider failure")
        } catch let error as CaptureClientError {
            XCTAssertEqual(error, .providerUnavailable)
        }
    }

    private func api() -> CaptureAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureMockURLProtocol.self]
        return CaptureAPI(
            baseURL: URL(string: "https://api.example.test")!,
            session: URLSession(configuration: configuration)
        )
    }
}
