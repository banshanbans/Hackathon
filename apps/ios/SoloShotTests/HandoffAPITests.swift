import Foundation
import XCTest
@testable import SoloShot

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: HandoffClientError.invalidResponse)
            return
        }
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

final class HandoffAPITests: XCTestCase {
    private func api() -> HandoffAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return HandoffAPI(
            baseURL: URL(string: "https://api.example.test")!,
            session: URLSession(configuration: configuration)
        )
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testPreviewDecodesOnlySafePublicTask() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/handoffs/294816")
            let data = Data("""
            {"data":{"schema_version":"1.0","handoff_id":"handoff_test","code":"294816","status":"created","mode":"original_replication","created_at":"2026-07-18T00:00:00Z","expires_at":"2026-07-18T00:10:00Z","claimed_at":null,"completed_at":null}}
            """.utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let preview = try await api().preview(code: "294816")
        XCTAssertEqual(preview.code, "294816")
        XCTAssertEqual(preview.status, .created)
    }

    func testClaimSendsContractHeadersAndMapsStableError() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Handoff-Claim-Token"))
            let data = Data("""
            {"error":{"code":"HANDOFF_EXPIRED","message":"expired","recoverable":true}}
            """.utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        do {
            _ = try await api().claim(code: "294816", clientInstanceID: "ios-test")
            XCTFail("Expected expiry")
        } catch let error as HandoffClientError {
            XCTAssertEqual(error, .expired)
        }
    }

    func testListsOnlySafeAvailableHandoffContract() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/handoffs")
            XCTAssertEqual(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "limit" })?.value,
                "20"
            )
            let data = Data("""
            {"data":{"schema_version":"1.0","items":[{"schema_version":"1.0","handoff_id":"handoff_available","code":"731204","status":"created","mode":"scene_adaptation","created_at":"2026-07-22T08:00:00Z","expires_at":"2026-07-22T08:10:00Z","claimed_at":null,"completed_at":null}]}}
            """.utf8)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let result = try await api().listAvailable()
        XCTAssertEqual(result.items.map(\.code), ["731204"])
        XCTAssertEqual(result.items.first?.status, .created)
    }
}
