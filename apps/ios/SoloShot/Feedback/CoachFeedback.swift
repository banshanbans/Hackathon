import AVFoundation
import Foundation
import SoloShotContracts
import SwiftUI
import UIKit

struct CoachPresentation: Equatable, Sendable {
    let text: String
    let symbol: String

    static func from(_ instruction: CurrentAlignment.InstructionCode) -> CoachPresentation {
        switch instruction {
        case .noPerson: CoachPresentation(text: "请进入画面", symbol: "person.crop.circle.badge.questionmark")
        case .multiplePeople: CoachPresentation(text: "只保留一人", symbol: "person.2.slash")
        case .moveLeft: CoachPresentation(text: "向左移动", symbol: "arrow.left")
        case .moveRight: CoachPresentation(text: "向右移动", symbol: "arrow.right")
        case .moveForward: CoachPresentation(text: "向前靠近", symbol: "arrow.up")
        case .moveBackward: CoachPresentation(text: "向后退一点", symbol: "arrow.down")
        case .feetOutside: CoachPresentation(text: "让双脚入镜", symbol: "figure.stand")
        case .headOutside: CoachPresentation(text: "让头部入镜", symbol: "person.crop.circle")
        case .adjustBodyDirection: CoachPresentation(text: "调整身体方向", symbol: "arrow.triangle.2.circlepath")
        case .adjustArm: CoachPresentation(text: "调整手臂动作", symbol: "figure.arms.open")
        case .holdStill: CoachPresentation(text: "保持不动", symbol: "pause.circle")
        case .readyToCapture: CoachPresentation(text: "构图已就位", symbol: "checkmark.circle.fill")
        }
    }
}

struct FeedbackGate: Sendable {
    private(set) var lastInstruction: CurrentAlignment.InstructionCode?
    private(set) var lastEmissionAt: Date?
    let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = AlignmentConfiguration.production.speechMinimumInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldEmit(
        instruction: CurrentAlignment.InstructionCode,
        confirmed: Bool,
        at now: Date
    ) -> Bool {
        guard confirmed else { return false }
        if lastInstruction == instruction,
           let lastEmissionAt,
           now.timeIntervalSince(lastEmissionAt) < minimumInterval
        {
            return false
        }
        if let lastEmissionAt, now.timeIntervalSince(lastEmissionAt) < minimumInterval {
            return false
        }
        lastInstruction = instruction
        lastEmissionAt = now
        return true
    }
}

@MainActor
final class CoachFeedbackController {
    private let speech = AVSpeechSynthesizer()
    private var gate = FeedbackGate()

    func handle(
        decision: AlignmentDecision,
        voiceEnabled: Bool,
        hapticsEnabled: Bool,
        at now: Date = Date()
    ) {
        let instruction = decision.alignment.instructionCode
        guard gate.shouldEmit(
            instruction: instruction,
            confirmed: decision.instructionConfirmed,
            at: now
        ) else { return }
        let presentation = CoachPresentation.from(instruction)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: presentation.text)
        } else if voiceEnabled {
            let utterance = AVSpeechUtterance(string: presentation.text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = 0.48
            speech.stopSpeaking(at: .word)
            speech.speak(utterance)
        }
        if hapticsEnabled {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(instruction == .readyToCapture ? .success : .warning)
        }
    }

    func stop() {
        speech.stopSpeaking(at: .immediate)
    }
}

