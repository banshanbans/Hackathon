@preconcurrency import AVFoundation
import Foundation
import UIKit

enum CaptureEngineError: LocalizedError, Equatable, Sendable {
    case durationOutOfRange
    case processingFailed

    var errorDescription: String? {
        switch self {
        case .durationOutOfRange: "短视频需保持 5–8 秒。"
        case .processingFailed: "候选帧处理失败，可切换为照片模式。"
        }
    }
}

struct RawCapturedFrame: Equatable, Sendable {
    let jpeg: Data
    let timestampMilliseconds: Int?
}

final class CaptureEngine: @unchecked Sendable {
    private let camera: CameraEngine

    init(camera: CameraEngine) {
        self.camera = camera
    }

    func capturePhotos() async throws -> [RawCapturedFrame] {
        let photos = try await camera.capturePhotoBurst()
        return photos.enumerated().map { index, data in
            RawCapturedFrame(jpeg: data, timestampMilliseconds: index * 180)
        }
    }

    func captureShortVideo(
        directory: URL,
        durationSeconds: Double = 6
    ) async throws -> (sourceURL: URL, frames: [RawCapturedFrame]) {
        guard (5 ... 8).contains(durationSeconds) else { throw CaptureEngineError.durationOutOfRange }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let url = directory.appending(path: "capture-\(UUID().uuidString).mov")
        try await camera.startShortVideo(to: url)
        do {
            try await Task.sleep(for: .seconds(durationSeconds))
            let result = try await camera.stopShortVideo()
            guard result.durationSeconds >= 1 else {
                try? FileManager.default.removeItem(at: url)
                throw CameraFailure.recordingFailed
            }
            let frames = try await VideoFrameExtractor.extract(
                from: url,
                durationSeconds: result.durationSeconds,
                maximumCount: 6
            )
            return (url, frames)
        } catch {
            await camera.cancelShortVideo()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<Data, Error>) -> Void

    init(completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if error != nil {
            completion(.failure(CameraFailure.recordingFailed))
        } else if let data = photo.fileDataRepresentation() {
            completion(.success(data))
        } else {
            completion(.failure(CameraFailure.recordingFailed))
        }
    }
}

final class SampleBufferMovieRecorder: @unchecked Sendable {
    private let url: URL
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastTime: CMTime?

    init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if input == nil {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
            ]
            let created = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: settings,
                sourceFormatHint: description
            )
            created.expectsMediaDataInRealTime = true
            guard writer.canAdd(created) else { return }
            writer.add(created)
            input = created
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: timestamp)
            startTime = timestamp
        }
        if input?.isReadyForMoreMediaData == true, input?.append(sampleBuffer) == true {
            lastTime = timestamp
        }
    }

    func finish(completion: @escaping @Sendable (Result<CaptureRecordingResult, Error>) -> Void) {
        guard writer.status == .writing, let startTime, let lastTime else {
            cancel()
            completion(.failure(CameraFailure.recordingFailed))
            return
        }
        input?.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self, self.writer.status == .completed else {
                completion(.failure(CameraFailure.recordingFailed))
                return
            }
            completion(.success(CaptureRecordingResult(
                url: self.url,
                durationSeconds: CMTimeGetSeconds(lastTime - startTime)
            )))
        }
    }

    func cancel() {
        input?.markAsFinished()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: url)
    }
}

private enum VideoFrameExtractor {
    static func extract(
        from url: URL,
        durationSeconds: Double,
        maximumCount: Int
    ) async throws -> [RawCapturedFrame] {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 2_048, height: 2_048)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let count = max(3, min(maximumCount, 6))
            return try (0 ..< count).map { index in
                let seconds = durationSeconds * Double(index) / Double(count - 1)
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                let image = try generator.copyCGImage(at: time, actualTime: nil)
                guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.88) else {
                    throw CaptureEngineError.processingFailed
                }
                return RawCapturedFrame(
                    jpeg: data,
                    timestampMilliseconds: Int(seconds * 1_000)
                )
            }
        }.value
    }
}
