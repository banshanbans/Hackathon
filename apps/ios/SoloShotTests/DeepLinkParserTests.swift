import XCTest
@testable import SoloShot

final class DeepLinkParserTests: XCTestCase {
    func testAcceptsStrictHandoffURLAndNormalizesCase() throws {
        XCTAssertEqual(
            try DeepLinkParser.parse(XCTUnwrap(URL(string: "SOLOSHOT://HANDOFF/abc234"))),
            "ABC234"
        )
    }

    func testRejectsUnexpectedURLShapesAndAmbiguousCodes() throws {
        let invalid = [
            "https://handoff/ABC234",
            "soloshot://other/ABC234",
            "soloshot://handoff/ABC234/extra",
            "soloshot://handoff/ABC234?token=secret",
            "soloshot://handoff/ABC230",
            "soloshot://handoff/ABC23I",
        ]
        for value in invalid {
            XCTAssertThrowsError(try DeepLinkParser.parse(XCTUnwrap(URL(string: value))), value)
        }
    }
}
