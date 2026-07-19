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
                instructionPanel
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .preferredColorScheme(.dark)
        .onChange(of: voiceEnabled) { _, _ in updateFeedback() }
        .onChange(of: hapticsEnabled) { _, _ in updateFeedback() }
        .alert("手动确认已就位？", isPresented: $showManualConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认未验证就位") { session.confirmManualReady() }
        } message: {
            Text("系统没有验证人物姿势或构图。该结果会明确标记为手动降级。")
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
            .accessibilityLabel("退出实时对齐")

            Label(session.isFixture ? "Fixture 本地对齐" : "本地实时对齐", systemImage: "circle.fill")
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
        let presentation = instruction.map(CoachPresentation.from)
            ?? CoachPresentation(text: "正在寻找人物", symbol: "viewfinder")
        return VStack(spacing: 10) {
            Label(presentation.text, systemImage: presentation.symbol)
                .font(.title3.weight(.bold))
                .padding(.horizontal, 18)
                .frame(minHeight: 52)
                .background(.black.opacity(0.72), in: Capsule())
                .accessibilityLabel("当前指令：\(presentation.text)")
            ProgressView(value: session.decision?.alignment.stabilityScore ?? 0)
                .tint(.green)
                .accessibilityLabel("对齐稳定度")
                .accessibilityValue("\(Int((session.decision?.alignment.stabilityScore ?? 0) * 100))%")
        }
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
                Button("手动已就位") { showManualConfirmation = true }
                    .font(.caption.weight(.bold))
                    .frame(minHeight: 48)
                    .padding(.horizontal, 12)
                    .background(.orange, in: Capsule())
                    .accessibilityHint("需要再次确认，结果不会标记为 Vision 验证")
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
            Label("相机被系统中断", systemImage: "pause.circle.fill")
            if session.interruptionEnded {
                Button("继续相机") { Task { await session.resumeAfterInterruption() } }
                    .frame(minHeight: 44)
            } else {
                Text("等待系统释放相机…").font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
    }

    private func failureBanner(_ failure: CameraFailure) -> some View {
        VStack(spacing: 8) {
            Label(failure.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            Button("返回准备页") { flow.returnToSetup(session.task) }
                .frame(minHeight: 44)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.red.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
    }

    private var pressureBanner: some View {
        Label("设备压力过高，Vision 已暂停；可退出降温或手动确认。", systemImage: "thermometer.high")
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
