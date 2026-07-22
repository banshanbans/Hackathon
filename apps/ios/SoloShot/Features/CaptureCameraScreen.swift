@preconcurrency import AVFoundation
import SwiftUI

struct CaptureCameraScreen: View {
    @ObservedObject var flow: AppFlowModel
    @ObservedObject var session: AlignmentSessionModel

    var body: some View {
        ZStack {
            cameraBackground.ignoresSafeArea()
            Color.black.opacity(0.28).ignoresSafeArea()
            if case .countdown = flow.state {
                AlignmentOverlayView(
                    target: session.target,
                    person: session.decision?.selectedPerson,
                    referenceContour: session.referenceContour,
                    liveContour: session.liveSilhouette?.contour,
                    imageSize: session.imageSize,
                    ready: true,
                    debugEnabled: false
                )
                .ignoresSafeArea()
            }
            VStack(spacing: 18) {
                HStack {
                    Button {
                        flow.showHome()
                    } label: {
                        Image(systemName: "house.fill")
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.62), in: Circle())
                    }
                    .accessibilityLabel("返回首页")
                    Spacer()
                    Label(session.isFixture ? "演示拍摄" : "本地拍摄", systemImage: "circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(session.isFixture ? .orange : .green)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(.black.opacity(0.62), in: Capsule())
                }
                Spacer()
                captureStatus
                Text("只记录画面，不录制声音")
                    .font(.caption)
                    .padding(10)
                    .background(.black.opacity(0.62), in: Capsule())
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var captureStatus: some View {
        switch flow.state {
        case let .countdown(_, completion, method, seconds):
            VStack(spacing: 12) {
                Text(seconds == 3 ? "已就位，3 秒后\(captureVerb(method))" : "保持这个画面")
                    .font(.headline)
                Text("\(seconds)")
                    .font(.system(size: 104, weight: .black, design: .rounded))
                    .accessibilityLabel("倒计时 \(seconds) 秒")
                Label(captureMethodLabel(method), systemImage: method == .shortVideo ? "video.fill" : "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("capture-method")
                Text(session.task.actions.first?.instruction ?? "保持自然动作并看向镜头。")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("拍摄动作：\(session.task.actions.first?.instruction ?? "保持自然动作并看向镜头。")")
                if completion.mode == .manual {
                    Text("手动就位 · 未经智能验证")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                } else {
                    Text(session.decision?.silhouetteMatch.map {
                        "轮廓接近度 \(Int(($0.score * 100).rounded()))% · 软评分"
                    } ?? "构图与动作已就位")
                        .font(.caption.monospacedDigit())
                }
            }
            .padding(24)
            .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 22))
            .accessibilityIdentifier("auto-countdown")
        case let .recording(_, method, _):
            VStack(spacing: 14) {
                ProgressView().tint(.white)
                Label(
                    method == .shortVideo ? "正在记录这段旅行瞬间" : "正在捕捉这一刻",
                    systemImage: method == .shortVideo ? "video.fill" : "camera.fill"
                )
                .font(.headline)
                Text("完成后，SoloShot 会在本机选出候选")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 20))
            .accessibilityIdentifier("capture-recording")
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var cameraBackground: some View {
        if session.isFixture {
            LinearGradient(colors: [.orange.opacity(0.28), .black], startPoint: .top, endPoint: .bottom)
        } else if let cameraSession = session.cameraSession {
            CameraPreviewView(session: cameraSession)
        } else {
            Color.black
        }
    }

    private func captureVerb(_ method: LocalCaptureMethod) -> String {
        method == .shortVideo ? "开始录制" : "开始连拍"
    }

    private func captureMethodLabel(_ method: LocalCaptureMethod) -> String {
        switch method {
        case .photo: "三张照片连拍"
        case .shortVideo: "6 秒无声短视频"
        case .photoFallback: "照片降级 · 三张连拍"
        }
    }
}
