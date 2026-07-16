import SwiftUI

struct FoundationView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.13), Color(red: 0.12, green: 0.16, blue: 0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                Text("SOLOSHOT AI · W0")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.4))

                Text("同一份任务，\n从网页走到镜头前。")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .tracking(-1.5)

                Text("当前是可构建的 iOS 基础骨架。相机、Vision 与实时陪拍将在后续工作包接入。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)

                Label("共享契约已接入", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.39, green: 0.89, blue: 0.63))
                    .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .padding(28)
        }
    }
}

