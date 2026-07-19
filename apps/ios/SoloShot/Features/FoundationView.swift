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
            Text("W5")
                .font(.caption.weight(.bold))
                .foregroundStyle(.green)
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var content: some View {
        switch flow.state {
        case .launch:
            statusView(title: "正在恢复任务…", detail: "优先读取 24 小时本地缓存。")
        case .taskImport:
            importView
        case .importing:
            statusView(title: "正在安全导入…", detail: "任务写入本地后会立即显示摘要。")
            Button("取消") { flow.cancelImport() }
                .buttonStyle(SecondaryButtonStyle())
        case let .referenceSummary(task):
            summaryView(task)
        case let .setup(task):
            setupView(task)
        case let .cameraPreparing(task):
            statusView(title: "正在准备后置 1× 相机…", detail: "Vision 将只在设备本地处理预览帧。")
            Button("取消") { flow.returnToSetup(task) }
                .buttonStyle(SecondaryButtonStyle())
        case .aligning:
            statusView(title: "正在打开相机…", detail: "相机界面准备完成后会自动显示。")
        case let .ready(task, completion):
            readyView(task, completion: completion)
        case let .actionBrief(task, completion, method):
            actionBriefView(task, completion: completion, method: method)
        case .countdown, .recording:
            statusView(title: "正在打开采集画面…", detail: "相机会话保持运行。")
        case let .processingFrames(_, roundIndex):
            statusView(title: "正在生成本地候选帧…", detail: "Round \(roundIndex) · 原视频不会上传。")
        case let .selectingFrame(task, work):
            selectionView(task, work: work)
        case let .consent(task, work):
            consentView(task, work: work)
        case let .uploadPending(task, work):
            uploadPendingView(task, work: work)
        case let .uploading(_, work):
            statusView(title: "正在上传所选 JPEG…", detail: "Round \(work.currentRound?.roundIndex ?? 1) · 未选帧不会上传。")
        case let .comparing(_, work):
            statusView(title: "正在比较拍摄结果…", detail: "Round \(work.currentRound?.roundIndex ?? 1) · 单帧评价不会判断动作时机。")
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
            Label("从网页接力 ShotPlan", systemImage: "qrcode.viewfinder")
                .font(.title2.weight(.bold))
            Text("可用系统相机打开深链，也可以粘贴或手输六位码。认领前只读取安全公开预览。")
                .foregroundStyle(.secondary)
            TextField("例如 ABC234", text: $flow.codeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.title3.monospaced().weight(.bold))
                .padding(14)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityLabel("六位任务码")
            Button("检查任务码") { flow.loadPreview() }
                .buttonStyle(SecondaryButtonStyle())

            if let preview = flow.preview {
                VStack(alignment: .leading, spacing: 12) {
                    Label("安全预览", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    LabeledContent("任务码", value: preview.code)
                    LabeledContent(
                        "模式",
                        value: preview.mode == .originalReplication ? "原图复刻" : "场景适配"
                    )
                    LabeledContent("有效期", value: preview.expiresAt.formatted())
                }
                .padding(15)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))

                Button("确认认领并缓存") { flow.confirmClaim() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(preview.status != .created)
            }
        }
    }

    private func summaryView(_ task: ImportedTask) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("任务已缓存，可离线查看", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)

            referenceView(task)

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Plan ID", value: task.planID)
                LabeledContent("模式", value: task.mode == "original_replication" ? "原图复刻" : "场景适配")
                LabeledContent("机位", value: "\(task.cameraHeight) · \(task.cameraAngle)")
                LabeledContent("镜头", value: task.lens)
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
                 ? "预览与 Vision 默认仅在本地处理；只有你确认的候选 JPEG 会在明确同意后上传。"
                 : "此旧任务缺少目标布局，请从 H5 重新导入后再开始陪拍。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setupView(_ task: ImportedTask) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("拍摄前准备", systemImage: "checklist")
                .font(.title2.weight(.bold))
            Text("先按任务要求固定手机。SoloShot 能验证部分人物构图，但不会判断支架是否稳固或现场是否安全。")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 13) {
                LabeledContent("镜头", value: "后置 1×")
                LabeledContent("方向", value: "竖屏")
                LabeledContent("机位", value: "\(task.cameraHeight) · \(task.cameraAngle)")
                Text(task.setupInstruction)
                    .foregroundStyle(.secondary)
                if task.lens != "1x" {
                    Label("原计划为 \(task.lens)，现场陪拍将使用 1× 降级执行。", systemImage: "exclamationmark.triangle.fill")
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

            Toggle("语音提示", isOn: $voiceEnabled)
                .frame(minHeight: 44)
            Toggle("触觉提示", isOn: $hapticsEnabled)
                .frame(minHeight: 44)
            Toggle("手机已固定，脚下环境安全", isOn: $phoneSecured)
                .frame(minHeight: 52)
                .accessibilityHint("确认后才能进入相机")

            Button("进入实时对齐") {
                flow.beginAlignment(
                    for: task,
                    voiceEnabled: voiceEnabled,
                    hapticsEnabled: hapticsEnabled
                )
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!phoneSecured)

            Button("返回任务摘要") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func readyView(_ task: ImportedTask, completion: AlignmentCompletion) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if completion.isFixture {
                Label("Fixture 演示结果", systemImage: "testtube.2")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            Label("构图已就位", systemImage: "checkmark.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)
            Text(completionLabel(completion.mode))
                .font(.headline)
            Text("下一步会先显示受控动作提示，再自动执行三秒倒计时。")
                .foregroundStyle(.secondary)
            Button("继续调整") {
                phoneSecured = true
                flow.openSetup(task)
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("准备动作并拍摄") {
                flow.openActionBrief(task, completion: completion)
            }
                .buttonStyle(PrimaryButtonStyle())
            Button("返回任务摘要") { flow.exitAlignment(toSummary: task) }
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
                Label("Fixture 本地候选与固定评分", systemImage: "testtube.2")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            Label("准备动作", systemImage: "figure.stand")
                .font(.title2.weight(.bold))
            Text(task.actions.first?.instruction ?? "保持自然动作并看向镜头。")
                .font(.headline)
            Text("语音只会播报“准备动作、三二一、开始、保持、完成”等本地固定短句，不会朗读模型自由文本。")
                .foregroundStyle(.secondary)
            HStack {
                Text("采集方式")
                Spacer()
                Text(captureMethodLabel(method))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("capture-method")
            }
                .padding(15)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
            if completion.mode == .manual {
                Label("本轮基于手动就位，未经 Vision 验证。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button("就位后自动倒计时") {
                flow.beginCountdown(task: task, completion: completion, method: method)
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("返回继续调整") { flow.returnToSetup(task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func selectionView(_ task: ImportedTask, work: CaptureWork) -> some View {
        let round = work.currentRound
        return VStack(alignment: .leading, spacing: 16) {
            Label("选择一张候选帧", systemImage: "photo.on.rectangle.angled")
                .font(.title2.weight(.bold))
            Text("推荐完全在本地完成。你可以选择任意候选；系统不会展示身体评分。")
                .foregroundStyle(.secondary)
            if let round {
                ForEach(Array(round.candidates.enumerated()), id: \.element.id) { index, candidate in
                    VStack(alignment: .leading, spacing: 10) {
                        CaptureCandidateImage(filename: candidate.localFilename)
                        HStack {
                            if index == 0 {
                                Label("本地推荐", systemImage: "sparkles")
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
                            Button("选择本地推荐") {
                                flow.selectCandidate(task: task, work: work, frameID: candidate.id)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button("选择这张") {
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
            Label("确认上传所选照片", systemImage: "lock.shield.fill")
                .font(.title2.weight(.bold))
            Text("只上传你刚刚选择的 JPEG。整段视频、未选候选、Vision 坐标和预览帧不会上传。")
                .foregroundStyle(.secondary)
            if let candidate = work.currentRound?.selectedCandidate {
                CaptureCandidateImage(filename: candidate.localFilename)
            }
            if task.usesFixtureEvaluation {
                Label("真实照片将关联 Fixture 固定演示评分，不会调用 Ark，也不代表 AI 已验证改善。", systemImage: "testtube.2")
                    .foregroundStyle(.orange)
            } else {
                Toggle("同意将所选照片发送至火山方舟分析", isOn: $externalAIConsent)
                    .frame(minHeight: 52)
            }
            Button("同意并上传所选 JPEG") {
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
            Label("候选帧已安全保存在本机", systemImage: "checkmark.icloud.fill")
                .font(.title2.weight(.bold))
            Text("当前尚未上传。继续后会从上次成功的网络步骤恢复。")
                .foregroundStyle(.secondary)
            Button("继续上传与评价") { flow.submit(task: task, work: work) }
                .buttonStyle(PrimaryButtonStyle())
            Button("稍后处理") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func coachingView(_ task: ImportedTask, work: CaptureWork) -> some View {
        let evaluation = work.currentRound?.evaluation
        return VStack(alignment: .leading, spacing: 18) {
            executionBadge(evaluation?.executionMode)
            Label("只修正一个问题", systemImage: "scope")
                .font(.title2.weight(.bold))
            Text(evaluation?.topIssue ?? "本轮仍可继续改进")
                .foregroundStyle(.secondary)
            Text(controlledInstruction(issueCode: evaluation?.issueCode))
                .font(.title3.weight(.bold))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 15))
            Text("第二轮会重新执行准备、对齐与拍摄，不复用第一轮的就位结论。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("开始第二轮") { flow.startRetake(task: task) }
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func finalResultView(_ task: ImportedTask, work: CaptureWork) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("两轮结果", systemImage: "checkmark.seal.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.green)
            ForEach(work.rounds) { round in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Round \(round.roundIndex)").font(.headline)
                        Spacer()
                        executionBadge(round.evaluation?.executionMode)
                    }
                    if let candidate = round.selectedCandidate {
                        CaptureCandidateImage(filename: candidate.localFilename)
                    }
                    LabeledContent(
                        "Readiness",
                        value: (round.evaluation?.publishReadiness ?? 0).formatted(.percent.precision(.fractionLength(0)))
                    )
                    if let issue = round.evaluation?.topIssue { Text(issue).foregroundStyle(.secondary) }
                    if round.alignmentMode == .manual {
                        Label("本轮未经 Vision 验证", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(14)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            }
            if task.usesFixtureEvaluation {
                Label("照片为本次真实/本地采集；评分为 Fixture 固定演示数据，不是模型对这些照片的分析。", systemImage: "testtube.2")
                    .foregroundStyle(.orange)
            } else if work.rounds.count == 2,
                      work.rounds.last?.evaluation?.goalSatisfied == false
            {
                Text("第二轮已结束，结果仍可继续改进；W5 不增加第三轮。")
                    .foregroundStyle(.secondary)
            }
            Button("返回任务摘要") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func offlinePendingView(_ task: ImportedTask, work: CaptureWork, message: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("待联网继续", systemImage: "wifi.slash")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text(message)
            Text("所选 JPEG 与幂等进度保存在本机；App 冷启动或网络恢复后可以继续。系统杀死 App 后不会宣称仍在后台上传。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("重试") { flow.retryPending(task: task, work: work) }
                .buttonStyle(PrimaryButtonStyle())
            Button("稍后处理") { flow.exitAlignment(toSummary: task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func captureErrorView(
        _ task: ImportedTask,
        message: String,
        canUsePhotoFallback: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("本轮采集未完成", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text(message)
            if canUsePhotoFallback {
                Button("切换照片降级") { flow.usePhotoFallback(task: task) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("返回准备页") { flow.returnToSetup(task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private func executionBadge(_ mode: String?) -> some View {
        let value = mode ?? "pending"
        Text(value == "fixture" ? "Fixture 固定评分" : value == "live" ? "Live" : value.capitalized)
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
        case .photoFallback: "照片降级（三张连拍）"
        }
    }

    private func cameraErrorView(_ task: ImportedTask, failure: CameraFailure) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("相机暂不可用", systemImage: "camera.fill.badge.exclamationmark")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text(failure.localizedDescription)
            Text(failure.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
            if failure == .permissionDenied,
               let settings = URL(string: UIApplication.openSettingsURLString)
            {
                Link("打开系统设置", destination: settings)
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("返回准备页") { flow.returnToSetup(task) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func completionLabel(_ mode: AlignmentCompletionMode) -> String {
        switch mode {
        case .verified: "人物、构图与受支持的简化姿势已验证。"
        case .compositionOnly: "构图已验证；请按任务摘要完成动作。"
        case .manual: "这是手动确认结果，姿势和构图未经 Vision 验证。"
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
            Label("导入未完成", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.orange)
            Text(message)
            Text(code).font(.caption.monospaced()).foregroundStyle(.secondary)
            Button("重试") { flow.retry() }
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
            Label("参考图缓存失败，ShotPlan 仍可离线执行", systemImage: "photo.badge.exclamationmark")
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
