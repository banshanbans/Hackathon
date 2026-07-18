import SwiftUI

struct FoundationView: View {
    @ObservedObject var flow: AppFlowModel

    var body: some View {
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
        .preferredColorScheme(.dark)
    }

    private var brand: some View {
        HStack {
            Image(systemName: "camera.aperture")
                .foregroundStyle(.orange)
            Text("SoloShot AI")
                .font(.headline.weight(.bold))
            Spacer()
            Text("W3")
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
        case let .recoverableError(message, code):
            errorView(message: message, code: code)
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

            Button("开始原生陪拍（W4）") {}
                .buttonStyle(PrimaryButtonStyle())
                .disabled(true)
            Text("W3 不提供假相机；AVFoundation、Vision 与 Overlay 将在 W4 接入。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
