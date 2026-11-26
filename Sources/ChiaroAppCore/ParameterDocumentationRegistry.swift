import Foundation
import ChiaroCore

public struct ParameterDoc: Sendable, Equatable, Hashable, Identifiable {
    public let id: ParameterID
    public let title: LocalizedText
    public let shortSummary: LocalizedText
    public let controlsWhat: LocalizedText
    public let leftOrLowEffect: LocalizedText
    public let rightOrHighEffect: LocalizedText
    public let recommendedRange: LocalizedText
    public let proTip: LocalizedText

    public init(
        id: ParameterID,
        title: LocalizedText,
        shortSummary: LocalizedText,
        controlsWhat: LocalizedText,
        leftOrLowEffect: LocalizedText,
        rightOrHighEffect: LocalizedText,
        recommendedRange: LocalizedText,
        proTip: LocalizedText
    ) {
        self.id = id
        self.title = title
        self.shortSummary = shortSummary
        self.controlsWhat = controlsWhat
        self.leftOrLowEffect = leftOrLowEffect
        self.rightOrHighEffect = rightOrHighEffect
        self.recommendedRange = recommendedRange
        self.proTip = proTip
    }
}

public enum ParameterDocumentationRegistry {
    public static var allDocs: [ParameterDoc] {
        ParameterID.allCases.map(doc(for:))
    }

    public static func doc(for id: ParameterID) -> ParameterDoc {
        switch id {
        // MARK: - App & Workspace Controls

        case .workspaceMode:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "工作区模式", en: "Workspace Mode"),
                shortSummary: LocalizedText(
                    zhHans: "在预设模式与专业模式间无损切换。",
                    en: "Losslessly switch between Preset Mode and Pro Mode."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "切换简化快速调色界面（预设模式）与完整五组底层工程参数界面（专业模式），底层参数状态完全共享。",
                    en: "Switches between the streamlined Preset Mode and the full 5-group Pro Mode over a single shared parameter state."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "预设模式：展示可视化平台预设卡片、6 个常用滑块与一键镜头/降噪开关。",
                    en: "Preset Mode: visual preset cards, 6 intuitive sliders, and one-click lens/denoise toggles."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "专业模式：开放解码、去马赛克、开源光学、双支路色调映射与 Gain Map 全部精细控制。",
                    en: "Pro Mode: exposes full decode, demosaic, optics, dual-branch tone mapping, and Gain Map controls."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "日常快速出图用预设模式，精修或排查合规用专业模式（⌘⇧P）。",
                    en: "Use Preset Mode for fast publishing; Pro Mode (⌘⇧P) for precision grading."
                ),
                proTip: LocalizedText(
                    zhHans: "在专业模式调整的精细参数切换到预设模式时不会丢失，顶部会提示当前生效的专业微调项数。",
                    en: "Pro adjustments remain intact when returning to Preset Mode and are surfaced via the override pill."
                )
            )

