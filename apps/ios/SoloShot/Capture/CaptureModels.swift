import Foundation

enum LocalCaptureMethod: String, Codable, CaseIterable, Equatable, Sendable {
    case photo
    case shortVideo = "short_video"
    case photoFallback = "photo_fallback"

    static func planned(_ rawValue: String?) -> LocalCaptureMethod {
        rawValue == shortVideo.rawValue ? .shortVideo : .photo
    }
}

enum LocalSelectionSource: String, Codable, Equatable, Sendable {
    case localRecommended = "local_recommended"
    case userSelected = "user_selected"
}

struct FrameQualityMetrics: Codable, Equatable, Sendable {
    let completeFraming: Double
    let targetPositionMatch: Double
    let personScaleMatch: Double
    let sharpness: Double
    let supportedPoseMatch: Double?
    let personCount: Int
    let headAndFeetVisible: Bool
    let averageConfidence: Double

    init(
        completeFraming: Double,
        targetPositionMatch: Double,
        personScaleMatch: Double,
        sharpness: Double,
        supportedPoseMatch: Double?,
        personCount: Int = 1,
        headAndFeetVisible: Bool = true,
        averageConfidence: Double = 1
    ) {
        self.completeFraming = Self.clamp(completeFraming)
        self.targetPositionMatch = Self.clamp(targetPositionMatch)
        self.personScaleMatch = Self.clamp(personScaleMatch)
        self.sharpness = Self.clamp(sharpness)
        self.supportedPoseMatch = supportedPoseMatch.map(Self.clamp)
        self.personCount = max(0, personCount)
        self.headAndFeetVisible = headAndFeetVisible
        self.averageConfidence = Self.clamp(averageConfidence)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct CaptureCandidate: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let timestampMilliseconds: Int?
    let localFilename: String
    let metrics: FrameQualityMetrics
    let localScore: Double
    let reasons: [String]

    var frameID: String { id }
}

struct CandidateInput: Equatable, Sendable {
    let frameID: String
    let timestampMilliseconds: Int?
    let localFilename: String
    let metrics: FrameQualityMetrics
}

enum FrameSelectionEngine {
    static func rank(_ inputs: [CandidateInput]) -> [CaptureCandidate] {
        inputs.map(candidate).sorted {
            if $0.localScore == $1.localScore {
                return ($0.timestampMilliseconds ?? 0) < ($1.timestampMilliseconds ?? 0)
            }
            return $0.localScore > $1.localScore
        }
    }

    static func temporallySpaced(
        _ inputs: [CandidateInput],
        maximumCount: Int = 6,
        minimumSpacingMilliseconds: Int = 400
    ) -> [CandidateInput] {
        let sorted = inputs.sorted { ($0.timestampMilliseconds ?? 0) < ($1.timestampMilliseconds ?? 0) }
        guard sorted.count > maximumCount else { return sorted }
        var selected: [CandidateInput] = []
        let anchors = [0, sorted.count / 2, sorted.count - 1]
        for index in anchors where !selected.contains(where: { $0.frameID == sorted[index].frameID }) {
            selected.append(sorted[index])
        }
        for candidate in rank(sorted).compactMap({ ranked in
            sorted.first(where: { $0.frameID == ranked.frameID })
        }) {
            guard selected.count < maximumCount else { break }
            let time = candidate.timestampMilliseconds ?? 0
            guard selected.allSatisfy({ abs(($0.timestampMilliseconds ?? 0) - time) >= minimumSpacingMilliseconds }) else {
                continue
            }
            selected.append(candidate)
        }
        return selected.sorted { ($0.timestampMilliseconds ?? 0) < ($1.timestampMilliseconds ?? 0) }
    }

    private static func candidate(_ input: CandidateInput) -> CaptureCandidate {
        let metrics = input.metrics
        var weighted = metrics.completeFraming * 0.30
            + metrics.targetPositionMatch * 0.25
            + metrics.personScaleMatch * 0.20
            + metrics.sharpness * 0.15
        var totalWeight = 0.90
        if let pose = metrics.supportedPoseMatch {
            weighted += pose * 0.10
            totalWeight += 0.10
        }
        var score = weighted / totalWeight
        if metrics.personCount != 1 { score *= 0.35 }
        if !metrics.headAndFeetVisible { score *= 0.55 }
        if metrics.averageConfidence < 0.55 { score *= 0.65 }

        var reasons: [String] = []
        if metrics.personCount > 1 {
            reasons.append("画面里出现了其他人")
        } else if metrics.personCount == 0 {
            reasons.append("人物没有稳定入镜")
        }
        if !metrics.headAndFeetVisible { reasons.append("画面边缘裁到了人物") }
        if metrics.sharpness >= 0.72 { reasons.append("这一帧更清晰") }
        if metrics.targetPositionMatch >= 0.72 { reasons.append("站位更接近 ShotPlan") }
        if metrics.personScaleMatch >= 0.72 { reasons.append("人物比例更自然") }
        if metrics.supportedPoseMatch == nil { reasons.append("动作不在本机判断范围") }
        if reasons.isEmpty { reasons.append("整体画面更稳定") }

        return CaptureCandidate(
            id: input.frameID,
            timestampMilliseconds: input.timestampMilliseconds,
            localFilename: input.localFilename,
            metrics: metrics,
            localScore: min(max(score, 0), 1),
            reasons: Array(reasons.prefix(2))
        )
    }
}

struct CaptureEvaluation: Codable, Equatable, Sendable {
    let evaluationID: String
    let captureID: String
    let issueCode: String?
    let topIssue: String?
    let nextInstruction: String?
    let needsRetake: Bool
    let goalSatisfied: Bool
    let publishReadiness: Double
    let confidence: Double
    let executionMode: String
}

enum CaptureNetworkStep: String, Codable, Equatable, Sendable {
    case consent
    case upload
    case createCapture = "create_capture"
    case evaluate
    case finished
}

struct CaptureRoundWork: Codable, Equatable, Identifiable, Sendable {
    let roundIndex: Int
    var captureMethod: LocalCaptureMethod
    let alignmentMode: AlignmentCompletionMode
    var candidates: [CaptureCandidate]
    var selectedFrameID: String?
    var selectionSource: LocalSelectionSource?
    var sourceFilename: String?
    var networkStep: CaptureNetworkStep
    var mediaAssetID: String?
    var captureID: String?
    var evaluation: CaptureEvaluation?
    let uploadAttemptID: String
    let captureIdempotencyKey: String
    let evaluationIdempotencyKey: String

    var id: Int { roundIndex }

    var selectedCandidate: CaptureCandidate? {
        guard let selectedFrameID else { return nil }
        return candidates.first { $0.id == selectedFrameID }
    }
}

struct CaptureWork: Codable, Equatable, Sendable {
    let schemaVersion: String
    let sessionID: String
    let taskCode: String
    let expiresAt: Date
    var captureConsentRecorded: Bool
    var externalAIConsentRecorded: Bool
    let consentIdempotencyKey: String
    var rounds: [CaptureRoundWork]

    static func empty(task: ImportedTask) -> CaptureWork {
        CaptureWork(
            schemaVersion: "1.0",
            sessionID: task.sessionID,
            taskCode: task.code,
            expiresAt: task.expiresAt,
            captureConsentRecorded: false,
            externalAIConsentRecorded: false,
            consentIdempotencyKey: "ios-consent-\(UUID().uuidString)",
            rounds: []
        )
    }

    var currentRound: CaptureRoundWork? { rounds.last }
}

extension ImportedTask {
    var usesFixtureEvaluation: Bool {
        mode == "original_replication" && presetThumbnailName != nil
    }
}
