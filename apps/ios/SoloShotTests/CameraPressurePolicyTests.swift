import Foundation
import XCTest
@testable import SoloShot

final class CameraPressurePolicyTests: XCTestCase {
    func testMostSevereDeviceOrThermalPressureWins() {
        XCTAssertEqual(
            CameraPressurePolicy.effective(device: .nominal, thermal: .nominal),
            .nominal
        )
        XCTAssertEqual(
            CameraPressurePolicy.effective(device: .degraded, thermal: .nominal),
            .degraded
        )
        XCTAssertEqual(
            CameraPressurePolicy.effective(device: .nominal, thermal: .critical),
            .critical
        )
        XCTAssertEqual(
            CameraPressurePolicy.effective(device: .critical, thermal: .degraded),
            .critical
        )
    }

    func testSystemThermalStatesMapToExpectedVisionRate() {
        XCTAssertEqual(CameraPressurePolicy.thermalLevel(.nominal), .nominal)
        XCTAssertEqual(CameraPressurePolicy.thermalLevel(.fair), .nominal)
        XCTAssertEqual(CameraPressurePolicy.thermalLevel(.serious), .degraded)
        XCTAssertEqual(CameraPressurePolicy.thermalLevel(.critical), .critical)
    }
}