        case .appLanguage:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "界面语言", en: "Interface Language"),
                shortSummary: LocalizedText(
                    zhHans: "切换简体中文、英文或跟随系统语言。",
                    en: "Switch between Simplified Chinese, English, or System."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "实时切换 Chiaro 界面文案、预设名称、防坑指南与参数文档的显示语言，无需重启应用。",
                    en: "Switches UI labels, preset titles, publishing guides, and parameter docs instantly without restart."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "跟随系统：自动读取 macOS 系统语言或启动参数（-AppleLanguages）。",
                    en: "Follow System: tracks macOS system language or -AppleLanguages launch flag."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "简体中文 / English：强制锁定为指定语言并持久化偏好。",
                    en: "zh-Hans / English: locks the app interface to the chosen language."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "默认跟随系统；双语对照学习 HDR 参数时可随时切换。",
                    en: "Follow System by default; toggle anytime to inspect bilingual terms."
                ),
                proTip: LocalizedText(
                    zhHans: "所有参数 ID 的文档注册表均同时覆盖中英文，切换后帮助弹窗即刻同步更新。",
                    en: "Every ParameterID entry has full bilingual docs that update live inside help popovers."
                )
            )

        case .showInlineParameterSummaries:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "行内参数说明", en: "Inline Parameter Summaries"),
                shortSummary: LocalizedText(
                    zhHans: "在滑块下方显示一行简短原理提示。",
                    en: "Show a concise one-line summary beneath each control."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "控制是否在每个参数标题下方直接展开单行简介；预设模式默认开启，专业模式默认关闭以保持紧凑。",
                    en: "Toggles one-line parameter summaries under controls (default ON in Preset Mode, OFF in Pro Mode)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：面板更紧凑，仍可随时点击参数旁的「?」按钮查看完整原理说明。",
                    en: "Off: compact layout while keeping '?' help popovers available on every control."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启：无需点击即可在调色时直接看到每个参数的用途摘要。",
                    en: "On: displays a concise explanation beneath every slider, picker, and toggle."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "新手或预设模式建议开启，高密度精修时可关闭。",
                    en: "Recommended ON in Preset Mode; OFF for compact Pro grading."
                ),
                proTip: LocalizedText(
                    zhHans: "预设模式与专业模式各自独立记忆此开关状态，互不干扰。",
                    en: "Inline summary preference is remembered independently per Workspace Mode."
                )
            )

        case .autoSaveSidecar:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "自动保存 Sidecar", en: "Auto-Save Sidecar"),
                shortSummary: LocalizedText(
                    zhHans: "将单图微调自动写入 .chiaro.json 文件。",
                    en: "Automatically save edits to sibling .chiaro.json files."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "开启后，对单张照片的任何编辑都会以原子写入方式保存到同目录 <文件名>.ARW.chiaro.json，不改动原 RAW。",
                    en: "Atomically persists per-photo edits to <raw>.chiaro.json without ever modifying the original ARW."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：仅在本次会话内存中保留修改，适合只读目录试调。",
                    en: "Off: keeps edits in memory only; safe for read-only inspection."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启（默认）：编辑后约 0.25s 防抖保存，下次导入自动无损恢复，CLI 也可直接复用。",
                    en: "On (default): debounced atomic write; auto-restored on re-import and readable by chiaro-cli."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "日常工作流保持开启；纯浏览样片时可暂时关闭。",
                    en: "Keep On for normal workflows; toggle Off when browsing read-only archives."
                ),
                proTip: LocalizedText(
                    zhHans: "被动导入或点选照片绝不会触发写入，只有真实用户编辑才会生成 .chiaro.json。",
                    en: "Passive import or selection never writes sidecars; only explicit user edits trigger saving."
                )
            )

        // MARK: - Preview Toolbar Controls

        case .previewMode:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "预览检视模式", en: "Preview Inspection Mode"),
                shortSummary: LocalizedText(
                    zhHans: "切换标准 EDR、分屏对比、热力图与 Gain Map。",
                    en: "Switch EDR, split compare, false color, or Gain Map."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "切换主画布 Metal 着色器的可视化模式，检查 SDR/HDR 动态范围、高光过曝与增益图分布。",
                    en: "Switches the Metal preview shader between Standard EDR, Split Swipe, False Color, and Gain Map."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "标准 EDR / 分屏：查看真实 HDR 观感或对比 SDR 基准（W=0）差异。",
                    en: "Standard EDR / Split: inspect true EDR appearance vs. SDR base (W=0)."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "假彩色热力图 / Gain Map [G]：定量诊断 >0 EV 高光分层与单/三通道增益图。",
                    en: "False Color / Gain Map [G]: inspect HDR headroom stops and gain map structure."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "调色用标准 EDR，查高光安全用热力图，查光晕按 G 看 Gain Map。",
                    en: "Use Standard EDR for grading, False Color for clipping, and [G] for Gain Map halos."
                ),
                proTip: LocalizedText(
                    zhHans: "分屏对比时拖动中间滑杆可实时比较左侧 SDR 基准与右侧 HDR 合成结果。",
                    en: "Drag the split handle to compare SDR base tone mapping against full HDR synthesis."
                )
            )

        case .simulatedHeadroom:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "iPhone 屏幕 Headroom 模拟", en: "iPhone Headroom Simulator"),
                shortSummary: LocalizedText(
                    zhHans: "模拟不同终端屏幕的 HDR 峰值亮度倍率。",
                    en: "Simulate playback across 1x–8x display HDR headrooms."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "以 ISO 21496-1 公式按指定线性倍率 H_sim 在预览画布实时合成，验证跨设备自适应观感。",
                    en: "Evaluates ISO 21496-1 gain map weight W at H_sim to preview SDR and mobile OLED rendering."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "1× (+0 EV)：模拟普通 SDR 屏幕或被压缩降级后的基础亮度。",
                    en: "1x (+0 EV): simulates standard SDR displays with zero HDR boost."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "4×–8× (+2..+3 EV)：模拟 iPhone XDR/ProMotion 屏幕全力点亮高光的效果。",
                    en: "4x–8x (+2..+3 EV): simulates iPhone OLED XDR peak highlight brightness."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "建议在 1×（SDR 保底）与 4×–5.6×（iPhone 常见峰值）间切换检查。",
                    en: "Check both 1x (SDR fallback) and 4x–5.6x (typical iPhone XDR headroom)."
                ),
                proTip: LocalizedText(
                    zhHans: "该控件仅影响实时预览与双区直方图虚线，不改变最终导出文件的 targetHeadroomStops。",
                    en: "Affects preview and histogram simulation only; exported headroom comes from Group 4."
                )
            )

        case .sdrExposureScaleEnabled:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "曝光缩放检视 (1/H)", en: "Exposure Scale View (1/H)"),
                shortSummary: LocalizedText(
                    zhHans: "在普通 SDR 屏幕上压缩亮度以看清 HDR 高光。",
                    en: "Scale preview by 1/H to inspect HDR highlights on SDR."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "将预览整体线性亮度除以模拟 Headroom（1/H_sim），使超出显示器物理上限的高光纹理在 SDR 屏上显形。",
                    en: "Divides linear preview luminance by H_sim so >1.0 HDR highlight detail becomes visible on SDR monitors."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：按正常漫反射白 1.0 渲染，超过当前显示器 EDR 上限的像素会被显示器裁切。",
                    en: "Off: normal 1.0 diffuse white; highlights above display EDR clip visually."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启：整体压暗以完整容纳 +2~+4 EV 高光层次，专用于外接 SDR 屏修图。",
                    en: "On: scales image down to fit +2 to +4 EV highlight detail within an SDR monitor."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "使用外接 SDR 显示器修高光时开启；在 MacBook Pro XDR 屏上保持关闭。",
                    en: "Enable on external SDR displays when checking highlights; keep Off on XDR panels."
                ),
                proTip: LocalizedText(
                    zhHans: "与假彩色热力图配合使用，可以在无 HDR 硬件屏幕上精确判断霓虹灯牌是否裁切。",
                    en: "Combine with False Color Heatmap on SDR screens to spot clipped neon or specular highlights."
                )
            )

        // MARK: - Group 1: Decode, Denoise & Open-Source Optics

        case .editScope:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "编辑作用域", en: "Edit Scope"),
                shortSummary: LocalizedText(
                    zhHans: "选择修改应用到全局预设或当前单张照片。",
                    en: "Apply edits to the active global preset or current photo."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "决定专业模式下的调色修改写入全局预设模板，还是仅写入当前选中照片的 PerPhotoDelta（并同步到 .chiaro.json）。",
                    en: "Routes Pro Mode edits either to the global active preset or to the selected photo's PerPhotoDelta."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "全局预设：批量影响队列中所有未单独覆写的照片。",
                    en: "Global Preset: affects all photos in the batch queue without per-photo overrides."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "单图微调：仅针对当前选中的 .ARW 生成独立增量覆写与 Sidecar。",
                    en: "Per-Photo Delta: isolates edits to the selected ARW and writes its .chiaro.json sidecar."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "先定全局预设基调，再切单图微调逐张精修曝光与裁剪。",
                    en: "Set overall look in Global Preset, then fine-tune individual shots in Per-Photo Delta."
                ),
                proTip: LocalizedText(
                    zhHans: "预设模式在有选中照片时自动使用单图微调，确保单张调色与 .chiaro.json 无缝保存。",
                    en: "Preset Mode automatically targets Per-Photo Delta when a photo is selected."
                )
            )

        case .decodeBackend:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "RAW 解码后端", en: "RAW Decode Backend"),
                shortSummary: LocalizedText(
                    zhHans: "选择 LibRaw 或 CIRAWv9 解码引擎。",
                    en: "Choose LibRaw open-source engine or Apple CIRAWv9."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "选择底层 RAW 解码器：LibRaw 0.22+ 支持 GPL3 高精度去马赛克与 Profiled Denoise；CIRAWv9 调用苹果神经网络引擎。",
                    en: "Selects LibRaw 0.22+ (with AMaZE/LMMSE & Profiled Denoise) or Apple CIRAWv9 (hardware ANE decode)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "LibRaw 0.22+：完整支持 5 种去马赛克、内嵌光学曲线解密与暗部线性降噪。",
                    en: "LibRaw 0.22+: enables 5 demosaic algorithms, Sony SR2 optics curves, and Profiled Denoise."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "Apple CIRAWv9：由系统框架解码与原生降噪（遇到不支持格式自动回退 LibRaw）。",
                    en: "Apple CIRAWv9: Apple native RAW decode and ANE denoise (auto-falls back to LibRaw if needed)."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "v1.1 强烈推荐默认使用 LibRaw 0.22+。",
                    en: "LibRaw 0.22+ is recommended as the primary v1.1 backend."
                ),
                proTip: LocalizedText(
                    zhHans: "选择 CIRAWv9 时，为避免重复涂抹，Stage 2A Profiled Denoise 默认自动旁路。",
                    en: "When CIRAWv9 runs, Stage 2A Profiled Denoise automatically bypasses to prevent double smoothing."
                )
            )

        case .demosaicAlgorithm:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "去马赛克算法", en: "Demosaic Algorithm"),
                shortSummary: LocalizedText(
                    zhHans: "选择 Bayer 原始像素去马赛克插值算法。",
                    en: "Select LibRaw/librtprocess Bayer demosaic algorithm."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "控制全尺寸导出时将 Bayer 原始马赛克重建为 RGB 像素的算法（AMaZE / LMMSE / DCB / DHT / AHD）。",
                    en: "Controls Bayer-to-RGB interpolation during full export (AMaZE, LMMSE, DCB, DHT, or AHD)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "AMaZE（默认）：边缘锐利度最高、抗伪色与摩尔纹极强，适合低中 ISO 风景与建筑。",
                    en: "AMaZE (default): sharpest fine detail and anti-moiré for low-to-mid ISO scenes."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "LMMSE：高 ISO 夜景专用，极大幅度抑制暗部迷宫纹与色彩噪点；DCB/DHT/AHD 为经典平衡算法。",
                    en: "LMMSE: ideal for high-ISO night scenes to suppress maze artifacts; DCB/DHT/AHD offer classic tradeoffs."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "日常 ISO ≤ 3200 用 AMaZE；ISO ≥ 6400 夜景推荐 LMMSE。",
                    en: "Use AMaZE up to ISO 3200; switch to LMMSE for ISO 6400+ night photography."
                ),
                proTip: LocalizedText(
                    zhHans: "交互预览为保证 ≤300ms 响应采用半尺寸代理，导出时将严格按此算法全尺寸解码。",
                    en: "Interactive preview uses a fast half-size proxy; full export strictly executes the chosen demosaic."
                )
            )

        case .writeCustomRenderedHDR:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "macOS HDR 筛选标记", en: "CustomRendered = 3 Tag"),
                shortSummary: LocalizedText(
                    zhHans: "写入 Exif HDR 标记便于相册筛选。",
                    en: "Write Exif CustomRendered=3 for macOS Photos filtering."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "决定是否在导出文件的 Exif 白名单中写入 CustomRendered = 3，使 macOS「照片」智能相簿能直接筛选 HDR 成品。",
                    en: "Writes standard Exif CustomRendered = 3 so Apple Photos smart albums can filter exported HDR images."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭（默认）：不写入 CustomRendered 标签，保持与常规静态 HDR 一致。",
                    en: "Off (default): omits CustomRendered tag for standard static HDR behavior."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启：写入 CustomRendered = 3（不影响 iOS 18–27 无角标原生 HDR 显示）。",
                    en: "On: sets CustomRendered = 3 without affecting iOS 18–27 native Gain Map playback."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "需要在 macOS 照片中按 HDR 分类管理时开启。",
                    en: "Enable if you organize exported photos with Apple Photos smart albums."
                ),
                proTip: LocalizedText(
                    zhHans: "该标记属于标准 Exif 2.32 白名单字段，绝不会泄露任何 Sony 私有 MakerNote。",
                    en: "Standard Exif 2.32 tag only; Sony private MakerNote (0x927C) remains strictly stripped."
                )
            )

        case .denoiseEnabled:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "高 ISO 智能降噪", en: "Profiled Smart Denoise"),
                shortSummary: LocalizedText(
                    zhHans: "在光学畸变矫正前执行传感器标定小波降噪。",
                    en: "Sensor-calibrated linear wavelet denoise before optics."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "开关 Stage 2A 线性域降噪（darktable ILCE-7CM2 标定噪声模型 + Metal GAT + 4 级 À-trous 小波 + IGAT）。",
                    en: "Toggles Stage 2A linear denoising using calibrated Sony ILCE-7CM2 Poisson-Gaussian profiles on Metal."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：完全保留原始传感器颗粒与暗部噪声。",
                    en: "Off: bypasses linear wavelet denoising and preserves raw sensor grain."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启（默认）：在光学变形插值前先去除彩噪与高亮暗噪声，避免噪点被拉伸成条纹。",
                    en: "On (default): denoises linear data strictly before optical warping to prevent noise smearing."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "建议常驻开启，低 ISO 时软件自动按标定方差轻微收敛，不伤锐度。",
                    en: "Keep On; calibrated ISO interpolation applies minimal smoothing at base ISO."
                ),
                proTip: LocalizedText(
                    zhHans: "严格位于 Stage 2B 光学矫正之前执行，以保持真实物理泊松-高斯噪声统计分布。",
                    en: "Always executes before OpticalCorrectionStage so Poisson-Gaussian noise statistics stay unwarped."
                )
            )

        case .denoiseMode:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "降噪引擎模式", en: "Denoise Engine Mode"),
                shortSummary: LocalizedText(
                    zhHans: "选择传感器小波降噪或系统 ANE 协议槽。",
                    en: "Select calibrated wavelet denoise or reserved ANE slot."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "选择 Stage 2A 降噪算法实现；v1.1 激活 Profiled Wavelet，并预留 v2 CoreML ANE 与 CIRAWv9 协议槽。",
                    en: "Selects Stage 2A algorithm: v1.1 activates Profiled Wavelet alongside frozen v2 CoreML ANE slots."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭 / CIRAWv9 ANE：关闭降噪或由 CIRAWv9 后端内置处理。",
                    en: "Off / CIRAWv9 ANE: bypasses Stage 2A or relies on Apple CIRAWv9 decode."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "Profiled Wavelet：针对 Sony α7C II 标定曲线执行 Metal 线性降噪。",
                    en: "Profiled Wavelet: runs darktable-calibrated Metal wavelet denoising for Sony α7C II."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "LibRaw 路径推荐使用 Profiled Wavelet。",
                    en: "Use Profiled Wavelet with the LibRaw decode backend."
                ),
                proTip: LocalizedText(
                    zhHans: "模式字段会按 schemaVersion=2 写入 .chiaro.json，兼容未来 v2 CoreML 神经网络降噪。",
                    en: "Persisted in schemaVersion=2 sidecars for forward compatibility with v2 neural models."
                )
            )

        case .denoiseLuminanceStrength:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "亮度降噪强度", en: "Luminance Denoise"),
                shortSummary: LocalizedText(
                    zhHans: "抑制高 ISO 暗部黑白颗粒与亮度噪点。",
                    en: "Reduce high-ISO monochrome grain in shadows and midtones."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "调节 4 级 À-trous 小波在亮度通道的 BayesShrink 阈值乘数（0–100，默认 25）。",
                    en: "Scales 4-level À-trous wavelet BayesShrink thresholding on luminance (0–100, default 25)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0–15：保留更多胶片感微颗粒，适合人像皮肤与细腻纹理。",
                    en: "0–15: retains fine natural grain and micro-texture."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "50–100：强力抹平 ISO 6400–12800 暗部噪点，但过高会减弱极细纹理。",
                    en: "50–100: strongly smooths ISO 6400–12800 shadow noise; high values soften fine detail."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 15–40（默认 25）；ISO 12800 夜景可提至 40–60。",
                    en: "15–40 for general shooting (default 25); 40–60 for ISO 12800 night scenes."
                ),
                proTip: LocalizedText(
                    zhHans: "因在广义 Anscombe 变换 (GAT) 域工作，对暗部阴影提亮后的耐受度远高于传统空间降噪。",
                    en: "Operates in Generalized Anscombe Transform space, staying clean even after heavy shadow recovery."
                )
            )

        case .denoiseChromaStrength:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "色彩降噪强度", en: "Chroma Denoise"),
                shortSummary: LocalizedText(
                    zhHans: "消除暗部红绿杂色斑块而不影响边缘锐度。",
                    en: "Suppress color blotches in shadows while keeping edges sharp."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "控制色度通道的小波去噪强度（0–100，默认 65），专门消除高感光度下的红绿/蓝黄彩噪。",
                    en: "Controls chrominance wavelet thresholding (0–100, default 65) to eliminate color speckling."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0–30：保留原始色彩像素噪点，高 ISO 暗部可能出现紫红或绿色斑点。",
                    en: "0–30: leaves raw chroma noise; high-ISO shadows may show magenta/green blotches."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "65–100：彻底清理夜拍彩色噪斑，同时几乎不损失亮度边缘清晰度。",
                    en: "65–100: removes high-ISO color mottling with minimal impact on luminance sharpness."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "默认 65 适用于绝大多数场景；极高 ISO 夜景可设 75–90。",
                    en: "Default 65 works broadly; push to 75–90 for extreme ISO night shots."
                ),
                proTip: LocalizedText(
                    zhHans: "人眼对色彩噪点比亮度颗粒敏感得多，优先提高色彩降噪而非盲目拉高亮度降噪。",
                    en: "Human vision notices chroma blotches far more than luma grain—raise chroma denoise first."
                )
            )

        case .denoiseDetailPreservation:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "降噪细节保留", en: "Denoise Detail Preservation"),
                shortSummary: LocalizedText(
                    zhHans: "在平滑噪点时保护高频边缘与纹理清晰度。",
                    en: "Protect high-frequency edges and fine texture during denoise."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "控制小波高频子带回混与边缘保护权重（0–100，默认 70），防止降噪造成塑料涂抹感。",
                    en: "Controls high-frequency detail retention (0–100, default 70) to avoid plastic smoothing."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0–30：优先极致平滑，极低光背景更纯净但细节偏柔和。",
                    en: "0–30: prioritizes smooth noise-free gradients over micro-detail."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "65–100：最大化保留建筑线条、毛发与星空点状细节。",
                    en: "65–100: preserves crisp architectural lines, hair, and fine textures."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 60–85（默认 70）。",
                    en: "Recommended 60–85 (default 70)."
                ),
                proTip: LocalizedText(
                    zhHans: "配合 LMMSE 去马赛克与 70% 左右细节保留，可在 ISO 12800 下兼顾干净与通透。",
                    en: "Pairing LMMSE demosaic with ~70 detail preservation yields clean yet crisp ISO 12800 results."
                )
            )

        case .opticsEnabled:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "自动镜头光学矫正", en: "Auto Lens Correction"),
                shortSummary: LocalizedText(
                    zhHans: "启用基于原厂曲线与 Lensfun 的光学矫正。",
                    en: "Enable embedded ARW & Lensfun optical corrections."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "总开关 Stage 2B 开源光学矫正管线：统一生成 256×192 GPU LUT，单次 Catmull-Rom 采样完成畸变、TCA 与暗角矫正。",
                    en: "Master toggle for Stage 2B open-source optics (256×192 LUT + Catmull-Rom GPU kernel in Linear Rec.2020)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：保持传感器原始几何畸变、色差与镜头暗角（某些复古镜头的暗角氛围可关闭以保留）。",
                    en: "Off: leaves native lens distortion, chromatic aberration, and vignetting untouched."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启（默认）：优先读取 .ARW 内嵌原厂曲线，缺失时自动回退 Lensfun 开源库。",
                    en: "On (default): prefers Sony ARW embedded curves and falls back to Lensfun DB automatically."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "现代变焦/大光圈镜头建议常驻开启。",
                    en: "Keep On for modern zoom and wide-aperture E-mount lenses."
                ),
                proTip: LocalizedText(
                    zhHans: "所有计算在 rgba16Float 线性 HDR 空间执行，绝不截断 >1.0 的高光峰值。",
                    en: "Executes in rgba16Float Linear Rec.2020 with zero >1.0 HDR highlight clipping."
                )
            )

        case .opticsSource:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "光学配置来源", en: "Optics Profile Source"),
                shortSummary: LocalizedText(
                    zhHans: "切换自动优先、仅 ARW 内嵌或仅 Lensfun。",
                    en: "Choose Auto, Embedded ARW curves, or Lensfun DB."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "指定光学矫正引擎：自动优先读取索尼 .ARW 加密 SubIFD 曲线，找不到时回退内置或自定义 Lensfun XML 数据库。",
                    en: "Selects Engine A (Sony SubIFD embedded curves), Engine B (Lensfun XML DB), or Auto priority."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "自动（默认）：有原厂内嵌曲线用原厂，无内嵌曲线（如老式副厂手动头）自动匹配 Lensfun。",
                    en: "Auto (default): uses embedded ARW curves when present, else falls back to Lensfun."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "仅内嵌 / 仅 Lensfun：强制锁定特定开源矫正来源用于对比或覆盖。",
                    en: "Embedded Only / Lensfun Only: forces a single open-source engine for testing or override."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "绝大多数情况下保持「自动」。",
                    en: "Keep Auto for everyday shooting."
                ),
                proTip: LocalizedText(
                    zhHans: "在全画幅 16 节点与 APS-C 11 节点模式下均可自动读取 Tamron 25-200mm A075 等 E 卡口内嵌曲线。",
                    en: "Supports both 16-node FF and 11-node APS-C Sony ARW embedded curves automatically."
                )
            )

        case .opticsDistortion:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "畸变矫正", en: "Distortion Correction"),
                shortSummary: LocalizedText(
                    zhHans: "修正广角桶形畸变与长焦枕形畸变。",
                    en: "Correct barrel and pincushion geometric distortion."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "开关基于标定多节点的几何形变映射，将弯曲的建筑直线与地平线还原平直。",
                    en: "Toggles calibrated radial distortion warping to straighten bent architectural lines and horizons."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：保留镜头原始透视形变（部分微距或鱼眼创意构图可关闭）。",
                    en: "Off: keeps uncorrected lens distortion."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启（默认）：依据焦段精确拉直边缘弯曲。",
                    en: "On (default): restores straight geometry using focal-length-specific curves."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "建筑、人像与日常摄影建议开启。",
                    en: "Keep On for architecture, portraits, and general shooting."
                ),
                proTip: LocalizedText(
                    zhHans: "严格采用已标定曲线，不提供无依据的手工 k1/k2 猜测滑块（ADR-013）。",
                    en: "Uses verified calibration curves only—never speculative manual k1/k2 sliders (ADR-013)."
                )
            )

        case .opticsAutoScale:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "自动裁边缩放", en: "Optics Auto-Scale"),
                shortSummary: LocalizedText(
                    zhHans: "畸变拉伸后自动微调缩放以消除黑边。",
                    en: "Automatically scale warped borders to eliminate black edges."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "当畸变矫正使画面边缘向内收缩时，自动计算最小安全倍率放大填满有效画幅，避免四角出现死黑像素。",
                    en: "Computes minimum safe zoom after distortion correction so inward-warped borders leave zero black corners."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：完整保留畸变矫正后的全部像素边界，枕形矫正边缘可能出现微弱黑边。",
                    en: "Off: shows full warped bounds; pincushion correction may reveal dark corners."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启（默认）：自动裁齐边缘，保证输出画面四角干净。",
                    en: "On (default): crops inward cleanly for edge-to-edge usable pixels."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "日常出图保持开启。",
                    en: "Keep On for clean borders."
                ),
                proTip: LocalizedText(
                    zhHans: "缩放直接烘焙在 256×192 统一采样 LUT 中，不会增加额外的重采样清晰度损失。",
                    en: "Baked directly into the single-pass 256×192 LUT so sharpness stays intact."
                )
            )

        case .opticsTCA:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "横向色差消除 (TCA)", en: "Chromatic Aberration (TCA)"),
                shortSummary: LocalizedText(
                    zhHans: "对齐红绿蓝通道倍率以消除边缘紫边。",
                    en: "Align R/G/B channel scaling to remove lateral color fringes."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "开关 R/G/B 三通道独立坐标偏移补偿，消除画面边缘高反差处（如树枝、霓虹灯边）的红青/紫绿边。",
                    en: "Toggles per-channel R/G/B radial LUT coordinates to remove red/cyan and blue/yellow edge fringing."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：保留镜头原始横向色差。",
                    en: "Off: leaves native lateral chromatic aberration uncorrected."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启（默认）：高精度对齐 R/B 通道至绿通道基准，边缘更纯净。",
                    en: "On (default): aligns Red and Blue channels to Green for crisp high-contrast edges."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "HDR 画面边缘高光反差大，强烈建议保持开启。",
                    en: "Strongly recommended On, especially for high-contrast HDR scenes."
                ),
                proTip: LocalizedText(
                    zhHans: "在 Catmull-Rom 双三次采样中一次完成 R/G/B 三路独立采样，几乎零额外耗时。",
                    en: "Evaluated in the same single-pass Catmull-Rom shader as distortion with negligible overhead."
                )
            )

        case .opticsVignetting:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "暗角补偿", en: "Vignetting Correction"),
                shortSummary: LocalizedText(
                    zhHans: "提亮镜头边缘失光并恢复四角均匀亮度。",
                    en: "Restore corner illumination lost to lens vignetting."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "开关基于光圈与焦距的线性域光学暗角增益补偿图（r16Float），提亮边缘失光。",
                    en: "Toggles the linear-domain radial vignetting gain map (r16Float) calibrated for focal length and aperture."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：保留自然光学暗角以突出中心主体。",
                    en: "Off: keeps natural optical corner falloff."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启（默认）：按实际拍摄光圈恢复四周亮度一致性。",
                    en: "On (default): restores uniform corner exposure according to shooting aperture."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "风光与建筑建议开启；人像可根据氛围配合强度滑块微调。",
                    en: "Keep On for landscapes; tune Vignetting Strength for portraits."
                ),
                proTip: LocalizedText(
                    zhHans: "因运行在去噪之后且处于线性空间，暗角提亮后的四角噪点已提前被 Stage 2A 清理干净。",
                    en: "Runs after Stage 2A denoise in linear space so lifted corners remain clean."
                )
            )

        case .opticsVignettingStrength:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "暗角补偿强度", en: "Vignetting Strength"),
                shortSummary: LocalizedText(
                    zhHans: "在 0%–100% 间调节暗角提亮的混合比例。",
                    en: "Blend vignetting compensation between 0% and 100%."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "平滑混合原图（0%）与 100% 物理暗角完全矫正结果（默认 100%），兼顾均匀曝光与氛围感。",
                    en: "Blends between uncorrected corners (0%) and full physical vignetting compensation (100%)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0%–40%：保留适度自然暗角聚焦视觉中心，同时减少极暗四角噪点抬升。",
                    en: "0%–40%: retains subtle natural falloff to frame the subject and limit corner noise lift."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "80%–100%：彻底拉平中心与边角亮度。",
                    en: "80%–100%: fully flattens corner illumination across the frame."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 60%–100%；高 ISO 夜景大光圈可降至 50%–75%。",
                    en: "60%–100% general; 50%–75% for wide-open high-ISO night shots."
                ),
                proTip: LocalizedText(
                    zhHans: "该调节只改变线性增益乘数，不会触发几何 LUT 重算，拖动即刻响应。",
                    en: "Adjusts a lightweight shader uniform without recomputing the 256×192 warp LUT."
                )
            )

        case .opticsLensfunLensOverride:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "Lensfun 镜头覆盖", en: "Lensfun Lens Override"),
                shortSummary: LocalizedText(
                    zhHans: "手动指定或导入自定义 Lensfun XML 镜头配置。",
                    en: "Manually pick a Lensfun lens or import custom XML."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "当 EXIF 镜头名无法自动匹配（如转接老镜头、无触点手动头）时，手动指定 Lensfun 数据库条目，或导入自定义 XML。",
                    en: "Manually selects a Lensfun profile for adapted/manual lenses without EXIF, or loads custom user XMLs."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "自动匹配：直接根据 EXIF Make/Model/LensModel 自动查找。",
                    en: "Auto Match: resolves lens directly from EXIF metadata."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "指定型号：强制按所选镜头和机身等效倍率（FF 1.0× / APS-C 1.5×）计算光学 LUT。",
                    en: "Specific Lens: forces that profile with accurate FF 1.0× / APS-C 1.5× crop factor."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "仅在无内嵌曲线或镜头名识别偏差时手动覆盖。",
                    en: "Use Auto Match unless EXIF lens name is missing or mismatched."
                ),
                proTip: LocalizedText(
                    zhHans: "导入的自定义 XML 会持久化保存在 ~/Library/Application Support/Chiaro/Lensfun/ 供 CLI 与 App 共用。",
                    en: "Imported XML files persist in ~/Library/Application Support/Chiaro/Lensfun/ for both App and CLI."
                )
            )

        // MARK: - Group 2: Shared Base Grading

        case .whiteBalanceMode:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "白平衡模式", en: "White Balance Mode"),
                shortSummary: LocalizedText(
                    zhHans: "选择按相机拍摄测定 (As-Shot) 或自定义色温。",
                    en: "Choose camera As-Shot white balance or custom Kelvin/Tint."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "切换使用相机原始白平衡乘数（As-Shot）还是在 Bradford 色彩适应矩阵下手动指定开尔文色温与色调。",
                    en: "Switches between camera As-Shot multipliers and manual Bradford-adapted Kelvin/Tint."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "按拍摄 (As-Shot)：完全忠实相机现场自动/预设白平衡测光。",
                    en: "As-Shot: uses the exact white balance multipliers recorded by the camera."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "自定义色温：解锁色温（K）与绿/洋红偏移（Tint）精细校准。",
                    en: "Custom: unlocks Kelvin temperature and Green/Magenta tint calibration."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "白平衡准确时保留 As-Shot；混合光源或夜景偏色时切自定义。",
                    en: "Keep As-Shot when neutral; switch to Custom for mixed lighting or creative warmth."
                ),
                proTip: LocalizedText(
                    zhHans: "在预设模式下直接拖动色温滑块会自动从当前估算色温起步转为自定义白平衡。",
                    en: "Dragging the Preset Mode temperature slider seeds Custom WB from the estimated scene Kelvin."
                )
            )

        case .whiteBalanceKelvin:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "色温 (Kelvin)", en: "Color Temperature (K)"),
                shortSummary: LocalizedText(
                    zhHans: "调节画面冷暖基调（2000K–15000K）。",
                    en: "Shift overall warmth and coolness from 2000K to 15000K."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "在 Linear Rec.2020 共享空间调整光源色温补偿，影响 SDR 与 HDR 两条分支的色彩平衡。",
                    en: "Adjusts scene white balance temperature in Linear Rec.2020 before SDR/HDR branching."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "2000–4500K：画面偏冷蓝，适合校正过暖的钨丝灯或营造冷峻夜景。",
                    en: "2000–4500K: cools down warm tungsten lighting or adds crisp night tones."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "6000–15000K：画面更温暖金黄，适合日落、人像肤色与阴天增暖。",
                    en: "6000–15000K: warms overcast scenes, skin tones, and golden-hour sunsets."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "日光/人像通常 5000–6200K，城市夜景 3500–4800K。",
                    en: "5000–6200K for daylight/portraits; 3500–4800K for city night scenes."
                ),
                proTip: LocalizedText(
                    zhHans: "可点击「恢复按拍摄」一键回到相机原生 As-Shot 白平衡。",
                    en: "Use 'Reset to As-Shot' anytime to restore original camera white balance."
                )
            )

        case .whiteBalanceTint:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "色调偏移 (Tint)", en: "White Balance Tint"),
                shortSummary: LocalizedText(
                    zhHans: "微调绿（负值）与洋红（正值）轴平衡。",
                    en: "Fine-tune Green (negative) to Magenta (positive) axis."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "补偿荧光灯、LED 舞台灯等非黑体光源造成的偏绿或偏品红现象（-150 至 +150）。",
                    en: "Corrects green/magenta cast caused by LED, fluorescent, or mixed artificial lighting (-150 to +150)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "负值（-150..0）：向绿色方向中和，消除画面过度的品红偏色。",
                    en: "Negative (-150..0): adds green to neutralize excessive magenta casts."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "正值（0..+150）：向洋红方向中和，消除老式灯管或树荫下的偏绿肤色。",
                    en: "Positive (0..+150): adds magenta to clean up greenish fluorescent or foliage casts."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "常规微调在 -25 至 +25 之间。",
                    en: "Typical fine-tuning stays within -25 to +25."
                ),
                proTip: LocalizedText(
                    zhHans: "仅在专业模式暴露非零 Tint 调节，保持预设模式界面精简。",
                    en: "Dedicated to Pro Mode to keep Preset Mode streamlined."
                )
            )

        case .exposureEV:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "全局曝光 (EV)", en: "Exposure (EV)"),
                shortSummary: LocalizedText(
                    zhHans: "在线性空间等比增减整张照片的亮度。",
                    en: "Adjust overall scene brightness linearly in stops (EV)."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "在线性 Rec.2020 空间乘以 2^EV，同时改变 SDR 与 HDR 分支的基准输入亮度。",
                    en: "Multiplies linear Rec.2020 scene values by 2^EV ahead of both SDR and HDR branches."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "负值（-3.0..0）：压暗画面，保护主体不过曝并沉稳暗部。",
                    en: "Negative (-3.0..0): darkens overall exposure and protects specular headroom."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "正值（0..+3.0）：提亮欠曝 RAW，释放暗部主体亮度。",
                    en: "Positive (0..+3.0): brightens underexposed RAW captures cleanly."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "建议以直方图 0 EV 漫反射白为基准，微调在 -1.0 至 +1.5 EV。",
                    en: "Typically -1.0 to +1.5 EV, anchored by the 0 EV diffuse white line."
                ),
                proTip: LocalizedText(
                    zhHans: "曝光先定主体中间调亮度，高光能撑多亮请交给目标 Headroom 与高光激励控制。",
                    en: "Set midtone brightness with Exposure EV first; shape bright highlights with Target Headroom."
                )
            )

        case .shadowRecovery:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "阴影恢复", en: "Shadow Recovery"),
                shortSummary: LocalizedText(
                    zhHans: "单独提亮暗部细节而不推高高光。",
                    en: "Lift shadow detail selectively without blowing highlights."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "基于对数平滑区域的暗部提亮曲线（0–100），精准拉起逆光与夜景暗部纹理。",
                    en: "Applies a smooth log-domain shadow lift (0–100) to reveal backlit and night-scene details."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0：保持原始暗部反差与深沉阴影。",
                    en: "0: preserves native shadow depth and contrast."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "40–100：大幅显现背光建筑、人脸阴影与暗角纹理。",
                    en: "40–100: opens up deep shadows in backlit subjects and night photography."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "大光比逆光推荐 15–55；过度拉高（>75）可能导致画面偏平。",
                    en: "15–55 for high-contrast scenes; above 75 can flatten natural depth."
                ),
                proTip: LocalizedText(
                    zhHans: "得益于 Stage 2A 提前在光学矫正前降噪，Sony α7C II 提亮阴影 40–60 依然细腻干净。",
                    en: "Because Stage 2A denoises early, lifting shadows 40–60 on α7C II files stays remarkably clean."
                )
            )

        case .blackPoint:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "黑位 (Black Point)", en: "Black Point"),
                shortSummary: LocalizedText(
                    zhHans: "设定极暗部黑电平的深沉程度或空气感。",
                    en: "Set deepest shadow black level for punch or airy fade."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "微调接近 0.0 的深黑阴影基底（-100 至 +100），收紧黑位可增加通透感，抬高黑位可营造胶片灰调。",
                    en: "Shifts the deepest shadow floor (-100 to +100) for punchy contrast or soft lifted blacks."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "负值（-100..0）：压实最暗阴影至纯黑，消除灰雾、提升通透度。",
                    en: "Negative (-100..0): deepens blacks and removes shadow haze for crisp contrast."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "正值（0..+100）：轻微垫高黑位，呈现柔和的胶片空气感。",
                    en: "Positive (0..+100): lifts black floor for a softer, matte film feel."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "通透风光/夜景常用 -20 至 0；胶片模拟可用 +5 至 +20。",
                    en: "-20 to 0 for punchy scenes; +5 to +20 for soft filmic aesthetics."
                ),
                proTip: LocalizedText(
                    zhHans: "先调阴影恢复找回细节，再用黑位 -10 左右定住最暗点，画面既通透又不丢层次。",
                    en: "Lift details with Shadow Recovery first, then anchor blacks near -10 for rich depth."
                )
            )

        case .clarity:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "无光晕清晰度 (Clarity)", en: "Halo-Free Clarity"),
                shortSummary: LocalizedText(
                    zhHans: "增强中频局部反差与质感且无黑白光晕。",
                    en: "Enhance midtone local contrast and texture without halos."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "在 Linear Rec.2020 空间运行边缘保持局部反差引擎（-100 至 +100），只强化结构而不产生难看的白边黑边。",
                    en: "Runs an edge-aware local contrast engine (-100 to +100) in Linear Rec.2020 without halo artifacts."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "负值（-100..0）：柔化皮肤与局部微反差，带来梦幻柔焦感。",
                    en: "Negative (-100..0): softens midtone micro-contrast for flattering skin or dreamy glow."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "正值（0..+100）：立体突出砖墙、金属、云层与水面质感。",
                    en: "Positive (0..+100): adds crisp three-dimensional punch to architecture, clouds, and textures."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "风光建筑 +10 至 +35；人像 -15 至 +10。",
                    en: "+10 to +35 for landscapes/architecture; -15 to +10 for portraits."
                ),
                proTip: LocalizedText(
                    zhHans: "算法感知高反差边缘边界，即使在 HDR 霓虹灯或剪影边缘也不会出现光晕。",
                    en: "Edge-aware weighting prevents halos even around bright HDR neon signs and silhouettes."
                )
            )

        case .opticalSharpness:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "物理光学锐化", en: "Optical Sharpness"),
                shortSummary: LocalizedText(
                    zhHans: "基于反扩散物理模型恢复镜头光学微反差。",
                    en: "Physical inverse-diffusion sharpening restoring lens bite."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "移植自 darktable diffuse-or-sharpen 热扩散逆运算（0–100），抑制低光噪点放大与 USM 锯齿振铃。",
                    en: "Applies darktable-inspired inverse-diffusion sharpening (0–100) without USM ringing or noise boost."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0：保持去马赛克后的原始光学锐度。",
                    en: "0: retains native demosaic sharpness."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "30–100：显著恢复镜头衍射或微焦软导致的细节轮廓。",
                    en: "30–100: restores crisp micro-contrast lost to diffraction or optical softness."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 15–45；搭配 AMaZE 去马赛克 25 左右即可极其锐利。",
                    en: "15–45 recommended; ~25 paired with AMaZE delivers crisp natural detail."
                ),
                proTip: LocalizedText(
                    zhHans: "采用自适应噪声门限约束，夜间天空平滑区域不会被锐化出麻点。",
                    en: "Includes adaptive gradient clamping so smooth night skies are not speckled by sharpening."
                )
            )

        case .vibrance:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "自然饱和度 (Vibrance)", en: "Vibrance"),
                shortSummary: LocalizedText(
                    zhHans: "智能提升低饱和色彩并保护肤色与高饱和区域。",
                    en: "Boost muted colors while protecting skin tones and clipping."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "对低饱和色优先增益、对已高饱和及肤色自动衰减保护（-100 至 +100），避免色彩溢出。",
                    en: "Selectively boosts muted colors (-100 to +100) while attenuating already-saturated hues and skin tones."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "负值（-100..0）：减弱整体色彩鲜艳度，走向素雅冷淡色调。",
                    en: "Negative (-100..0): mutes color intensity toward understated desaturated tones."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "正值（0..+100）：让灰暗的天空、草木与霓虹环境色更通透饱满。",
                    en: "Positive (0..+100): enriches dull skies and foliage without blowing out reds or yellows."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "日常推荐 +5 至 +25。",
                    en: "Typical range +5 to +25."
                ),
                proTip: LocalizedText(
                    zhHans: "广色域 Display P3 / Rec.2020 下用 Vibrance 比硬拉 Saturation 更不容易导致边缘色块。",
                    en: "In wide-gamut P3/Rec.2020 HDR workflows, Vibrance avoids gamut clipping far better than raw Saturation."
                )
            )

        case .highlightReconstruction:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "高光重构", en: "Highlight Reconstruction"),
                shortSummary: LocalizedText(
                    zhHans: "修复单通道裁切过曝导致的品红偏色。",
                    en: "Repair clipped sensor channels and eliminate magenta casts."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "当高光灯牌或天空部分通道达到传感器饱和上限时，利用未裁切通道重建色彩；v1.1 升级 darktable opposedInpaint。",
                    en: "Reconstructs clipped sensor channels; v1.1 upgrades opposedInpaint to darktable's median chrominance strategy."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "Opposed Inpaint（默认）：消除过曝灯牌与车灯的洋红伪色同时保留高光色彩过渡。",
                    en: "Opposed Inpaint (default): eliminates magenta clipping artifacts while preserving highlight hue."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "Blend / Rebuild：在通道混合或邻域扩散之间切换重构策略。",
                    en: "Blend / Rebuild: alternative clipping recovery strategies."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "夜景霓虹与逆光天空推荐始终保持 Opposed Inpaint。",
                    en: "Keep Opposed Inpaint for night neon lights and bright skies."
                ),
                proTip: LocalizedText(
                    zhHans: "v1.1 升级的 Opposed Inpaint 专门根治索尼高 ISO 过曝点光源边缘洋红伪色问题。",
                    en: "v1.1 Opposed Inpaint directly eliminates magenta highlights common in clipped bright night sources."
                )
            )

        case .cameraProfile:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "相机色彩配置", en: "Camera Color Profile"),
                shortSummary: LocalizedText(
                    zhHans: "选择标准矩阵、索尼外观或 DCP 配置。",
                    en: "Choose Standard Matrix, Sony Creative Look, or DCP file."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "定义从传感器原始色彩空间到 Linear Rec.2020 的基础显色风格，支持索尼 ST/VV/FL/NT/BW 等创意外观或外部 .dcp。",
                    en: "Sets Camera-to-Rec.2020 color rendering: Standard D65, Sony Creative Looks (ST/VV/FL/etc.), or custom .dcp."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "标准 (D65)：中性精准的原厂色彩矩阵，最忠实还原现场。",
                    en: "Standard (D65): neutral, color-accurate matrix baseline."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "Creative Look / .dcp：注入 FL 胶片感、VV 鲜明或自定义相机色彩特性。",
                    en: "Creative Look / .dcp: applies Sony Creative Look curves or external DCP camera profiles."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "通用建议标准 (D65) 或 FL / ST；人像可试 PT。",
                    en: "Standard (D65), ST, or FL for general use; PT for portraits."
                ),
                proTip: LocalizedText(
                    zhHans: "所有 Creative Look 与 DCP 变换均保持线性高亮延展，不裁切 HDR 峰值。",
                    en: "All Creative Looks and DCP transforms preserve extended HDR linear values above 1.0."
                )
            )

        case .cubeLUT:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "3D/1D .cube LUT", en: "3D/1D .cube LUT"),
                shortSummary: LocalizedText(
                    zhHans: "加载外部 .cube 调色查找表并平滑外插 HDR。",
                    en: "Load an external .cube LUT with smooth HDR extrapolation."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "在共享线性分级阶段加载自定义 1D/3D .cube 文件；对 >1.0 的 HDR 高光采用亮度比例延展以保留高光。",
                    en: "Applies a custom 1D/3D .cube LUT in shared grading with luminance-preserving extrapolation above 1.0."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "未加载：直接输出原生色彩流水线。",
                    en: "None: passes ungraded camera profile colors straight through."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "已加载：按所选 .cube 赋予电影感或个人调色风格。",
                    en: "Loaded: applies your custom film emulation or look LUT."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "适用于加载工作流统一风格 LUT；加载后注意检查假彩色是否异常。",
                    en: "Use clean grading LUTs and verify highlight smoothness in False Color mode."
                ),
                proTip: LocalizedText(
                    zhHans: "Chiaro 对超出 [0,1] 的 HDR 高光自动执行安全外插，不会像普通 SDR 软件那样截断高光。",
                    en: "Unlike SDR-only apps, Chiaro extrapolates >1.0 values cleanly instead of clipping HDR peaks."
                )
            )

        // MARK: - Group 3: SDR Base Branch

        case .sdrToneMapper:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "SDR 色调映射器", en: "SDR Tone Mapper"),
                shortSummary: LocalizedText(
                    zhHans: "选择将线性 HDR 压缩到基础 SDR 图层的映射算法。",
                    en: "Select the curve mapping HDR scene data to the SDR base."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "仅作用于 Gain Map 下方的 SDR 基础图像分支，支持 AgX、Sigmoid（v1.1）、Neutral Rational 与 OpenDRT。",
                    en: "Controls the SDR base image branch only: AgX, Sigmoid (v1.1 darktable port), Neutral Rational, or OpenDRT."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "AgX / Neutral Rational：自然过渡高光色彩与精确中性白平衡。",
                    en: "AgX / Neutral Rational: smooth highlight desaturation or exact neutral hue preservation."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "Sigmoid / OpenDRT：v1.1 广义对数-逻辑斯蒂曲线，高光肤色与霓虹平滑度极佳。",
                    en: "Sigmoid / OpenDRT: v1.1 log-logistic S-curve with rich contrast and clean highlight rolloff."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "通用默认 AgX；夜景霓虹与人像强推尝试 Sigmoid。",
                    en: "AgX as solid default; try Sigmoid for neon night scenes and portraits."
                ),
                proTip: LocalizedText(
                    zhHans: "由于 Gain Map 以真实目标 HDR 为参考合成，切换 SDR 色调映射器不会破坏 iPhone 上的 HDR 亮部，只优化 SDR 兼容观感。",
                    en: "Gain Map synthesis compensates automatically so HDR appearance stays faithful while SDR base improves."
                )
            )

        case .sdrExposureEV:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "SDR 独立曝光", en: "SDR Independent Exposure"),
                shortSummary: LocalizedText(
                    zhHans: "仅微调基础 SDR 层的亮度而不影响 HDR 峰值。",
                    en: "Adjust SDR base brightness without altering HDR targets."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "在 SDR 色调映射前独立偏移曝光（-1.0 至 +1.0 EV），专门调节不支持 HDR 的旧设备或缩略图观感。",
                    en: "Offsets exposure (-1.0 to +1.0 EV) exclusively on the SDR base branch before tone mapping."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "负值：压暗 SDR 基础图，同时 Gain Map 会相应记录更大增益差。",
                    en: "Negative: darkens SDR base while Gain Map widens headroom ratio to compensate."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "正值：让普通 SDR 屏用户看到更明亮的中间调。",
                    en: "Positive: brightens SDR base for viewers on non-HDR screens."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "建议维持 -0.25 至 +0.25 EV 以保持 SDR 与 HDR 一致性。",
                    en: "Keep within -0.25 to +0.25 EV so SDR and HDR stays cohesive."
                ),
                proTip: LocalizedText(
                    zhHans: "使用分屏对比或模拟 1× 即可直观看到本滑块对 SDR 基础层的作用。",
                    en: "Preview changes clearly using 1x Headroom simulation or Split Screen mode."
                )
            )

        case .sdrHighlightCompression:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "SDR 高光压缩", en: "SDR Highlight Compression"),
                shortSummary: LocalizedText(
                    zhHans: "控制 SDR 基础层中高光的滚落压缩力度。",
                    en: "Control highlight rolloff strength in the SDR base layer."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "调节 SDR 分支对 0 EV 以上高亮场景的压缩比例（0–100），决定 SDR 图保留多少云层与灯光细节。",
                    en: "Adjusts SDR highlight shoulder compression (0–100) to retain sky and specular detail in SDR fallback."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0–30：高光在 SDR 中更明亮清脆，但极亮处较早接近纯白。",
                    en: "0–30: punchier SDR highlights with earlier rolloff to white."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "60–100：将极多高光纹理压入 SDR 可见范围。",
                    en: "60–100: compresses deep HDR detail firmly into SDR range."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 45–65（默认 50）。",
                    en: "Recommended 45–65 (default 50)."
                ),
                proTip: LocalizedText(
                    zhHans: "若开启「闭环 SDR 补偿」，可防止在小红书/抖音 JPEG 重压缩下 SDR 高光突然死白。",
                    en: "Works with Closed-Loop SDR Compensation to preserve highlight detail after social JPEG compression."
                )
            )

        case .sdrContrast:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "SDR 反差", en: "SDR Contrast"),
                shortSummary: LocalizedText(
                    zhHans: "专调 SDR 基础层的对比度，防止被平台降级后发灰。",
                    en: "Tune SDR base contrast so fallback views never look flat."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "以中灰为支点仅调整 SDR 基础分支的反差（-100 至 +100），使社交平台即便剥离 Gain Map 仍有良好反差。",
                    en: "Adjusts midtone contrast (-100 to +100) strictly on the SDR base image around middle gray."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "负值：降低 SDR 对比度，呈现柔和低反差。",
                    en: "Negative: softens SDR contrast for a gentle look."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "正值：增强 SDR 立体感，抖音图文等预设会适当增加此值防发灰。",
                    en: "Positive: adds crispness to SDR fallback (used by Douyin JPG preset)."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 -10 至 +25。",
                    en: "Recommended -10 to +25."
                ),
                proTip: LocalizedText(
                    zhHans: "因为只修改 SDR 支路，iPhone HDR 点亮时的真实动态范围和明暗关系完全不受影响。",
                    en: "Leaves the true HDR branch untouched while optimizing SDR fallback appearance."
                )
            )

        case .sdrSaturation:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "SDR 饱和度", en: "SDR Saturation"),
                shortSummary: LocalizedText(
                    zhHans: "微调 SDR 基础层的色彩饱和度。",
                    en: "Fine-tune color saturation of the SDR base layer."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "补偿部分高光压缩算法带来的轻微退色，仅作用于 SDR 基础层（-100 至 +100）。",
                    en: "Adjusts SDR base branch color saturation (-100 to +100) to offset tone-curve desaturation."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "负值：降低 SDR 彩度。",
                    en: "Negative: reduces SDR base saturation."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "正值：让 SDR 色彩更鲜活饱满。",
                    en: "Positive: enriches SDR base colors."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 -5 至 +20。",
                    en: "Recommended -5 to +20."
                ),
                proTip: LocalizedText(
                    zhHans: "在 3ch 彩色 Gain Map 模式下，即使 SDR 饱和度略微偏高或偏低，HDR 色彩也会被精确还原。",
                    en: "With 3ch RGB Gain Maps, HDR color remains accurate regardless of moderate SDR saturation tweaks."
                )
            )

        // MARK: - Group 4: HDR & Gain Map Engine

        case .targetHeadroomStops:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "目标 Headroom (EV)", en: "Target Headroom (EV)"),
                shortSummary: LocalizedText(
                    zhHans: "设定 HDR 高光相对漫反射白的最高亮度档数。",
                    en: "Set peak HDR highlight stops above diffuse white."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "控制导出 ISO 21496-1 / HLG 成品的目标动态范围上限（预设模式 1.0–3.5 EV，专业模式可达 +4.0 EV）。",
                    en: "Sets target HDR peak headroom above diffuse white (1.0–3.5 EV in Preset Mode; up to +4.0 EV in Pro Mode)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "1.0–1.5 EV (2×–2.8×)：克制温和的微 HDR，观感极其自然耐看。",
                    en: "1.0–1.5 EV (2x–2.8x): subtle, restrained HDR luminance."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "2.5–4.0 EV (5.6×–16×)：强烈通透的阳光金属反光、烟花与霓虹刺眼亮感。",
                    en: "2.5–4.0 EV (5.6x–16x): radiant sunlight speculars, fireworks, and neon punch."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "日常推荐 +2.0 至 +3.0 EV（iPhone 相册最佳平衡）。",
                    en: "+2.0 to +3.0 EV is the sweet spot for iPhone XDR and social feeds."
                ),
                proTip: LocalizedText(
                    zhHans: "在预设模式拖动此滑块会按联动曲线同步微调高光激励；在专业模式中两者可完全独立控制。",
                    en: "In Preset Mode this slider couples smoothly with Highlight Excitation; Pro Mode decouples both."
                )
            )

        case .midtoneAnchorP:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "中灰锁定锚点 P", en: "Midtone Anchor P"),
                shortSummary: LocalizedText(
                    zhHans: "锁定低于阈值 P 的中间调与暗部在 HDR 下不变亮。",
                    en: "Pin midtones below threshold P to match SDR exactly."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "控制线性值 ≤ P 的区域 Gain Map 严格保持 1.0（0 增益），确保皮肤、树叶、地面在 HDR 亮起时不会跟着漂白。",
                    en: "Locks gain = 1.0 for pixels below anchor P (0.65–0.95) so midtones and skin stay identical across SDR/HDR."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0.65–0.75：更早的线性高光起跳点，亮部金属和浅色云朵也会获得 HDR 增益。",
                    en: "0.65–0.75: lower threshold; bright clouds and highlights begin lifting earlier."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "0.85–0.95：严格只点亮最顶尖的灯源与反光，中间调绝对稳如磐石。",
                    en: "0.85–0.95: restricts HDR boost strictly to top specular highlights."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 0.78–0.85（默认 0.80）。",
                    en: "Recommended 0.78–0.85 (default 0.80)."
                ),
                proTip: LocalizedText(
                    zhHans: "这是 Chiaro「中灰锁定」核心公式的关键参数：人像肤色永远不会因为打开 HDR 而发亮发飘。",
                    en: "Core to Chiaro's Midtone-Lock math: skin tones remain rock-solid when HDR headroom engages."
                )
            )

        case .hdrHighlightExcitation:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "HDR 高光激励", en: "HDR Highlight Excitation"),
                shortSummary: LocalizedText(
                    zhHans: "调节超过锚点 P 后 HDR 亮度爬升的斜率与饱满度。",
                    en: "Control how aggressively highlights ramp toward peak HDR."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "控制从漫反射白到目标 Headroom 之间高光区域的能量激励曲线（0–100），决定亮部有多快达到峰值。",
                    en: "Shapes the energy curve (0–100) between diffuse white and peak headroom."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0–35：高光渐进柔和，只有极小的高光点达到满载亮度。",
                    en: "0–35: gentle highlight lift; only extreme peaks approach max headroom."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "65–100：高光迅速饱满点亮，画面更具视觉冲击力。",
                    en: "65–100: bold, energetic HDR highlight expansion."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 45–80（默认 60）。",
                    en: "Recommended 45–80 (default 60)."
                ),
                proTip: LocalizedText(
                    zhHans: "若在热力图中看到大面积洋红过曝裁切，适当降低高光激励并柔和肩部即可找回细节。",
                    en: "If False Color shows large pink clipped regions, lower excitation slightly to recover texture."
                )
            )

        case .hdrRolloffSoftness:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "HDR 肩部柔化", en: "HDR Rolloff Softness"),
                shortSummary: LocalizedText(
                    zhHans: "平滑 HDR 极高光向目标上限收敛的过渡肩部。",
                    en: "Soften the highlight shoulder approaching peak headroom."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "控制有理肩部函数（Rational Shoulder）的平滑系数（0–100），防止高光直撞天花板造成断层。",
                    en: "Adjusts the rational shoulder smoothness (0–100) approaching target headroom to prevent hard clipping."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0–30：高光接近峰值时较硬朗，保留最强刺眼感。",
                    en: "0–30: crisper, steeper highlight saturation near peak."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "60–100：如奶油般平滑收束高光，灯芯与太阳边缘过渡自然无断阶。",
                    en: "60–100: silky highlight rolloff around bulbs, neon, and solar discs."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "推荐 40–75（默认 50）。",
                    en: "Recommended 40–75 (default 50)."
                ),
                proTip: LocalizedText(
                    zhHans: "全精度浮点有理肩部函数保证了无论 Target Headroom 设为 +2 EV 还是 +4 EV 均严格有界。",
                    en: "Guarantees mathematically bounded output whether Target Headroom is +2 EV or +4 EV."
                )
            )

        case .gainMapChannels:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "Gain Map 通道", en: "Gain Map Channels"),
                shortSummary: LocalizedText(
                    zhHans: "选择 1ch 单色或 3ch 彩色增益图。",
                    en: "Choose 1ch monochrome L008 or 3ch RGB Gain Map."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "选择辅助增益图是记录单通道亮度比值（1ch）还是独立 RGB 三通道色彩增益（3ch）。",
                    en: "Selects single-channel luminance gain (1ch) vs. full RGB per-channel gain (3ch)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "1ch 单色 (L008)：体积更小、兼容 Ultra HDR XMP 与旧版 Apple HDRGainMap。",
                    en: "1ch Mono (L008): compact size and required for Ultra HDR XMP & legacy Apple compatibility."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "3ch 彩色 (BGRA)：最高色彩保真度，精确还原饱和霓虹与日落渐变的 HDR 色相。",
                    en: "3ch RGB: highest chromatic fidelity for saturated neon and sunset HDR gradients."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "HEIC / AVIF 推荐 3ch；纯 JPEG Ultra HDR 必须用 1ch。",
                    en: "Use 3ch for HEIC/AVIF; pure JPEG with Ultra HDR XMP requires 1ch."
                ),
                proTip: LocalizedText(
                    zhHans: "Chiaro 会自动强制执行格式合规护栏，防止出现非法 3ch+XMP 组合。",
                    en: "Compliance guardrails automatically enforce 1ch whenever Ultra HDR XMP or legacy dual-write is active."
                )
            )

        case .gainMapResolution:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "Gain Map 分辨率", en: "Gain Map Resolution"),
                shortSummary: LocalizedText(
                    zhHans: "选择 1/2 抗光晕采样或 1:1 全尺寸增益图。",
                    en: "Select 1/2 anti-halo resolution or 1:1 full resolution."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "设定导出辅助增益图的宽高比：1/2 采用 4×4 物理防光晕双线性降采样；1:1 保留全像素精度。",
                    en: "Sets Gain Map dimensions: Half uses 4×4 anti-halo downsampling; Full matches base image 1:1."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "1/2 抗光晕（默认）：文件显著更小，且平滑边界可抑制暗边强光晕。",
                    en: "1/2 Half (default): smaller files and smoother high-contrast gain transitions."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "1:1 全尺寸：点对点细微高光丝毫毕现，适合极端细节归档。",
                    en: "1:1 Full: pixel-exact gain map for archival detail."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "95% 场景推荐 1/2 抗光晕。",
                    en: "Half resolution is recommended for almost all workflows."
                ),
                proTip: LocalizedText(
                    zhHans: "按 G 键进入 Gain Map 直视即可观察 1/2 与 1:1 边界细节差异。",
                    en: "Press [G] to inspect the Gain Map directly and compare Half vs. Full edge transitions."
                )
            )

        case .gainMapGamma:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "Gain Map Gamma", en: "Gain Map Gamma"),
                shortSummary: LocalizedText(
                    zhHans: "调整增益图 8-bit 编码伽马精度。",
                    en: "Set ISO 21496-1 gain map encoding gamma for quantization."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "定义 8-bit 增益图存储对数比值时的非线性伽马曲线（0.25–4.0），优化高光或低增益区的量化步阶。",
                    en: "Controls non-linear encoding gamma (0.25–4.0) for 8-bit Gain Map quantization precision."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "< 1.0：将更多编码色阶分配给较高增益区域。",
                    en: "< 1.0: allocates finer quantization steps to stronger highlight gain."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "> 1.0：将更多编码色阶分配给接近 0 增益的微弱过渡区。",
                    en: "> 1.0: allocates finer steps near the midtone transition threshold."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "标准流程保持 1.00。",
                    en: "Keep 1.00 for standard ISO 21496-1 workflows."
                ),
                proTip: LocalizedText(
                    zhHans: "该值会严格写入 ISO 21496-1 二进制 tmap 元数据，确保解码端数学精确还原。",
                    en: "Written verbatim into ISO 21496-1 tmap metadata so decoders invert it losslessly."
                )
            )

        case .closedLoopSDRCompensation:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "JPEG 闭环 SDR 补偿", en: "Closed-Loop SDR Compensation"),
                shortSummary: LocalizedText(
                    zhHans: "先模拟 JPEG 有损压缩再反算 Gain Map。",
                    en: "Synthesize Gain Map from actual JPEG-decoded pixels."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "在编码 JPEG Gain Map 前，先将 SDR 基底图经 libjpeg-turbo 实际编解码一次，再用真实解码像素反推增益图。",
                    en: "Round-trips the SDR JPEG through actual lossy compression before computing Gain Map ratios."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭：按内存无损 SDR 纹理计算 Gain Map，速度快但 JPEG 块效应处可能有微小色差。",
                    en: "Off: computes Gain Map from uncompressed SDR texture."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启：消除 JPEG 8×8 DCT 压缩误差导致的 HDR 还原偏差（小红书/抖音 JPG 预设默认开启）。",
                    en: "On: eliminates JPEG quantization mismatch in HDR playback (default for social JPG presets)."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "导出 HDR JPEG 时强烈建议开启。",
                    en: "Recommended On whenever exporting Ultra HDR JPEG."
                ),
                proTip: LocalizedText(
                    zhHans: "若单张高对比度夜景 JPEG 边缘出现细小块状噪声，开启闭环补偿可显著改善。",
                    en: "Prevents mosquito/block artifacts in JPEG highlight gradients when boosted back to HDR."
                )
            )

        case .writeLegacyAppleHDRGainMap:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "兼容 iOS 14–17 双写", en: "Legacy iOS 14–17 Dual-Write"),
                shortSummary: LocalizedText(
                    zhHans: "双写旧版 Apple HDRGainMap 兼容。",
                    en: "Dual-write legacy Apple HDRGainMap alongside ISO tmap."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "在写入现代 ISO 21496-1 tmap 的同时双写旧版 AppleMakerNote HDRGainMap，并自动锁定 1ch 单色增益图。",
                    en: "Writes legacy Apple HDRGainMap metadata alongside ISO tmap and automatically enforces 1ch mono gain map."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "关闭（默认）：原生面向 iOS 18–27 与现代浏览器，支持 3ch 高精度彩色 Gain Map。",
                    en: "Off (default): pure ISO 21496-1 targeting iOS 18–27 with optional 3ch RGB Gain Map."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "开启：兼顾旧款 iOS 14–17 与 macOS 11–14 设备显示 HDR。",
                    en: "On: adds compatibility with older iOS 14–17 and macOS 11–14 devices."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "仅需兼容老设备分享时开启。",
                    en: "Enable only when targeting legacy iOS 14–17 viewers."
                ),
                proTip: LocalizedText(
                    zhHans: "开启时 Chiaro 会严格遵守规范：锁定 mono1ch 并固定 gainMapMin=0、gainMapMax=log2(H)。",
                    en: "Automatically locks mono1ch and bounds [0, log2(H)] as required by legacy Apple specs."
                )
            )

        // MARK: - Group 5: Composition & Output Guardrails

        case .cropAspect:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "画幅比例", en: "Crop Aspect Ratio"),
                shortSummary: LocalizedText(
                    zhHans: "裁剪输出画幅比例并支持物理方向烘焙。",
                    en: "Crop output aspect ratio with Orientation=1 baking."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "设定导出画幅（原画幅、3:4、4:5、1:1、4:3、9:16），在 Metal GPU 上随 Orientation=1 物理旋转一次完成。",
                    en: "Selects target aspect ratio (Original, 3:4, 4:5, 1:1, 4:3, 9:16) baked with Orientation=1."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "原画幅：保留相机传感器 3:2 原始长宽比。",
                    en: "Original: preserves the native sensor aspect ratio."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "3:4 / 9:16 等：完美契合小红书竖图与抖音全屏规范。",
                    en: "3:4 / 9:16 / etc.: fits Xiaohongshu portrait cards and Douyin vertical frames."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "小红书推荐 3:4；抖音动态图推荐 9:16 或 3:4。",
                    en: "3:4 for Xiaohongshu; 9:16 or 3:4 for Douyin."
                ),
                proTip: LocalizedText(
                    zhHans: "裁剪后直接重算输出，禁止依赖 Exif Orientation 旋转，杜绝社交平台转正丢失 Gain Map。",
                    en: "Pixels are physically oriented to Orientation=1 so social apps never misalign the Gain Map."
                )
            )

        case .cropOffsetX:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "裁剪中心 X", en: "Crop Center X"),
                shortSummary: LocalizedText(
                    zhHans: "左右平移裁剪取景框中心点。",
                    en: "Pan crop window horizontally (0.0 left to 1.0 right)."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "当画幅比例不是原画幅且横图裁竖图时，调节取景框水平归一化中心（0.0–1.0，默认 0.50）。",
                    en: "Shifts the normalized horizontal center (0.0–1.0, default 0.50) when cropping."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0.0：取景框尽可能靠左对齐。",
                    en: "0.0: aligns crop window toward the left edge."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "1.0：取景框尽可能靠右对齐。",
                    en: "1.0: aligns crop window toward the right edge."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "保持主体处于黄金分割或居中（0.33 / 0.50 / 0.67）。",
                    en: "Place subject near 0.33, 0.50, or 0.67."
                ),
                proTip: LocalizedText(
                    zhHans: "单张裁剪中心点会自动记录在每张图的 .chiaro.json 中。",
                    en: "Per-photo crop framing is preserved automatically in .chiaro.json."
                )
            )

        case .cropOffsetY:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "裁剪中心 Y", en: "Crop Center Y"),
                shortSummary: LocalizedText(
                    zhHans: "上下平移裁剪取景框中心点。",
                    en: "Pan crop window vertically (0.0 top to 1.0 bottom)."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "当画幅比原画幅更扁（如 4:3）时，调节取景框垂直归一化中心（0.0–1.0，默认 0.50）。",
                    en: "Shifts the normalized vertical center (0.0–1.0, default 0.50) when cropping."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "0.0：取景框靠上，保留更多天空。",
                    en: "0.0: shifts crop toward the top edge."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "1.0：取景框靠下，保留更多前景。",
                    en: "1.0: shifts crop toward the bottom edge."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "默认居中 0.50，按构图微调。",
                    en: "Default 0.50 centered; adjust for headroom or foreground."
                ),
                proTip: LocalizedText(
                    zhHans: "结合实时 Metal 预览画布，可毫秒级即时定位最佳构图。",
                    en: "Updates live on the GPU canvas with zero decode overhead."
                )
            )

        case .maxLongEdge:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "最大长边保护", en: "Max Long Edge Guardrail"),
                shortSummary: LocalizedText(
                    zhHans: "限制导出长边像素以防平台强压或超限。",
                    en: "Cap output longest dimension to avoid platform recompression."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "在 Lanczos/双线性缩放阶段限制输出长边像素（自动对齐偶数 ≥64）；HLG MP4 模式强制锁定 ≤1920 px。",
                    en: "Caps maximum output edge in pixels (even >=64); HLG MP4 strictly caps at <=1920 px."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "1440 / 1920 / 2048 px：精准匹配抖音、小红书免二次压缩安全线。",
                    en: "1440 / 1920 / 2048 px: hits exact social platform safe thresholds."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "原图尺寸 (nil)：导出完整 33MP 全分辨率档案。",
                    en: "Original Size: exports full unscaled sensor resolution."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "Apple 相册用原图；小红书用 2048 px；抖音 HLG 用 1920 px。",
                    en: "Original for Apple Photos; 2048 px for Xiaohongshu; 1920 px for Douyin HLG."
                ),
                proTip: LocalizedText(
                    zhHans: "小红书超出 2048 px 或 4 MB 会被客户端强压剥离 Gain Map，保持护栏即可稳定点亮。",
                    en: "Keeping Xiaohongshu exports <=2048 px prevents client-side recompression from stripping Gain Maps."
                )
            )

        case .baseColorSpace:
            return ParameterDoc(
                id: id,
                title: LocalizedText(zhHans: "基础色彩空间", en: "Base Color Space"),
                shortSummary: LocalizedText(
                    zhHans: "选择基础层的 P3 或 sRGB 色域。",
                    en: "Choose Display P3 or sRGB for the exported base layer."
                ),
                controlsWhat: LocalizedText(
                    zhHans: "设定导出图像的 ICC 色域标签与编码色域矩阵（Display P3 广色域或兼容 sRGB）。",
                    en: "Sets the base image color primaries and embedded ICC profile (Display P3 vs. sRGB)."
                ),
                leftOrLowEffect: LocalizedText(
                    zhHans: "Display P3（推荐）：更广阔的红绿青色域，完美适配 Apple 屏与小红书。",
                    en: "Display P3 (recommended): rich wide-gamut colors for Apple displays and Xiaohongshu."
                ),
                rightOrHighEffect: LocalizedText(
                    zhHans: "sRGB：通用兼容性最强，适合对旧版网页或特定安卓客户端稳妥展示。",
                    en: "sRGB: maximum legacy compatibility across older web and Android viewers."
                ),
                recommendedRange: LocalizedText(
                    zhHans: "HEIC/AVIF 与小红书 JPEG 推荐 Display P3；抖音图文预设默认 sRGB。",
                    en: "Display P3 for HEIC/AVIF/Xiaohongshu; sRGB for Douyin JPG fallback."
                ),
                proTip: LocalizedText(
                    zhHans: "无论选择哪种基础色域，内部 Linear Rec.2020 管线与 OKLab 色域映射都确保无色相偏移。",
                    en: "OKLab gamut mapping from Linear Rec.2020 ensures hue-accurate conversion to either target."
                )
            )
        }
    }
}
