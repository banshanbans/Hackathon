@preconcurrency import AVFoundation
import SwiftUI

struct CaptureCameraScreen: View {
    @ObservedObject var flow: AppFlowModel
    @ObservedObject var session: AlignmentSessionModel

    var body: some View {
        ZStack {
            cameraBackground.ignoresSafeArea()
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Button {
                        flow.returnToSetup(session.task)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.62), in: Circle())
                    }
                    .accessibilityLabel("取消这次拍摄")
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
        case let .countdown(_, completion, _, seconds):
            VStack(spacing: 12) {
                Text("\(seconds)")
                    .font(.system(size: 104, weight: .black, design: .rounded))
                    .accessibilityLabel("倒计时 \(seconds) 秒")
                Text(completion.mode == .manual ? "手动就位 · 未经智能验证" : "保持这个画面")
                    .font(.headline)
            }
            .padding(24)
            .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 22))
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
}
