import Foundation
import SoloShotContracts
import Testing

@Suite("Canonical session fixture")
struct SessionFixtureTests {
    @Test("Generated Swift models decode the shared fixture")
    func decodesCanonicalSession() throws {
        let fixtureURL = repositoryRoot()
            .appendingPathComponent("packages/contracts/fixtures/session.v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let session = try decoder.decode(SoloShotSession.self, from: data)

        #expect(session.schemaVersion.rawValue == "1.0")
        #expect(session.sessionId == "ss_w0_fixture")
        #expect(session.state == .shotPlanReady)
        #expect(session.shotPlan?.targetLayout.centerX == 0.72)
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 {
            url.deleteLastPathComponent()
        }
        return url
    }
}
