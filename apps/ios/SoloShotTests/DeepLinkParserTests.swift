import XCTest
@testable import SoloShot

final class DeepLinkParserTests: XCTestCase {
    func testAcceptsStrictNumericHandoffURL() throws {
        XCTAssertEqual(
            try DeepLinkParser.parse(XCTUnwrap(URL(string: "SOLOSHOT://HANDOFF/294816"))),
            "294816"
        )
    }

    func testRejectsUnexpectedURLShapesAndAmbiguousCodes() throws {
        let invalid = [
            "https://handoff/294816",
            "soloshot://other/294816",
            "soloshot://handoff/294816/extra",
            "soloshot://handoff/294816?token=secret",
            "soloshot://handoff/29481",
            "soloshot://handoff/29481A",
        ]
        for value in invalid {
            XCTAssertThrowsError(try DeepLinkParser.parse(XCTUnwrap(URL(string: value))), value)
        }
    }
}
