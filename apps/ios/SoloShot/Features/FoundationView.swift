import SwiftUI
import UIKit

struct FoundationView: View {
    @ObservedObject var flow: AppFlowModel
    @AppStorage("soloshot.w4.voice-enabled") private var voiceEnabled = true
    @AppStorage("soloshot.w4.haptics-enabled") private var hapticsEnabled = true
    @State private var phoneSecured = false
    @State private var externalAIConsent = false

    var body: some View {
        Group {
            if case .aligning = flow.state, let session = flow.alignmentSession {
                AlignmentCameraScreen(flow: flow, session: session)
            } else if isCaptureCameraState, let session = flow.alignmentSession {
                CaptureCameraScreen(flow: flow, session: session)
            } else {
                standardShell
            }
        }
        .preferredColorScheme(.dark)
    }

    private var standardShell: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.08, blue: 0.13), Color(red: 0.08, green: 0.15, blue: 0.21)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    brand
                    content
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var brand: some View {
        HStack {
            Image(systemName: "camera.aperture")
                .foregroundStyle(.orange)
            Text("SoloShot AI")
                .font(.headline.weight(.bold))
            Spacer()
            Text("现场陪拍")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.state {
        case .launch:
            statusView(title: "正在找回你的 ShotPlan", detail: "上一次的任务已保存在本机")
        case .taskImport:
            importView
        case .importing:
            statusView(title: "正在把 ShotPlan 带到 iPhone", detail: "完成后即可离线查看")
            Button("取消") { flow.cancelImport() }
                .buttonStyle(SecondaryButtonStyle())
        case let .referenceSummary(task):
            summaryView(task)
        case let .setup(task):
            setupView(task)
        case let .cameraPreparing(task):
            statusView(title: "正在为现场陪拍做准备", detail: "画面只在本机实时处理")
            Button("取消") { flow.returnToSetup(task) }
                .buttonStyle(SecondaryButtonStyle())
        case .aligning:
            statusView(title: "正在打开你的 AI 摄影机位", detail: "准备完成后，跟随屏幕走进轮廓")
        case let .ready(task, completion):
            readyView(task, completion: completion)
        case let .actionBrief(task, completion, method):
            actionBriefView(task, completion: completion, method: method)
        case .countdown, .recording:
            statusView(title: "准备记录这一拍", detail: "保持当前构图")
        case let .processingFrames(_, roundIndex):
            statusView(title: "正在替你挑选最好的瞬间", detail: "第 \(roundIndex) 次拍摄 · 原视频只留在本机")
        case let .selectingFrame(task, work):
            selectionView(task, work: work)
        case let .consent(task, work):
            consentView(task, work: work)
        case let .uploadPending(task, work):
            uploadPendingView(task, work: work)
        case .uploading:
            statusView(title: "正在提交你选中的照片", detail: "其他候选不会上传")
        case .comparing:
            statusView(title: "AI 摄影导演正在复盘这一拍", detail: "只给你一条最值得调整的建议")
        case let .coaching(task, work):
            coachingView(task, work: work)
        case let .finalResult(task, work):
            finalResultView(task, work: work)
        case let .offlinePending(task, work, message):
            offlinePendingView(task, work: work, message: message)
        case let .captureError(task, message, canUsePhotoFallback):
            captureErrorView(task, message: message, canUsePhotoFallback: canUsePhotoFallback)
        case let .cameraError(task, failure):
            cameraErrorView(task, failure: failure)
        case let .recoverableError(message, code):
            errorView(message: message, code: code)
        }
    }

    private var isCaptureCameraState: Bool {
        switch flow.state {
        case .countdown, .recording: true
        default: false
        }
    }

    private var importView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("把网页里的灵感带到现场", systemImage: "qrcode.viewfinder")
                .font(.title2.weight(.bold))
            Text("扫描二维码或输入六位任务码，继续你的 ShotPlan。")
                .foregroundStyle(.secondary)
            TextField("输入六位任务码", text: $flow.codeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.title3.monospaced().weight(.bold))
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityLabel("六位任务码")
            Button("查看 ShotPlan") { flow.loadPreview() }
                .buttonStyle(SecondaryButtonStyle())

            if let preview = flow.preview {
                VStack(alignment: .leading, spacing: 12) {
                    Label("这就是你的旅拍任务", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    LabeledContent("任务码", value: preview.code)
                    LabeledContent(
                        "创作方式",
                        value: ProductCopy.creationMode(preview.mode.rawValue)
                    )
                    LabeledContent("有效期", value: preview.expiresAt.formatted())
                }
                .padding(15)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))

                Button("把它带到 iPhone") { flow.confirmClaim() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(preview.status != .created)
            }
        }
    }

    private func summaryView(_ task: ImportedTask) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("你的 ShotPlan 已到达", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)

            Text("离线也能查看，准备好就让 SoloShot 陪你完成这一拍。")
                .foregroundStyle(.secondary)

            referenceView(task)

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("创作方式", value: ProductCopy.creationMode(task.mode))
                LabeledContent("手机放这里", value: "\(ProductCopy.cameraHeight(task.cameraHeight)) · \(ProductCopy.cameraAngle(task.cameraAngle))")
                LabeledContent("这样取景", value: ProductCopy.lens(task.lens))
                Text(task.setupInstruction)
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))

            ForEach(task.actions) { action in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(action.sequence)")
                        .font(.headline)
                        .frame(width: 34, height: 34)
                        .background(.orange, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.instruction).fontWeight(.semibold)
                        Text("\(action.durationSeconds.formatted()) 秒").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let safety = task.safetyNotes.first {
                Label(safety, systemImage: "checkmark.shield.fill")
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.green)
                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }

            Button("开始现场陪拍") {
                phoneSecured = false
                flow.openSetup(task)
            }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!task.canStartAlignment)
            Text(task.canStartAlignment
                 ? "参考画面与实时识别默认留在本机；只有你选中的照片会在同意后上传。"
                 : "这份旧任务缺少现场陪拍信息，请从网页重新接力。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setupView(_ task: ImportedTask) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("把手机放好，就差你入镜", systemImage: "checklist")
                .font(.title2.weight(.bold))
            Text("确认机位稳定、脚下安全，SoloShot 会在你走进画面后实时引导。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 13) {
                LabeledContent("镜头", value: "1× 主摄")
                LabeledContent("方向", value: "竖屏")
                LabeledContent("机位", value: "\(ProductCopy.cameraHeight(task.cameraHeight)) · \(ProductCopy.cameraAngle(task.cameraAngle))")
                Text(task.setupInstruction)
                    .foregroundStyle(.secondary)
                if task.lens != "1x" {
                    Label("这次将使用 1× 主摄，保证现场陪拍更稳定。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .padding(15)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))

            if let safety = task.safetyNotes.first {
                Label(safety, systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }

            Toggle("声音引导", isOn: $voiceEnabled)
                .frame(minHeight: 44)
            Toggle("触感提醒", isOn: $hapticsEnabled)
                .frame(minHeight: 44)
            Toggle("手机已固定，周围安全", isOn: $phoneSecured)
                .frame(minHeight: 52)
                .accessibilityHint("确认后即可开始现场陪拍")

            Button("开始实时陪拍") {
                flow.beginAlignment(
                    for: task,
                    voiceEnabled: voiceEnabled,
                    hapticsEnabled: hapticsEnabled
                )
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!phoneSecured)

            Button("返回 ShotPlan") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func readyView(_ task: ImportedTask, completion: AlignmentCompletion) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if completion.isFixture {
                Label("演示模式", systemImage: "testtube.2")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            Label("构图已经对上了", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)
            Text(completionLabel(completion.mode))
                .font(.headline)
            Text("准备好动作，就可以记录这一刻。")
                .foregroundStyle(.secondary)
            Button("再调整一下") {
                phoneSecured = true
                flow.openSetup(task)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("准备动作") {
                flow.openActionBrief(task, completion: completion)
            }
                .buttonStyle(PrimaryButtonStyle())
            Button("返回 ShotPlan") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func actionBriefView(
        _ task: ImportedTask,
        completion: AlignmentCompletion,
        method: LocalCaptureMethod
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if completion.isFixture {
                Label("演示模式 · 优化建议来自精选样例", systemImage: "testtube.2")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            Label("现在，完成这个动作", systemImage: "figure.stand")
                .font(.title2.weight(.bold))
            Text(task.actions.first?.instruction ?? "保持自然动作并看向镜头。")
                .font(.headline)
            Text("就位后会自动倒数 3 秒，声音只提示关键节奏。")
                .foregroundStyle(.secondary)
            HStack {
                Text("记录方式")
                Spacer()
                Text(captureMethodLabel(method))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("capture-method")
            }
                .padding(15)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
            if completion.mode == .manual {
                Label("手动就位 · 构图与动作尚未验证", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("我已就位") {
                flow.beginCountdown(task: task, completion: completion, method: method)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("返回调整") { flow.returnToSetup(task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func selectionView(_ task: ImportedTask, work: CaptureWork) -> some View {
        let round = work.currentRound
        return VStack(alignment: .leading, spacing: 16) {
            Label("这一拍，哪一刻最像你？", systemImage: "photo.on.rectangle.angled")
                .font(.title2.weight(.bold))
            Text("SoloShot 已在本机挑出推荐帧，选择你最喜欢的一张。")
                .foregroundStyle(.secondary)
            if let round {
                ForEach(Array(round.candidates.enumerated()), id: \.element.id) { index, candidate in
                    VStack(alignment: .leading, spacing: 10) {
                        CaptureCandidateImage(filename: candidate.localFilename)
                        HStack {
                            if index == 0 {
                                Label("SoloShot 推荐", systemImage: "sparkles")
                                    .foregroundStyle(.orange)
                            } else {
                                Text("候选 \(index + 1)")
                            }
                            Spacer()
                            if let milliseconds = candidate.timestampMilliseconds,
                               round.captureMethod == .shortVideo
                            {
                                Text("\(Double(milliseconds) / 1_000, format: .number.precision(.fractionLength(1)))s")
                                    .font(.caption.monospaced())
                            }
                        }
                        ForEach(candidate.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if index == 0 {
                            Button("就选这一张") {
                                flow.selectCandidate(task: task, work: work, frameID: candidate.id)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button("就选这一张") {
                                flow.selectCandidate(task: task, work: work, frameID: candidate.id)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    .padding(14)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private func consentView(_ task: ImportedTask, work: CaptureWork) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("只上传你选中的这一张", systemImage: "lock.shield.fill")
                .font(.title2.weight(.bold))
            Text("整段视频、其他候选与实时识别数据都留在本机。")
                .foregroundStyle(.secondary)
            if let candidate = work.currentRound?.selectedCandidate {
                CaptureCandidateImage(filename: candidate.localFilename)
            }
            if task.usesFixtureEvaluation {
                Label("演示模式 · 照片不会交给 AI 判断，结果来自预设样例", systemImage: "testtube.2")
                    .foregroundStyle(.orange)
            } else {
                Toggle("我同意将这张照片发送至火山方舟进行 AI 分析", isOn: $externalAIConsent)
                    .frame(minHeight: 52)
            }
            Button(task.usesFixtureEvaluation ? "上传这张照片并查看演示结果" : "同意并继续") {
                flow.confirmCaptureConsent(
                    task: task,
                    work: work,
                    externalAIConsent: task.usesFixtureEvaluation ? false : externalAIConsent
                )
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!task.usesFixtureEvaluation && !externalAIConsent)
        }
    }

    private func uploadPendingView(_ task: ImportedTask, work: CaptureWork) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            Label("这一张已留在本机", systemImage: "checkmark.icloud.fill")
                .font(.title2.weight(.bold))
            Text("网络恢复后，可从这里继续提交与复盘。")
                .foregroundStyle(.secondary)
            Button("继续复盘") { flow.submit(task: task, work: work) }
                .buttonStyle(PrimaryButtonStyle())
            Button("稍后再说") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func coachingView(_ task: ImportedTask, work: CaptureWork) -> some View {
        let evaluation = work.currentRound?.evaluation
        return VStack(alignment: .leading, spacing: 18) {
            executionBadge(evaluation?.executionMode)
            Label("下一拍，只改这一点", systemImage: "scope")
                .font(.title2.weight(.bold))
            Text(evaluation?.topIssue ?? "这一拍还可以更好")
                .foregroundStyle(.secondary)
            Text(controlledInstruction(issueCode: evaluation?.issueCode))
                .font(.title3.weight(.bold))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 15))
            Text("其他都保持不变。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("带着建议再拍一次") { flow.startRetake(task: task) }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func finalResultView(_ task: ImportedTask, work: CaptureWork) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("你拍到了想要的画面", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)
            Text("第一拍是开始，第二拍是你和 SoloShot 一起完成的作品。")
                .foregroundStyle(.secondary)
            ForEach(work.rounds) { round in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(ProductCopy.round(round.roundIndex)).font(.headline)
                        Spacer()
                        executionBadge(round.evaluation?.executionMode)
                    }
                    if let candidate = round.selectedCandidate {
                        CaptureCandidateImage(filename: candidate.localFilename)
                    }
                    LabeledContent(
                        "作品就绪度",
                        value: (round.evaluation?.publishReadiness ?? 0).formatted(.percent.precision(.fractionLength(0)))
                    )
                    if let issue = round.evaluation?.topIssue { Text(issue).foregroundStyle(.secondary) }
                    if round.alignmentMode == .manual {
                        Label("本次使用手动确认", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(14)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            }
            if task.usesFixtureEvaluation {
                Label("照片来自本次拍摄；作品就绪度为演示参考，不代表 AI 对照片的判断。", systemImage: "testtube.2")
                    .foregroundStyle(.orange)
            } else if work.rounds.count == 2,
                      work.rounds.last?.evaluation?.goalSatisfied == false
            {
                Text("两次拍摄已完成，仍有一处可以继续改进。")
                    .foregroundStyle(.secondary)
            }
            Button("完成这次旅拍") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func offlinePendingView(_ task: ImportedTask, work: CaptureWork, message: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("网络离开了，创作还在", systemImage: "wifi.slash")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text("所选照片和进度已保存在本机，联网后可以继续。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重新连接") { flow.retryPending(task: task, work: work) }
                .buttonStyle(PrimaryButtonStyle())
            Button("稍后继续") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func captureErrorView(
        _ task: ImportedTask,
        message: String,
        canUsePhotoFallback: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("这一拍没有保存下来", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text("准备好后，可以重新记录这一刻。")
            if canUsePhotoFallback {
                Button("改用三张连拍") { flow.usePhotoFallback(task: task) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("返回准备") { flow.returnToSetup(task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private func executionBadge(_ mode: String?) -> some View {
        let value = mode ?? "pending"
        Text(ProductCopy.executionMode(value))
            .font(.caption.weight(.bold))
            .foregroundStyle(value == "fixture" ? .orange : .green)
    }

    private func controlledInstruction(issueCode: String?) -> String {
        switch issueCode {
        case "person_too_large": "向后退半步"
        case "person_too_small": "向前靠近半步"
        case "person_too_left": "向右移动半步"
        case "person_too_right": "向左移动半步"
        case "head_cut": "降低头顶留白"
        case "feet_cut": "让双脚完整入镜"
        case "background_blocked": "移开背景遮挡"
        case "pose_direction_wrong": "调整身体方向"
        case "arm_position_wrong": "调整手臂动作"
        case "camera_too_high": "降低手机高度"
        case "camera_too_low": "抬高手机高度"
        case "camera_angle_wrong": "保持镜头水平"
        default: "按任务摘要重新对齐"
        }
    }

    private func captureMethodLabel(_ method: LocalCaptureMethod) -> String {
        switch method {
        case .photo: "三张照片连拍"
        case .shortVideo: "5–8 秒无声短视频"
        case .photoFallback: "三张照片连拍"
        }
    }

    private func cameraErrorView(_ task: ImportedTask, failure: CameraFailure) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("相机还没准备好", systemImage: "camera.fill.badge.exclamationmark")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text(failure.localizedDescription)
            if failure == .permissionDenied,
               let settings = URL(string: UIApplication.openSettingsURLString)
            {
                Link("去系统设置开启相机", destination: settings)
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("返回准备") { flow.returnToSetup(task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func completionLabel(_ mode: AlignmentCompletionMode) -> String {
        switch mode {
        case .verified: "人物位置、画面比例与动作方向都已就位。"
        case .compositionOnly: "构图已就位，照着 ShotPlan 完成动作即可。"
        case .manual: "这是手动确认，SoloShot 尚未验证构图与动作。"
        }
    }

    @ViewBuilder
    private func referenceView(_ task: ImportedTask) -> some View {
        if let filename = task.localReferenceFilename {
            LocalReferenceImage(filename: filename)
        } else if let name = task.presetThumbnailName,
                  let url = Bundle.main.url(forResource: name, withExtension: "webp"),
                  let image = UIImage(contentsOfFile: url.path)
        {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 250)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 15))
        } else {
            Label("参考图暂不可用，ShotPlan 不受影响", systemImage: "photo.badge.exclamationmark")
                .frame(maxWidth: .infinity, minHeight: 130)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private func errorView(message: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("这份 ShotPlan 还没接上", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text("确认任务码后再试一次，你的网页进度不会丢失。")
            Button("再试一次") { flow.retry() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func statusView(title: String, detail: String) -> some View {
        VStack(spacing: 13) {
            ProgressView()
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}

private struct LocalReferenceImage: View {
    let filename: String

    var body: some View {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SoloShot", directoryHint: .isDirectory)
        if let image = UIImage(contentsOfFile: directory.appending(path: filename).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 250)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 15))
        } else {
            Label("参考画面暂时无法显示，ShotPlan 仍可离线执行", systemImage: "photo.badge.exclamationmark")
                .frame(maxWidth: .infinity, minHeight: 130)
        }
    }
}

private struct CaptureCandidateImage: View {
    let filename: String

    var body: some View {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SoloShot/CaptureWork", directoryHint: .isDirectory)
        if let image = UIImage(contentsOfFile: root.appending(path: filename).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 320)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 13))
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityLabel("本地候选照片")
        } else {
            Label("候选照片暂不可读取", systemImage: "photo.badge.exclamationmark")
                .frame(maxWidth: .infinity, minHeight: 130)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.bold)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(.orange.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 13))
    }
}
