import Foundation
import ChiaroCore

public enum ChiaroStrings {
    private static func pick(_ lang: ResolvedLanguage, zh: String, en: String) -> String {
        switch lang {
        case .zhHans: return zh
        case .en: return en
        }
    }

    // MARK: - App, Toolbar & Menus

    public static func workspaceModeLabel(_ mode: WorkspaceMode, lang: ResolvedLanguage) -> String {
        switch mode {
        case .preset: return pick(lang, zh: "预设模式", en: "Preset Mode")
        case .pro: return pick(lang, zh: "专业模式", en: "Pro Mode")
        }
    }

    public static func appLanguageLabel(_ language: AppLanguage, lang: ResolvedLanguage) -> String {
        switch language {
        case .system: return pick(lang, zh: "跟随系统", en: "Follow System")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public static func toolbarImportARW(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入 ARW", en: "Import ARW")
    }

    public static func toolbarGainMap(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "Gain Map [G]", en: "Gain Map [G]")
    }

    public static func toolbarInlineDocs(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "参数说明", en: "Param Docs")
    }

    public static func toolbarLanguage(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "语言", en: "Language")
    }

    public static func toolbarGuide(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "发布防坑指南", en: "Publishing Guide")
    }

    public static func toolbarBatchExport(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "批量导出...", en: "Batch Export...")
    }

    public static func menuView(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "检视", en: "View")
    }

    public static func menuToggleGainMap(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "切换 Gain Map 直视", en: "Toggle Gain Map Direct View")
    }

    public static func menuToggleWorkspaceMode(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "切换预设 / 专业模式", en: "Toggle Preset / Pro Mode")
    }

    public static func alertTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "提示", en: "Notice")
    }

    public static func okButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "确定", en: "OK")
    }

    // MARK: - Popover Documentation Sections

    public static func docControlsWhat(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "调节对象", en: "Controls")
    }

    public static func docLeftEffect(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "低值 / 左移效果", en: "Lower / Left Effect")
    }

    public static func docRightEffect(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "高值 / 右移效果", en: "Higher / Right Effect")
    }

    public static func docRecommendedRange(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "推荐范围", en: "Recommended")
    }

    public static func docProTip(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "工程提示", en: "Pro Tip")
    }

    // MARK: - Built-in Preset Localization (without modifying Presets/*.json)

    public static func presetName(_ preset: PresetSchema, lang: ResolvedLanguage) -> String {
        switch (preset.id, lang) {
        case ("apple_heic", .zhHans): return "Apple 相册原生高保真（默认）"
        case ("apple_heic", .en): return "Apple Photos Native HDR (Default)"
        case ("apple_heic_compat", .zhHans): return "Apple 兼容全代（含 iOS 14–17）"
        case ("apple_heic_compat", .en): return "Apple All-Gen Compat (incl. iOS 14–17)"
        case ("xiaohongshu_jpg", .zhHans): return "小红书 HDR（推荐）"
        case ("xiaohongshu_jpg", .en): return "Xiaohongshu HDR (Recommended)"
        case ("douyin_jpg", .zhHans): return "抖音图文 HDR 兼容"
        case ("douyin_jpg", .en): return "Douyin Photo Post Compat"
        case ("douyin_hlg_mp4", .zhHans): return "抖音必亮 HDR 动态图（10-bit HLG MP4）"
        case ("douyin_hlg_mp4", .en): return "Douyin Guaranteed OLED HDR (10-bit HLG MP4)"
        case ("tri_format", .zhHans): return "全平台三格式一键归档"
        case ("tri_format", .en): return "Tri-Format Universal Archive"
        case ("avif_archive", .zhHans): return "次时代 Web / 极致压缩归档（AVIF）"
        case ("avif_archive", .en): return "Next-Gen Web / Compact Archive (AVIF)"
        default: return preset.name
        }
    }

    public static func presetDescription(_ preset: PresetSchema, lang: ResolvedLanguage) -> String {
        switch (preset.id, lang) {
        case ("apple_heic", .zhHans):
            return "10-bit Display P3 HEIC · 3ch ISO 21496-1 增益图（Apple 硬件编码）"
        case ("apple_heic", .en):
            return "10-bit Display P3 HEIC with 3-channel RGB ISO 21496-1 gain map"
        case ("apple_heic_compat", .zhHans):
            return "10-bit Display P3 HEIC · 1ch 单色双写 ISO tmap 与旧版 Apple HDRGainMap"
        case ("apple_heic_compat", .en):
            return "10-bit P3 HEIC dual-writing ISO tmap and legacy Apple HDRGainMap"
        case ("xiaohongshu_jpg", .zhHans):
            return "8-bit P3 Ultra HDR v1.1 JPEG · 3:4 竖图 ≤2048px ≤4MB"
        case ("xiaohongshu_jpg", .en):
            return "8-bit P3 Ultra HDR v1.1 JPEG (1ch, closed-loop SDR, 3:4 <=2048px)"
        case ("douyin_jpg", .zhHans):
            return "8-bit sRGB Ultra HDR v1.1 JPEG · 增强 SDR 防发灰 3:4 ≤1440px"
        case ("douyin_jpg", .en):
            return "8-bit sRGB Ultra HDR v1.1 JPEG (boosted SDR contrast, 3:4 <=1440px)"
        case ("douyin_hlg_mp4", .zhHans):
            return "10-bit HEVC BT.2020 HLG MP4 · 1080×1920 4s 30fps 必亮 OLED"
        case ("douyin_hlg_mp4", .en):
            return "10-bit HEVC Main10 BT.2020 HLG MP4 (1080x1920, 4s, 30fps)"
        case ("tri_format", .zhHans):
            return "单次解码并发扇出 10-bit HEIC + AVIF（3ch）与 Ultra HDR JPEG"
        case ("tri_format", .en):
            return "Single-decode fan-out: 10-bit P3 HEIC + AVIF (3ch) & Ultra HDR JPEG"
        case ("avif_archive", .zhHans):
            return "10-bit P3 AVIF · 3ch ISO tmap + 自动 MIAF 5.1 Grid Tiling"
        case ("avif_archive", .en):
            return "10-bit P3 AVIF with 3ch ISO tmap & auto MIAF 5.1 Grid Tiling"
        default:
            return preset.description
        }
    }

    public static func presetAdvisory(_ preset: PresetSchema, lang: ResolvedLanguage) -> String {
        switch (preset.id, lang) {
        case ("apple_heic", .zhHans):
            return "推荐经 AirDrop（原图）或 iCloud 照片同步至 iPhone；iOS 18–27 相册原生静态 HDR 无角标，观感与 iPhone 原相机直出一致。"
        case ("apple_heic", .en):
            return "Transfer via AirDrop (Original) or iCloud Photos; iOS 18–27 displays native Adaptive HDR seamlessly without an HDR badge."
        case ("apple_heic_compat", .zhHans):
            return "双写 ISO tmap 与旧版 Apple HDRGainMap（强制单通道 L008 并锁定 gainMapMin=0、gainMapMax=log2(H)），兼容 iOS 14–17 与 macOS 11–14 设备。"
        case ("apple_heic_compat", .en):
            return "Dual-writes ISO tmap and legacy Apple HDRGainMap (1ch L008, [0, log2(H)]) for compatibility back to iOS 14–17 & macOS 11–14."
        case ("xiaohongshu_jpg", .zhHans):
            return "请经 AirDrop 原图传至手机并用最新版小红书 iOS App 直接从相册发布；严禁网页端上传，严禁站内裁剪、加滤镜、贴纸或花字，同贴多图请保持统一画幅比例。"
        case ("xiaohongshu_jpg", .en):
            return "AirDrop original to iPhone and upload directly in the Xiaohongshu iOS App; avoid web upload, in-app crop, filters, or stickers."
        case ("douyin_jpg", .zhHans):
            return "透明提示：抖音图文静态照目前多数仍会被服务端降级为 SDR，本预设增强 SDR 支路反差与饱和度以防发灰并前向兼容 veImageX；需 100% 必亮 OLED HDR 请选用「抖音必亮 HDR 动态图」预设。"
        case ("douyin_jpg", .en):
            return "Note: Douyin currently strips Gain Maps on most static JPEGs; SDR contrast/saturation are boosted to avoid flat fallback. Use Douyin HLG MP4 for guaranteed OLED HDR."
        case ("douyin_hlg_mp4", .zhHans):
            return "请经抖音 iOS App 上传并开启「高清发布」，100% 稳定触发 OLED HDR（严禁导出 4K 以防二次压坏；iOS 相册同时显示原生 HDR 视频角标）。"
        case ("douyin_hlg_mp4", .en):
            return "Upload via Douyin iOS App with HD Upload enabled for guaranteed OLED HDR (never export 4K to avoid forced server re-encoding)."
        case ("tri_format", .zhHans):
            return "一次解码并发扇出三套同源 ISO 21496-1 成品：HEIC（10-bit 3ch，Apple 相册首选）、JPEG（8-bit 1ch Ultra HDR v1.1，跨平台通用）、AVIF（10-bit 3ch + 自动 MIAF Grid Tiling，高压缩归档）。"
        case ("tri_format", .en):
            return "Fan-out three ISO 21496-1 deliverables from one decode: 10-bit 3ch HEIC (Apple Photos), 8-bit 1ch Ultra HDR JPEG (cross-platform), and 10-bit 3ch AVIF (archive)."
        case ("avif_archive", .zhHans):
            return "采用 libavif + SVT-AV1/libaom 编码并自动启用 MIAF 5.1 Grid Tiling，同时通过 Apple ImageIO 与 avifdec 双向校验；不适合直接上传小红书/抖音，且 iCloud 相册同步 AVIF 存在已知缓存限制。"
        case ("avif_archive", .en):
            return "Encodes with libavif + SVT-AV1/libaom and MIAF 5.1 Grid Tiling; verified via Apple ImageIO & avifdec. Not for Xiaohongshu/Douyin uploads."
        default:
            return preset.platformAdvisory
        }
    }

    public static func presetSpecTags(_ preset: PresetSchema, lang: ResolvedLanguage) -> [String] {
        var tags: [String] = []
        let fmt = preset.outputFormats.map { $0.fileExtension.uppercased() }.joined(separator: "+")
        tags.append(fmt)
        if preset.outputFormats.contains(.hlgMP4) {
            tags.append("10-bit HLG")
        } else {
            tags.append("\(preset.bitDepth.rawValue)-bit")
            tags.append(preset.baseColorSpace == .displayP3 ? "P3" : "sRGB")
        }
        if preset.cropAspect != .original {
            tags.append(preset.cropAspect.rawValue)
        }
        if let edge = preset.maxLongEdge {
            tags.append("≤\(edge)px")
        } else {
            tags.append(pick(lang, zh: "全分辨率", en: "Full Res"))
        }
        return tags
    }

    // MARK: - Sidebar & Queue

    public static func presetsTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "预设配置", en: "Presets")
    }

    public static func importButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入", en: "Import")
    }

    public static func exportButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导出", en: "Export")
    }

    public static func platformAdvisoryTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "平台发布提示", en: "Platform Advisory")
    }

    public static func queueTitle(count: Int, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "待处理队列 (\(count))", en: "Queue (\(count))")
    }

    public static func clearButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "清空", en: "Clear")
    }

    public static func filesButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "文件", en: "Files")
    }

    public static func folderButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "文件夹", en: "Folder")
    }

    public static func recursiveToggle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "递归", en: "Recursive")
    }

    public static func recursiveHelp(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入文件夹时递归扫描子目录中的 .ARW 文件", en: "Recursively scan subfolders for Sony .ARW files")
    }

    public static func autoSaveSidecarLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "自动保存 .chiaro.json", en: "Auto-save .chiaro.json")
    }

    public static func dropzoneTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "拖拽索尼 .ARW 文件或目录到此处", en: "Drop Sony .ARW files or folders here")
    }

    public static func dropzoneSubtitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "专注索尼 .ARW（自动忽略 .HIF 及 *.ARW/ 目录，路径去重）", en: "Sony .ARW focused (ignores .HIF & *.ARW/ folders, deduplicates)")
    }

    public static func resetDeltaMenu(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "重置此图微调", en: "Reset Photo Adjustments")
    }

    public static func deleteSidecarMenu(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "删除 .chiaro.json Sidecar", en: "Delete .chiaro.json Sidecar")
    }

    public static func removeFromQueueMenu(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "从队列移除", en: "Remove from Queue")
    }

    public static func sidecarBadge(_ lang: ResolvedLanguage) -> String {
        "Sidecar"
    }

    public static func deltaBadge(_ lang: ResolvedLanguage) -> String {
        "Delta"
    }

    public static func fallbackPrefix(_ reason: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "回退 LibRaw: \(reason)", en: "LibRaw fallback: \(reason)")
    }

    public static func queuedBadge(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "排队", en: "Queued")
    }

    public static func queueStatusLabel(_ status: QueueItemStatus, lang: ResolvedLanguage) -> String {
        switch status {
        case .idle: return pick(lang, zh: "就绪", en: "Ready")
        case .queued: return pick(lang, zh: "排队中", en: "Queued")
        case .decoding: return pick(lang, zh: "解码中", en: "Decoding")
        case .rendered: return pick(lang, zh: "编码中", en: "Encoding")
        case .completed: return pick(lang, zh: "已完成", en: "Done")
        case .failed: return pick(lang, zh: "失败", en: "Failed")
        }
    }

    // MARK: - Preset Mode Inspector

    public static func proOverridesBadge(count: Int, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "含 \(count) 项专业微调", en: "Includes \(count) Pro override\(count == 1 ? "" : "s")")
    }

    public static func inspectInProButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "前往专业模式查看", en: "Inspect in Pro")
    }

    public static func resetProOverridesButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "重置专业微调", en: "Reset Pro")
    }

    public static func presetSectionImageAdjustments(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "基础画面调节", en: "Image Adjustments")
    }

    public static func presetSectionAutoEnhancements(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "智能画质增强", en: "Smart Quality Enhancements")
    }

    public static func presetSectionCompositionExport(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "构图与导出", en: "Composition & Export")
    }

    public static func hdrStrengthTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "HDR 高光强度", en: "HDR Highlight Intensity")
    }

    public static func proHeadroomPreservedHint(_ stops: Double, lang: ResolvedLanguage) -> String {
        let formatted = String(format: "+%.2f EV", stops)
        return pick(lang, zh: "专业设定 \(formatted) 已保留", en: "Pro \(formatted) preserved")
    }

    public static func resetToAsShotButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "按拍摄 (As-Shot)", en: "Reset As-Shot")
    }

    public static func estimatedKelvinLabel(_ kelvin: Double, lang: ResolvedLanguage) -> String {
        pick(lang, zh: String(format: "测光色温: %.0f K", kelvin), en: String(format: "Est. WB: %.0f K", kelvin))
    }

    public static func isoSpeedHint(_ iso: Int?, lang: ResolvedLanguage) -> String {
        guard let iso else {
            return pick(lang, zh: "Sony α7C II 传感器噪声标定模型", en: "Sony α7C II calibrated sensor profile")
        }
        return pick(lang, zh: "当前照片 ISO \(iso) · 自动匹配噪声曲线", en: "Current ISO \(iso) · Calibrated noise curve")
    }

    public static func opticsResolutionBadge(_ info: OpticsResolutionInfo, lang: ResolvedLanguage) -> String {
        switch info.source {
        case .embeddedARW:
            let lens = info.lensMatched ?? pick(lang, zh: "原厂镜头", en: "Sony E Lens")
            return pick(lang, zh: "内嵌原厂曲线 · \(lens)", en: "Embedded ARW · \(lens)")
        case .lensfun:
            let lens = info.lensMatched ?? pick(lang, zh: "Lensfun 匹配", en: "Lensfun Match")
            return pick(lang, zh: "Lensfun 开源库 · \(lens)", en: "Lensfun DB · \(lens)")
        case .none:
            return pick(lang, zh: "无可用光学配置（已跳过）", en: "No optics profile (bypassed)")
        }
    }

    public static func exportWithActivePreset(_ presetName: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "按「\(presetName)」导出...", en: "Export with \"\(presetName)\"...")
    }

    // MARK: - Pro Mode Inspector

    public static func scopeLabel(_ scope: InspectorEditScope, lang: ResolvedLanguage) -> String {
        switch scope {
        case .globalPreset: return pick(lang, zh: "全局预设", en: "Global Preset")
        case .perPhotoDelta: return pick(lang, zh: "单图微调", en: "Per-Photo Delta")
        }
    }

    public static func resetSelectedDeltaButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "重置此图微调", en: "Reset Photo")
    }

    public static func syncToAllButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "同步到全部", en: "Sync to All")
    }

    public static func deltaJSONMenu(_ lang: ResolvedLanguage) -> String {
        "Delta JSON"
    }

    public static func importDeltaMenu(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入 Delta JSON...", en: "Import Delta JSON...")
    }

    public static func exportDeltaMenu(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导出 Delta JSON...", en: "Export Delta JSON...")
    }

    public static func globalPresetNotice(_ presetName: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "当前修改将应用于批量预设「\(presetName)」", en: "Edits apply to global preset \"\(presetName)\"")
    }

    public static func group1Title(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "1. 解码、降噪与开源光学矫正", en: "1. Decode, Denoise & Open-Source Optics")
    }

    public static func group2Title(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "2. 共享基础调色 (Linear Rec.2020)", en: "2. Shared Base Grading (Linear Rec.2020)")
    }

    public static func group3Title(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "3. SDR 基准支路控制 (中灰锁定)", en: "3. SDR Base Branch (Midtone Lock)")
    }

    public static func group4Title(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "4. HDR 与 Gain Map 引擎", en: "4. HDR & Gain Map Engine")
    }

    public static func group5Title(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "5. 构图裁剪与分辨率保护", en: "5. Composition & Resolution Guardrails")
    }

    public static func librawLabel(_ lang: ResolvedLanguage) -> String {
        "LibRaw 0.22+"
    }

    public static func ciraw9Label(_ lang: ResolvedLanguage) -> String {
        "Apple CIRAWv9"
    }

    public static func demosaicName(_ alg: DemosaicAlgorithm, lang: ResolvedLanguage) -> String {
        switch alg {
        case .amaze: return pick(lang, zh: "AMaZE (默认高清)", en: "AMaZE (Sharp Default)")
        case .lmmse: return pick(lang, zh: "LMMSE (高 ISO 夜景)", en: "LMMSE (High-ISO Night)")
        case .dcb: return "DCB"
        case .dht: return "DHT"
        case .ahd: return "AHD"
        }
    }

    public static func denoiseModeName(_ mode: DenoiseEngineMode, lang: ResolvedLanguage) -> String {
        switch mode {
        case .off: return pick(lang, zh: "关闭", en: "Off")
        case .profiledWavelet: return pick(lang, zh: "Profiled Wavelet (v1.1 标定小波)", en: "Profiled Wavelet (v1.1)")
        case .appleCIRAWv9ANE: return pick(lang, zh: "Apple CIRAWv9 ANE", en: "Apple CIRAWv9 ANE")
        case .coreMLANE: return pick(lang, zh: "CoreML ANE (v2 预留)", en: "CoreML ANE (v2 Slot)")
        }
    }

    public static func opticsSourceName(_ source: OpticalProfileSource, lang: ResolvedLanguage) -> String {
        switch source {
        case .auto: return pick(lang, zh: "自动 (优先内嵌)", en: "Auto (Embedded First)")
        case .embedded: return pick(lang, zh: "仅 .ARW 内嵌曲线", en: "Embedded .ARW Only")
        case .lensfun: return pick(lang, zh: "仅 Lensfun 开源库", en: "Lensfun DB Only")
        }
    }

    public static func lensfunAutoLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "自动按 EXIF 匹配", en: "Auto-Match via EXIF")
    }

    public static func importLensfunXMLButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入自定义 Lensfun XML...", en: "Import Custom Lensfun XML...")
    }

    public static func lensfunImportedSuccess(_ fileName: String, count: Int, lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "已导入自定义 Lensfun XML「\(fileName)」（当前已加载 \(count) 支 E 卡口镜头）。",
            en: "Imported custom Lensfun XML \"\(fileName)\" (\(count) E-mount lenses loaded)."
        )
    }

    public static func lensfunImportFailed(_ error: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "Lensfun XML 导入失败：\(error)", en: "Failed to import Lensfun XML: \(error)")
    }

    public static func asShotLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "按拍摄 (As-Shot)", en: "As-Shot")
    }

    public static func customWBLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "自定义色温", en: "Custom Kelvin")
    }

    public static func estimatedWBReadout(_ kelvin: Double, lang: ResolvedLanguage) -> String {
        pick(lang, zh: String(format: "As-Shot 估算色温: %.0f K", kelvin), en: String(format: "Estimated As-Shot WB: %.0f K", kelvin))
    }

    public static func highlightModeName(_ mode: HighlightReconstructionMode, lang: ResolvedLanguage) -> String {
        switch mode {
        case .opposedInpaint: return pick(lang, zh: "Opposed Inpaint (v1.1 抗紫边)", en: "Opposed Inpaint (v1.1)")
        case .blend: return "Blend"
        case .rebuild: return "Rebuild"
        }
    }

    public static func cameraProfileLabel(_ profile: CameraColorProfile, lang: ResolvedLanguage) -> String {
        switch profile {
        case .standard: return pick(lang, zh: "标准 (D65 矩阵)", en: "Standard (D65 Matrix)")
        case let .creativeLook(name): return "Look: \(name)"
        case let .dcp(path): return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    public static func loadDCPButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "加载外部 .dcp 文件...", en: "Load External .dcp Profile...")
    }

    public static func chooseCubeButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "选择 .cube...", en: "Choose .cube...")
    }

    public static func clearShortButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "清除", en: "Clear")
    }

    public static func toneMapperName(_ mapper: SDRToneMapper, lang: ResolvedLanguage) -> String {
        switch mapper {
        case .agx: return "AgX"
        case .sigmoid: return pick(lang, zh: "Sigmoid (v1.1 平滑高光)", en: "Sigmoid (v1.1)")
        case .neutralRational: return "Neutral Rational"
        case .openDRT: return "OpenDRT"
        }
    }

    public static func mono1chLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "1ch 单色 (L008)", en: "1ch Mono (L008)")
    }

    public static func rgb3chLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "3ch 彩色 (BGRA)", en: "3ch RGB (BGRA)")
    }

    public static func rgb3chRestrictedNotice(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "JPEG + Ultra HDR XMP 模式已锁定 1ch 单色（如需 3ch 请先启用 HEIC/AVIF 或关闭 XMP）",
            en: "JPEG + Ultra HDR XMP locks 1ch Mono (enable HEIC/AVIF for 3ch RGB)"
        )
    }

    public static func halfResLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "1/2 抗光晕", en: "1/2 Anti-Halo")
    }

    public static func fullResLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "1:1 全尺寸", en: "1:1 Full Res")
    }

    public static func aspectLabel(_ aspect: AspectRatio, lang: ResolvedLanguage) -> String {
        switch aspect {
        case .original: return pick(lang, zh: "原画幅", en: "Original")
        default: return aspect.rawValue
        }
    }

    public static func maxLongEdgeLabel(_ edge: Int?, lang: ResolvedLanguage) -> String {
        if let edge {
            return "\(edge) px"
        }
        return pick(lang, zh: "原图尺寸", en: "Original Size")
    }

    public static func maxLongEdgeMenu2048(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "2048 px (小红书推荐)", en: "2048 px (Xiaohongshu)")
    }

    public static func maxLongEdgeMenu1920(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "1920 px (HLG MP4 上限)", en: "1920 px (HLG MP4 Cap)")
    }

    public static func customLongEdgeLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "自定义长边 (偶数≥64):", en: "Custom Long Edge (even >=64):")
    }

    public static func customLongEdgePlaceholder(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "原图", en: "Original")
    }

    public static func hlgMaxEdgeNotice(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "已启用 HLG MP4：长边自动限制 ≤ 1920 px（禁止 4K 防止抖音二次压缩）",
            en: "HLG MP4 active: longest edge capped at <=1920 px (4K blocked for Douyin)"
        )
    }

    // MARK: - Preview Canvas & Dual-Zone Histogram

    public static func screenEDRBadge(edr: Double, ev: Double, lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: String(format: "屏幕 EDR: %.2f× (+%.1f EV)", edr, ev),
            en: String(format: "Display EDR: %.2fx (+%.1f EV)", edr, ev)
        )
    }

    public static func iphoneSimulatorLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "iPhone 模拟:", en: "iPhone Sim:")
    }

    public static func previewModeLabel(_ mode: EDRPreviewMode, lang: ResolvedLanguage) -> String {
        switch mode {
        case .standardEDR: return pick(lang, zh: "标准 EDR", en: "Standard EDR")
        case .splitScreenSwipe: return pick(lang, zh: "分屏对比", en: "Split Compare")
        case .falseColorHeatmap: return pick(lang, zh: "假彩色热力图", en: "False Color")
        case .gainMapDirectView: return pick(lang, zh: "Gain Map [G]", en: "Gain Map [G]")
        }
    }

    public static func gainMapHelpText(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "快捷键 G：直接检视 Gain Map（单通道 L008 / 三通道 BGRA）",
            en: "Shortcut G: Inspect Gain Map directly (1ch L008 / 3ch BGRA)"
        )
    }

    public static func sdrMonitorBannerText(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "当前显示器为标准 SDR 外接屏 (EDR = 1.0×)，高光超过 0 EV 会受硬件上限限制。可开启「曝光缩放检视」按 1/H_sim 压缩全图亮度以检查高光纹理。",
            en: "External SDR monitor detected (EDR = 1.0x). Highlights >0 EV exceed display ceiling. Enable Exposure Scale (1/H) to inspect highlight texture."
        )
    }

    public static func sdrExposureScaleToggle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "曝光缩放检视 (1/H)", en: "Exposure Scale (1/H)")
    }

    public static func sdrExposureScaleCompactToggle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "曝光缩放 (1/H)", en: "Exposure Scale (1/H)")
    }

    public static func renderFailedPrefix(_ err: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "预览渲染失败: \(err)", en: "Preview render failed: \(err)")
    }

    public static func renderingFileMessage(_ fileName: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "正在解码与渲染 \(fileName)...", en: "Decoding & rendering \(fileName)...")
    }

    public static func fallbackBannerText(_ reason: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "已自动回退至 LibRaw: \(reason)", en: "Auto fallback to LibRaw: \(reason)")
    }

    public static func emptyCanvasTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "拖入索尼 .ARW 文件或文件夹开始预览", en: "Drop Sony .ARW files or folders to preview")
    }

    public static func emptyCanvasSubtitle(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "支持单张/批量导入、自动忽略 .HIF、120Hz 原生 EDR 实时调色与 ISO 21496-1 合规校验",
            en: "Single/batch .ARW import, ignores .HIF, 120Hz native EDR grading & ISO 21496-1 verification"
        )
    }

    public static func chooseARWFilesButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "选择 ARW 文件...", en: "Choose ARW Files...")
    }

    public static func chooseFolderButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "选择文件夹...", en: "Choose Folder...")
    }

    public static func splitSDRBadge(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "SDR 基准 (W=0)", en: "SDR Base (W=0)")
    }

    public static func heatmapSDRChip(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "≤0 EV SDR", en: "<=0 EV SDR")
    }

    public static func heatmapClipChip(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "裁切过曝", en: "Clipped")
    }

    public static func gainMapPill(chLabel: String, w: Int, h: Int, minV: Float, maxV: Float, gammaV: Float, lang: ResolvedLanguage) -> String {
        let prefix = pick(lang, zh: "Gain Map 直视", en: "Gain Map")
        return String(format: "%@ · %@ (%d×%d) · min=%.2f max=%.2f γ=%.2f", prefix, chLabel, w, h, minV, maxV, gammaV)
    }

    public static func measuredKelvinLabel(_ kelvin: Double, lang: ResolvedLanguage) -> String {
        pick(lang, zh: String(format: "机身测光色温: %.0fK", kelvin), en: String(format: "Camera WB: %.0fK", kelvin))
    }

    public static func previewDimensionsSuffix(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "预览", en: "Preview")
    }

    public static func histogramTitle(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "双区 HDR 直方图 (SDR [-6..0 EV] | HDR (0..+4 EV])",
            en: "Dual-Zone HDR Histogram (SDR [-6..0 EV] | HDR (0..+4 EV])"
        )
    }

    public static func histogramSimLimit(mult: Double, ev: Double, lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: String(format: "模拟上限: %.1f× (+%.1f EV)", mult, ev),
            en: String(format: "Sim Limit: %.1fx (+%.1f EV)", mult, ev)
        )
    }

    public static func histogramZeroEV(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "0 EV 漫反射白", en: "0 EV Diffuse White")
    }

    // MARK: - Export & Compliance Sheet

    public static func exportSheetTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "批量导出与 ISO/IEC 21496-1 合规校验", en: "Batch Export & ISO/IEC 21496-1 Compliance")
    }

    public static func exportSheetSubtitle(presetName: String, count: Int, lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "当前预设: \(presetName) · 队列共 \(count) 张 .ARW",
            en: "Preset: \(presetName) · \(count) .ARW item\(count == 1 ? "" : "s") queued"
        )
    }

    public static func closeButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "关闭", en: "Close")
    }

    public static func shortGuideButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "防坑指南", en: "Guide")
    }

    public static func outputFormatsGroup(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "输出格式（可多选单次解码并发扇出）", en: "Output Formats (Single-Decode Fan-Out)")
    }

    public static func baseBitDepthLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "基础色深:", en: "Base Bit Depth:")
    }

    public static func baseColorSpaceLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "基础色域:", en: "Base Color Space:")
    }

    public static func imageQualityLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "图像质量:", en: "Quality:")
    }

    public static func avifEncoderLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "AVIF 编码器:", en: "AVIF Encoder:")
    }

    public static func outputPathGroup(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "输出路径与命名规则", en: "Output Folder & Naming")
    }

    public static func chooseFolderShort(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "选择目录...", en: "Choose Folder...")
    }

    public static func formatSubdirsToggle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "按格式分子目录 (--format-subdirs: heic/ jpeg/ avif/ mp4/)", en: "Subfolders by format (heic/ jpeg/ avif/ mp4/)")
    }

    public static func namingTemplateLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "命名模板:", en: "Template:")
    }

    public static func filenamePreview(_ name: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "文件名预览: \(name)", en: "Preview: \(name)")
    }

    public static func conflictPolicyLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "同名冲突:", en: "On Conflict:")
    }

    public static func conflictPolicyName(_ policy: ConflictPolicy, lang: ResolvedLanguage) -> String {
        switch policy {
        case .overwrite: return pick(lang, zh: "覆盖", en: "Overwrite")
        case .skip: return pick(lang, zh: "跳过", en: "Skip")
        case .autoNumber: return pick(lang, zh: "自动编号", en: "Auto-Number")
        }
    }

    public static func verifyAfterExportToggle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导出后自动执行 ISO 21496-1 / HLG 合规校验", en: "Verify ISO 21496-1 / HLG compliance after export")
    }

    public static func hlgVideoSectionHeader(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "抖音 10-bit BT.2020 HLG MP4 参数 (30fps · 禁 4K)", en: "Douyin 10-bit BT.2020 HLG MP4 (30fps · Max 1080p)")
    }

    public static func videoAspectLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "视频画幅:", en: "Aspect:")
    }

    public static func videoDurationLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "时长:", en: "Duration:")
    }

    public static func videoBitrateLabel(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "码率:", en: "Bitrate:")
    }

    public static func exportProgressTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导出进度与合规徽章", en: "Export Progress & Compliance")
    }

    public static func exportSummaryText(_ s: BatchExportSummary, lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: String(format: "完成 %d/%d（失败 %d）· %.2fs", s.succeeded, s.totalJobs, s.failed, s.elapsedSeconds),
            en: String(format: "Done %d/%d (failed %d) · %.2fs", s.succeeded, s.totalJobs, s.failed, s.elapsedSeconds)
        )
    }

    public static func processingCount(done: Int, total: Int, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "正在处理 \(done) / \(total)...", en: "Processing \(done) / \(total)...")
    }

    public static func decodeFallbackRow(_ fallback: String, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "解码回退: \(fallback)", en: "Decode fallback: \(fallback)")
    }

    public static func compliancePassBadge(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "HDR 合规通过 ✅", en: "HDR Compliant ✅")
    }

    public static func complianceWarnBadge(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "警告 ⚠️", en: "Warning ⚠️")
    }

    public static func complianceFailBadge(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "HDR 合规失败 ❌", en: "Compliance Failed ❌")
    }

    public static func complianceUnverifiedBadge(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "未校验", en: "Unverified")
    }

    public static func openOutputDirButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "打开输出目录", en: "Open Output Folder")
    }

    public static func cancelExportButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "取消导出", en: "Cancel")
    }

    public static func startBatchExportButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "开始批量导出", en: "Start Batch Export")
    }

    public static func complianceVerdict(passed: Bool, lang: ResolvedLanguage) -> String {
        if passed {
            return pick(lang, zh: "校验结论: 通过 ✅", en: "Verdict: Passed ✅")
        }
        return pick(lang, zh: "校验结论: 未通过 ❌", en: "Verdict: Failed ❌")
    }

    public static func complianceMeasuredHeadroom(mult: Double, ev: Double, lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: String(format: "实测 Headroom: %.2f× (+%.2f EV)", mult, ev),
            en: String(format: "Measured Headroom: %.2fx (+%.2f EV)", mult, ev)
        )
    }

    public static func complianceBitDepth(_ depth: Int, lang: ResolvedLanguage) -> String {
        pick(lang, zh: "色深: \(depth)-bit", en: "Bit Depth: \(depth)-bit")
    }

    public static func complianceNotRun(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "此导出产物未运行自动合规探针（已关闭导出后校验）。",
            en: "Automated compliance probe was not run for this artifact (verification disabled)."
        )
    }

    // MARK: - Publishing Guide

    public static func guideTitle(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "发布与传图防坑指南", en: "HDR Publishing & Delivery Guide")
    }

    public static func guideSubtitle(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "覆盖 AirDrop / iOS 18–27 相册、小红书 Ultra HDR 与抖音必亮 HLG MP4 全链路规范",
            en: "Best practices for AirDrop / iOS 18–27 Photos, Xiaohongshu Ultra HDR, and Douyin HLG MP4"
        )
    }

    public static func guideDoneButton(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "完成", en: "Done")
    }

    public struct GuideCardContent: Sendable {
        public let title: String
        public let summary: String
        public let dos: [String]
        public let donts: [String]
    }

    public static func guideCards(lang: ResolvedLanguage) -> [GuideCardContent] {
        switch lang {
        case .zhHans:
            return [
                GuideCardContent(
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
                ),
                GuideCardContent(
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
                ),
                GuideCardContent(
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
            ]
        case .en:
            return [
                GuideCardContent(
                    title: "1. AirDrop & iPhone Photos (iOS 18–27)",
                    summary: "Native static Adaptive HDR (ISO 21496-1) in iOS 18–27 Photos intentionally shows no 'HDR' corner badge—matching iPhone camera originals.",
                    dos: [
                        "Transfer using AirDrop (keep original) or iCloud Photos sync.",
                        "Keep Settings -> Photos -> View Full HDR enabled on iPhone.",
                        "Verify the 'HDR Compliant ✅' badge and measured Headroom (e.g. 5.66x / +2.5 EV) in Chiaro.",
                        "Enable CustomRendered = 3 if you want macOS Photos smart albums to filter HDR files."
                    ],
                    donts: [
                        "Never sync photos via Finder USB 'Sync Photos' (it may recompress and drop the Gain Map).",
                        "Never enable AirDrop 'Most Compatible' or send compressed chat images (strips Gain Maps to SDR)."
                    ]
                ),
                GuideCardContent(
                    title: "2. Xiaohongshu HDR Spec (xiaohongshu_jpg)",
                    summary: "Recommended 3:4 crop, long edge <= 2048 px, <= 4 MB, 1ch L008 Ultra HDR v1.1 JPEG (Display P3 ICC + Closed-Loop SDR Compensation).",
                    dos: [
                        "AirDrop the original file to iPhone Photos and publish directly from the Xiaohongshu iOS App.",
                        "Keep a consistent aspect ratio (e.g. 3:4) across all photos in the same carousel."
                    ],
                    donts: [
                        "Do not upload via desktop web browser (Gain Map metadata is stripped).",
                        "Do not crop, filter, or add stickers in-app (client re-encoding discards ISO APP2 / XMP gain maps)."
                    ]
                ),
                GuideCardContent(
                    title: "3. Douyin Delivery (Static JPEG vs. Guaranteed HLG MP4)",
                    summary: "Douyin currently downgrades most static JPEG posts to SDR server-side. For 100% guaranteed mobile OLED HDR playback, use preset 'douyin_hlg_mp4'.",
                    dos: [
                        "For guaranteed OLED HDR: export 10-bit HEVC Main10 BT.2020 HLG MP4 (1080x1920 or 1080x1440, 3–5s, 30fps, 12–16 Mbps).",
                        "Enable 'HD Upload' inside the Douyin iOS App when uploading the HLG MP4.",
                        "When posting static photos (douyin_jpg), SDR contrast and saturation are pre-boosted to stay crisp even if stripped to SDR."
                    ],
                    donts: [
                        "Never export 4K HLG MP4 to Douyin (forced server re-encoding breaks HDR metadata; Chiaro caps long edge at <=1920 px)."
                    ]
                )
            ]
        }
    }

    // MARK: - ViewModel Messages & Prompts

    public static func msgImportPresetPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入预设 JSON", en: "Import Preset JSON")
    }

    public static func msgExportPresetPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导出预设 JSON", en: "Export Preset JSON")
    }

    public static func msgImportFilesPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入 ARW", en: "Import ARW")
    }

    public static func msgImportFolderPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入文件夹", en: "Import Folder")
    }

    public static func msgOutputDirPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "选择导出目录", en: "Choose Output Folder")
    }

    public static func msgImportDeltaPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入单图微调 Delta JSON", en: "Import Per-Photo Delta JSON")
    }

    public static func msgExportDeltaPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导出 Delta JSON", en: "Export Delta JSON")
    }

    public static func msgPickDCPPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "选择 DCP 相机配置文件", en: "Select DCP Camera Profile")
    }

    public static func msgPickCubePrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "加载 .cube LUT", en: "Load .cube LUT")
    }

    public static func msgImportLensfunPrompt(_ lang: ResolvedLanguage) -> String {
        pick(lang, zh: "导入自定义 Lensfun XML", en: "Import Custom Lensfun XML")
    }

    public static func msgNoARWFound(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "未在选定路径中找到有效的 .ARW 原始文件（已自动忽略 .HIF 及非 ARW 文件）。",
            en: "No valid Sony .ARW files found in selection (.HIF and non-ARW files are ignored)."
        )
    }

    public static func msgRGB3chRestricted(_ lang: ResolvedLanguage) -> String {
        pick(
            lang,
            zh: "纯 JPEG + Ultra HDR XMP 模式仅支持 1ch 单色 Gain Map（如需 3ch 请先启用 HEIC/AVIF 或关闭 Ultra HDR XMP）。",
            en: "JPEG + Ultra HDR XMP supports 1ch Mono Gain Maps only (enable HEIC/AVIF for 3ch RGB)."
        )
    }
}
