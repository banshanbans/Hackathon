@preconcurrency import AVFoundation
import SwiftUI

struct AlignmentCameraScreen: View {
    @ObservedObject var flow: AppFlowModel
    @ObservedObject var session: AlignmentSessionModel
    @AppStorage("soloshot.w4.voice-enabled") private var voiceEnabled = true
    @AppStorage("soloshot.w4.haptics-enabled") private var hapticsEnabled = true
    @State private var debugEnabled = false
    @State private var showManualConfirmation = false

    var body: some View {
        ZStack {
            cameraBackground
                .ignoresSafeArea()
            AlignmentOverlayView(
                target: session.target,
                person: session.decision?.selectedPerson,
                imageSize: session.imageSize,
                ready: session.decision?.alignment.readyToCapture == true,
                debugEnabled: debugEnabled
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                topBar
                if session.isInterrupted {
                    interruptionBanner
                } else if let failure = session.failure {
                    failureBanner(failure)
                } else if session.pressure == .critical {
                    pressureBanner
                }
                Spacer()
                if debugEnabled { debugPanel }
                actionPanel
                instructionPanel
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .preferredColorScheme(.dark)
        .onChange(of: voiceEnabled) { _, _ in updateFeedback() }
        .onChange(of: hapticsEnabled) { _, _ in updateFeedback() }
        .alert("这次改用手动确认？", isPresented: $showManualConfirmation) {
            Button("取消", role: .cancel) {}
            Button("继续使用手动确认") { session.confirmManualReady() }
        } message: {
            Text("SoloShot 尚未验证构图与动作，结果会标记为手动完成。")
        }
    }

    @ViewBuilder
    private var cameraBackground: some View {
        if session.isFixture {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.16, green: 0.12, blue: 0.08), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Image(systemName: "person.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.white.opacity(0.12))
            }
        } else if let cameraSession = session.cameraSession {
            CameraPreviewView(session: cameraSession)
        } else {
            Color.black
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                flow.exitAlignment(toSummary: session.task)
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel("退出现场陪拍")

            Label(session.isFixture ? "演示陪拍" : "本地实时陪拍", systemImage: "circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(session.isFixture ? .orange : .green)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(.black.opacity(0.55), in: Capsule())
            Spacer()
#if DEBUG
            Button {
                debugEnabled.toggle()
            } label: {
                Image(systemName: debugEnabled ? "ladybug.fill" : "ladybug")
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel(debugEnabled ? "关闭 Debug Overlay" : "打开 Debug Overlay")
#endif
        }
    }

    private var instructionPanel: some View {
        let instruction = session.decision?.alignment.instructionCode
        let overlap = session.decision?.overlapRatio ?? 0
        let basePresentation = instruction.map(CoachPresentation.from)
            ?? CoachPresentation(text: "正在寻找人物", symbol: "viewfinder")
        let presentation = instruction == .holdStill
            && overlap >= AlignmentConfiguration.production.overlapEnterThreshold
            ? CoachPresentation(text: "已进入轮廓，请保持", symbol: "checkmark.circle")
            : basePresentation
        let overlapPercent = Int((overlap * 100).rounded())
        let targetPercent = Int((AlignmentConfiguration.production.overlapEnterThreshold * 100).rounded())
        return VStack(spacing: 10) {
            Label(presentation.text, systemImage: presentation.symbol)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 18)
                .frame(minHeight: 52)
                .background(.black.opacity(0.72), in: Capsule())
                .accessibilityLabel("当前指令：\(presentation.text)")
            HStack {
                Text("轮廓匹配度 \(overlapPercent)%")
                Spacer()
                Text("目标 \(targetPercent)%")
            }
            .font(.caption.weight(.semibold))
            ProgressView(value: overlap)
                .tint(.green)
                .accessibilityLabel("轮廓匹配度")
                .accessibilityValue("\(overlapPercent)%，目标 \(targetPercent)%")
        }
        .padding(12)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 15))
    }

    private var actionPanel: some View {
        Label(
            session.task.actions.first?.instruction ?? "保持自然动作并看向镜头。",
            systemImage: "figure.stand"
        )
        .font(.subheadline.weight(.semibold))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityLabel("拍摄动作：\(session.task.actions.first?.instruction ?? "保持自然动作并看向镜头。")")
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            referenceThumbnail
            Spacer()
            Button {
                voiceEnabled.toggle()
            } label: {
                Image(systemName: voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .accessibilityLabel(voiceEnabled ? "关闭语音提示" : "开启语音提示")
            if session.manualOverrideAvailable {
                Button("我已就位") { showManualConfirmation = true }
                    .font(.caption.weight(.bold))
                    .frame(minHeight: 48)
                    .padding(.horizontal, 12)
                    .background(.orange, in: Capsule())
                    .accessibilityHint("需要再次确认，本次会标记为手动完成")
            }
        }
    }

    @ViewBuilder
    private var referenceThumbnail: some View {
        if let name = session.task.presetThumbnailName,
           let url = Bundle.main.url(forResource: name, withExtension: "webp"),
           let image = UIImage(contentsOfFile: url.path)
        {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.7)))
                .accessibilityLabel("参考图缩略图")
        } else {
            Image(systemName: "photo")
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("参考图不可用")
        }
    }

    private var interruptionBanner: some View {
        VStack(spacing: 8) {
            Label("相机暂时停下了", systemImage: "pause.circle.fill")
            if session.interruptionEnded {
                Button("继续陪拍") { Task { await session.resumeAfterInterruption() } }
                    .frame(minHeight: 44)
            } else {
                Text("正在等待相机恢复…").font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
    }

    private func failureBanner(_ failure: CameraFailure) -> some View {
        VStack(spacing: 8) {
            Label(failure.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            Button("返回准备") { flow.returnToSetup(session.task) }
                .frame(minHeight: 44)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pressureBanner: some View {
        Label("手机有点热，实时识别已暂停。可稍后继续或手动确认。", systemImage: "thermometer.high")
            .font(.caption.weight(.semibold))
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
    }

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Debug Overlay · 不保存画面").fontWeight(.bold)
            Text("Vision \(session.visionLatencyMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms")
            Text("FPS \(session.observedFramesPerSecond.formatted(.number.precision(.fractionLength(1))))")
            Text("Instruction \(session.decision?.alignment.instructionCode.rawValue ?? "waiting")")
            Text("Confidence \((session.decision?.selectedPerson?.confidence ?? 0).formatted(.percent.precision(.fractionLength(0))))")
            Text("IoU \((session.decision?.overlapRatio ?? 0).formatted(.percent.precision(.fractionLength(1))))")
        }
        .font(.caption.monospaced())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Debug 性能信息")
    }

    private func updateFeedback() {
        session.updateFeedback(voiceEnabled: voiceEnabled, hapticsEnabled: hapticsEnabled)
    }
}
