import XCTest
@testable import SoloShot

final class CaptureEngineTests: XCTestCase {
    func testVideoFrameSamplingAvoidsExactAssetBoundaries() throws {
        let times = VideoFrameSampling.times(durationSeconds: 6, maximumCount: 6)

        XCTAssertEqual(times.count, 6)
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThan(try XCTUnwrap(times.first), 0)
        XCTAssertLessThan(try XCTUnwrap(times.last), 6)
        XCTAssertEqual(times[2], 2.5, accuracy: 0.001)
        XCTAssertEqual(times[3], 3.5, accuracy: 0.001)
    }

    func testVideoFrameSamplingClampsCandidateCount() {
        XCTAssertEqual(VideoFrameSampling.times(durationSeconds: 6, maximumCount: 1).count, 3)
        XCTAssertEqual(VideoFrameSampling.times(durationSeconds: 6, maximumCount: 20).count, 6)
        XCTAssertTrue(VideoFrameSampling.times(durationSeconds: 0, maximumCount: 6).isEmpty)
    }
}
