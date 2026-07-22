import AVFoundation
import Foundation
import UIKit

enum CaptureCue: Equatable, Sendable {
    case autoReady
    case countdown(Int)
    case alignmentLost
    case start
    case hold
    case completed

    var text: String {
        switch self {
        case .autoReady: "已就位"
        case let .countdown(value): String(value)
        case .alignmentLost: "请重新进入轮廓"
        case .start: "开始"
        case .hold: "保持"
        case .completed: "完成"
        }
    }
}

@MainActor
final class CaptureCueFeedbackController {
    private let speech = AVSpeechSynthesizer()

    func emit(_ cue: CaptureCue) {
        let defaults = UserDefaults.standard
        let voiceKey = "soloshot.w4.voice-enabled"
        let hapticsKey = "soloshot.w4.haptics-enabled"
        let voiceEnabled = defaults.object(forKey: voiceKey) == nil || defaults.bool(forKey: voiceKey)
        let hapticsEnabled = defaults.object(forKey: hapticsKey) == nil || defaults.bool(forKey: hapticsKey)
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: cue.text)
        } else if voiceEnabled {
            let utterance = AVSpeechUtterance(string: cue.text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            utterance.rate = 0.48
            speech.stopSpeaking(at: .word)
            speech.speak(utterance)
        }
        if hapticsEnabled {
            switch cue {
            case .autoReady:
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.success)
            case .alignmentLost:
                let generator = UINotificationFeedbackGenerator()
                generator.prepare()
                generator.notificationOccurred(.warning)
            default:
                let generator = UIImpactFeedbackGenerator(style: cue == .completed ? .heavy : .medium)
                generator.prepare()
                generator.impactOccurred()
            }
        }
    }

    func stop() {
        speech.stopSpeaking(at: .immediate)
    }
}
