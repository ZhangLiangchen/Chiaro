import SwiftUI

struct PublishingGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("发布与传图防坑指南")
                        .font(.title2.bold())
                    Text("覆盖 AirDrop / iOS 18–27 相册、小红书 Ultra HDR 与抖音必亮 HLG MP4 全链路规范")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    guideCard(
                        icon: "airplayaudio",
                        tint: .blue,
                        title: "1. AirDrop 与 iPhone 相册（iOS 18–27）",
                        summary: "iOS 18–27 相册中原生静态 Adaptive HDR（ISO 21496-1）不显示左上角「HDR」角标，这与 iPhone 原相机直出完全一致。",
                        dos: [
                            "使用 AirDrop（保持原图）或 iCloud 照片同步传输到 iPhone。",
                            "在 iPhone「设置 → 照片 → 查看完整 HDR」保持开启状态以高亮查看。",
                            "通过本软件导出的「HDR 合规通过 ✅」徽章与实测 Headroom（如 5.66× / +2.5 EV）确认增益图完好。",
                            "如需要在 macOS 照片中使用智能相簿筛选 HDR，可在导出设置中勾选 CustomRendered = 3。"
                        ],
                        donts: [
                            "严禁使用 Finder USB「同步相册」（可能重新压图并丢失增益图辅助轨道）。",
                            "严禁开启 AirDrop「兼容性最佳」或通过微信非原图转发（会剥离 Gain Map 回退为 SDR）。"
                        ]
                    )

                    guideCard(
                        icon: "sparkles.rectangle.stack",
                        tint: .pink,
                        title: "2. 小红书 HDR 发布规范（xiaohongshu_jpg）",
                        summary: "推荐画幅 3:4、长边 ≤ 2048 px、单文件 ≤ 4 MB、单通道 L008 Ultra HDR v1.1 JPEG（Display P3 ICC + 闭环 SDR 补偿）。",
                        dos: [
                            "经 AirDrop 原图传入 iPhone 相册后，使用最新版小红书 iOS App 直接从相册选图发布。",
                            "同贴多图请保持统一画幅比例（如全部 3:4）。"
                        ],
                        donts: [
                            "严禁网页端上传（会丢失 Gain Map）。",
                            "严禁站内裁剪、加滤镜、贴纸或花字（客户端二次重编码会剥离 ISO APP2 / XMP 增益图）。"
                        ]
                    )

                    guideCard(
                        icon: "video.badge.checkmark",
                        tint: .orange,
                        title: "3. 抖音发布避坑（图文 JPEG vs 必亮 HLG MP4）",
                        summary: "实测抖音图文静态照目前服务端多数仍将 JPEG 剥离为 SDR；若需 100% 稳定触发手机 OLED HDR 点亮，请务必使用预设 #5「抖音必亮 HDR 动态图」。",
                        dos: [
                            "追求 100% 必亮 OLED HDR：选用「douyin_hlg_mp4」导出 10-bit HEVC Main10 BT.2020 HLG MP4（1080×1920 竖屏或 1080×1440，3–5s，30fps，12–16 Mbps）。",
                            "在抖音 iOS App 上传该 MP4 时，务必勾选「高清发布」（iOS 相册同时会显示原生 HDR 视频角标）。",
                            "若必须发静态图文（douyin_jpg）：预设已自动提高 SDR 支路反差与饱和度，确保即使被服务端转成 SDR 也不发灰，同时保留 Ultra HDR v1.1 前向兼容。"
                        ],
                        donts: [
                            "严禁向抖音导出 4K HLG MP4（会被服务端强制重编码压坏 HDR 元数据；本工具已锁定长边 ≤ 1920 px）。"
                        ]
                    )
                }
                .padding(.vertical, 4)
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 540)
    }

    private func guideCard(
        icon: String,
        tint: Color,
        title: String,
        summary: String,
        dos: [String],
        donts: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }

            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(dos, id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("✅")
                        Text(line)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(donts, id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("⛔️")
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.3), lineWidth: 1)
        )
    }
}
