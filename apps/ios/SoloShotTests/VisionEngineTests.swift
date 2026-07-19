import CoreGraphics
import Foundation
@preconcurrency import Vision
import XCTest
@testable import SoloShot

final class VisionEngineTests: XCTestCase {
    func testJointConversionFiltersConfidenceAndReturnsTopLeftDomainData() throws {
        let observedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let person = try XCTUnwrap(VisionEngine().map([
            VisionJointSample(
                joint: .nose,
                visionPoint: NormalizedPoint(x: 0.4, y: 0.8),
                confidence: 0.9
            ),
            VisionJointSample(
                joint: .leftAnkle,
                visionPoint: NormalizedPoint(x: 0.35, y: 0.1),
                confidence: 0.1
            ),
        ], observedAt: observedAt))

        let nose = try XCTUnwrap(person.joints[.nose])
        XCTAssertEqual(nose.point.x, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(nose.point.y, 0.2, accuracy: 0.000_001)
        XCTAssertNil(person.joints[.leftAnkle])
        XCTAssertEqual(person.observedAt, observedAt)
        XCTAssertTrue((0 ... 1).contains(person.boundingBox.x))
        XCTAssertTrue((0 ... 1).contains(person.boundingBox.y))
    }

    func testControlledPersonFixtureProducesOnlyNormalizedDomainObservations() throws {
        let url = repositoryRoot()
            .appending(path: "packages/evals/test-image-v1/assets/references/doorway_coffee_fullbody.jpg")
        let provider = try XCTUnwrap(CGDataProvider(url: url as CFURL))
        let image = try XCTUnwrap(CGImage(
            jpegDataProviderSource: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))
        let results: [PersonObservation]
        do {
            results = try VisionEngine().observations(
                cgImage: image,
                observedAt: Date(timeIntervalSince1970: 1_750_000_000)
            )
        } catch {
            try skipWhenSimulatorVisionModelIsUnavailable(error)
            throw error
        }
        let person = try XCTUnwrap(results.first)
        XCTAssertFalse(person.joints.isEmpty)
        XCTAssertTrue(person.joints.values.allSatisfy {
            (0 ... 1).contains($0.point.x) && (0 ... 1).contains($0.point.y)
        })
    }

    func testPlainImageProducesNoBodyObservation() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 128,
            height: 128,
            bitsPerComponent: 8,
            bytesPerRow: 128 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let image = try XCTUnwrap(context.makeImage())
        do {
            let observations = try VisionEngine().observations(cgImage: image, observedAt: Date())
            XCTAssertTrue(observations.isEmpty)
        } catch {
            try skipWhenSimulatorVisionModelIsUnavailable(error)
            throw error
        }
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func skipWhenSimulatorVisionModelIsUnavailable(_ error: Error) throws {
        let error = error as NSError
        if error.domain == VNErrorDomain, error.code == 9 {
            throw XCTSkip("当前 Simulator runtime 缺少 Vision 人体姿态模型权重；纯转换测试仍必须通过。")
        }
    }
}
