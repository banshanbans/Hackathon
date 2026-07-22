import CoreVideo
import UIKit
import XCTest
@testable import SoloShot

final class SilhouetteTests: XCTestCase {
    func testDiceIsOneForIdenticalContoursAndZeroForDisjointContours() throws {
        let reference = SilhouetteContour.fixturePerson.transformed(
            into: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.7)
        )
        let disjoint = SilhouetteContour.fixturePerson.transformed(
            into: NormalizedRect(x: 0.65, y: 0.1, width: 0.3, height: 0.7)
        )
        XCTAssertEqual(
            try XCTUnwrap(SilhouetteMatcher.dice(reference: reference, live: reference)),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(SilhouetteMatcher.dice(reference: reference, live: disjoint)),
            0,
            accuracy: 0.000_001
        )
    }

    func testTightNormalizationThenTargetTransformUsesTargetBounds() throws {
        let source = SilhouetteContour.fixturePerson.transformed(
            into: NormalizedRect(x: 0.2, y: 0.1, width: 0.4, height: 0.8)
        )
        let target = NormalizedRect(x: 0.45, y: 0.25, width: 0.25, height: 0.55)
        let mapped = try XCTUnwrap(source.normalizedToTightBounds()).transformed(into: target)
        let bounds = try XCTUnwrap(mapped.bounds)
        XCTAssertEqual(bounds.x, target.x, accuracy: 0.000_001)
        XCTAssertEqual(bounds.y, target.y, accuracy: 0.000_001)
        XCTAssertEqual(bounds.width, target.width, accuracy: 0.000_001)
        XCTAssertEqual(bounds.height, target.height, accuracy: 0.000_001)
    }

    func testSmoothingKeepsAClosedNormalizedContour() throws {
        let previous = SilhouetteContour.fixturePerson
        let current = previous.transformed(
            into: NormalizedRect(x: 0.05, y: 0.02, width: 0.90, height: 0.96)
        )
        let smoothed = current.smoothed(with: previous)
        XCTAssertEqual(smoothed.loops.first?.count, 96)
        XCTAssertTrue(smoothed.loops.flatMap { $0 }.allSatisfy {
            (0 ... 1).contains($0.x) && (0 ... 1).contains($0.y)
        })
    }

    func testMaskContourExtractionReturnsTightUsableShape() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault,
            96,
            160,
            kCVPixelFormatType_OneComponent8,
            nil,
            &buffer
        ), kCVReturnSuccess)
        let mask = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(mask, [])
        defer { CVPixelBufferUnlockBaseAddress(mask, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(mask))
        memset(base, 0, CVPixelBufferGetDataSize(mask))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        for y in 20 ..< 145 {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 30 ..< 66 { row[x] = 255 }
        }
        let contour = try MaskContourExtractor.contour(from: mask)
        XCTAssertTrue(contour.isUsable)
        let bounds = try XCTUnwrap(contour.bounds)
        XCTAssertGreaterThan(bounds.height, 0.70)
        XCTAssertGreaterThan(bounds.width, 0.25)
    }

    func testCorruptReferenceFailsWithoutThrowingOrPersistingPixels() {
        let asset = ReferenceSilhouetteExtractor().extract(
            data: Data("not-an-image".utf8),
            selectedBox: NormalizedRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        )
        XCTAssertEqual(asset.status, .extractionFailed)
        XCTAssertNil(asset.contour)
        XCTAssertFalse(asset.sourceSHA256.isEmpty)
    }

    func testReferenceImageNormalizerBakesRightRotationIntoPixels() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 24))
        let source = renderer.image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 24))
        }
        let rotated = UIImage(
            cgImage: try XCTUnwrap(source.cgImage),
            scale: 1,
            orientation: .right
        )
        let data = try XCTUnwrap(rotated.jpegData(compressionQuality: 0.9))
        let normalized = try XCTUnwrap(ReferenceSilhouetteExtractor().normalizedCGImage(data))
        XCTAssertEqual(normalized.width, normalized.height * 2)
    }

    func testReferenceSelectionCoversNoPersonMultiplePartialAndFullBody() {
        XCTAssertEqual(ReferenceSilhouetteSelector.poseStatus([]), .noPerson)
        XCTAssertEqual(
            ReferenceSilhouetteSelector.poseStatus([
                ReferencePoseCandidate(fullBodyVisible: true),
                ReferencePoseCandidate(fullBodyVisible: true),
            ]),
            .multiplePeople
        )
        XCTAssertEqual(
            ReferenceSilhouetteSelector.poseStatus([ReferencePoseCandidate(fullBodyVisible: false)]),
            .partialPerson
        )
        XCTAssertEqual(
            ReferenceSilhouetteSelector.poseStatus([ReferencePoseCandidate(fullBodyVisible: true)]),
            .ready
        )
    }

    func testReferenceInstanceLabelSelectionRejectsAmbiguity() {
        XCTAssertEqual(
            ReferenceSilhouetteSelector.selectLabel(from: [:]),
            .unavailable(.noPerson)
        )
        XCTAssertEqual(
            ReferenceSilhouetteSelector.selectLabel(from: [1: 100, 2: 40]),
            .unavailable(.multiplePeople)
        )
        XCTAssertEqual(
            ReferenceSilhouetteSelector.selectLabel(from: [1: 100, 2: 20]),
            .selected(1)
        )
    }
}
