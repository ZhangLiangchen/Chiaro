# 产品需求文档（PRD）：`Chiaro` v1.1 — 开源对标 DxO PhotoLab 的原生 HDR 数字暗房

| 文档元信息 | 内容 |
|---|---|
| **产品名称** | **Chiaro**（原生 macOS HDR-First RAW 数字暗房 & CLI） |
| **文档版本** | **v1.1**（基于 v1.0 已发布基线 `github.com/ZhangLiangchen/Chiaro` 迭代） |
| **创建日期** | 2026-11-26 |
| **开源协议策略** | **GPL-3.0-or-later**（取消 v1.0 零 GPL/LGPL 商业闭源约束，全面拥抱开源影像生态） |
| **官方认证机型策略** | **聚焦 Sony α7C II（`ILCE-7CM2`）与索尼 `.ARW` 作为唯一官方实测认证基准**（核心管线保持相机无关抽象，暂不对外宣称或放开未实测的其他品牌 RAW） |
| **关联文档** | [v1.1 架构决策记录（ADR-011 ~ ADR-018）](./ADR.md) · [v1.0 基线 PRD](../PRD.md) · [v1.0 基线 ADR](../ADR.md) · [新会话开发启动提示词](./NEXT_SESSION_PROMPT.md) |
| **目标平台** | Apple Silicon macOS **15.0+**（macOS **26.0+** 原生 Apple Liquid Glass，macOS 15 优雅降级；本机基准 macOS 27.2 / Swift 6.4.2） |

---

## 1. 产品愿景与多代演进路线图

### 1.1 长期定位：开源世界的 **HDR-Native DxO PhotoLab**
Chiaro 旨在打造一款**完全开源、原生于 Apple Silicon（Swift 6 + Metal + Apple ANE）、从第一颗像素起即为真 HDR 设计的专业摄影暗房与 CLI**，在核心光学画质、AI 高感降噪与智能调色上对标 **DxO PhotoLab**，同时彻底解决跨平台真 HDR（ISO/IEC 21496-1:2025 Gain Map）分发难题。

由于项目定位为**纯开源社区产品（不考虑商业闭源分发）**，自 v1.1 起取消 v1.0 的「零 GPL/LGPL」约束，主协议切换为 **GPL-3.0-or-later**，高效借力成熟开源影像生态（LibRaw GPL2/GPL3 高精度去马赛克算法包、Lensfun 光学镜头模块库、以及未来的开源 RAW 神经网络模型）。同时，研发遵循**“先吃透单机标杆、有真片才解锁”**的务实策略：v1.1 深度聚焦 **Sony α7C II（`.ARW`）** 打磨至真片可肉眼验透的水准，不为未实测的其他品牌做盲目兼容承诺。

### 1.2 三代版本路线图（Roadmap）

| 版本 | 代号 / 主题 | 核心交付范围 | 状态 |
|---|---|---|---|
| **v1.0** | **HDR 管线基石** | Linear Rec.2020 Metal 管线、ISO 21496-1 Gain Map 引擎、四路编码（HEIC / Ultra HDR JPEG / MIAF Grid AVIF / 10-bit HLG MP4）、7 套内置预设、`chiaro-cli`、120Hz EDR `Chiaro.app` | **已发布** (`v1.0.0`) |
| **v1.1** | **Sony A7C2 光学暗房与液态玻璃体验打磨（本 PRD 范围）** | ① **GPL-3.0 切换** + **LibRaw GPL2/GPL3 高精度去马赛克（AMaZE/LMMSE/DCB）**；② **双开源自动光学引擎**（`.ARW` 内嵌工厂光学曲线 darktable GPL-3.0 公式 + **Lensfun 离线开源数据库**，GPU 单 Pass 线性采样）；③ **吸收 darktable GPL-3.0 四大画质模块（Metal GPU 版）**：**Profiled Denoise 标定高感小波降噪**（内置 Sony A7C2/A7M4 `noiseprofiles.json`）、**`Sigmoid` 防偏色色调映射**、**无光晕局部对比度/通透度（Clarity，对标 DxO ClearView）**、**物理反扩散光学锐化（Optical Sharpness，对标 DxO Lens Sharpness）** 及真实 **`inpaint opposed` 高光重构升级**；④ **聚焦 Sony α7C II / `.ARW`** + **`.chiaro.json` 非破坏 Sidecar**（含 v2/v3 扩展槽位）；⑤ **预设模式 / 专业模式无损切换** + **100% 双语参数说明体系** + **Apple Liquid Glass UI** + **`chiaro-cli` 全量对齐** | **规划中（下一会话开发）** |
| **v2.0** | **Apple ANE AI 降噪（对标 DxO DeepPRIME）** | 吸收 **darktable-ai / NAFNet / NIND** 开源生态，面向 **Sony α7C II / α7 IV 33MP BSI 传感器**，以 `noiseprofiles.json` 噪声水平 $\sigma(\text{ISO})$ 为条件输入，基于 **CoreML + Apple ANE**（固定分块 `512×512`/`768×768` + `IOSurface` 零拷贝推理）实现线性/Bayer RAW 神经网络降噪（与 v1.1 Profiled Wavelet 及原生 `CIRAWv9` 形成三轨降噪）；支持结合 LLM 场景分析推荐降噪策略 | 架构已在 v1.1 ADR 预留插槽 |
| **v3.0** | **多模态 LLM/VLM 智能调色与交互调色室** | 吸收 **darktable `Color Balance RGB`（4-Way 感知色轮）** 与 **`Tone Equalizer`（8 档区域曝光均衡器）** 作为确定性线性调色引擎；接入可插拔 **Multimodal LLM/VLM API**（云端 OpenAI 兼容 / Gemini / Claude + 本地零费用隐私 **Ollama / MLX-VLM**），通过“自然语言指令 + 低分预览图 + 直方图 + EXIF”输出严格 JSON Schema 配方，驱动调色引擎与 v2 ANE 降噪参数 | 架构已在 v1.1 ADR 预留插槽 |

---

## 2. v1.1 目标用户与痛点解决

| 用户群体 | v1.0 痛点 | v1.1 解决方案 |
|---|---|---|
| **普通索尼摄影爱好者**（想“拖入 `.ARW` → 选平台 → 轻调两下 → 导出真 HDR”） | 右侧栏一次性堆砌 25+ 专业参数（`Midtone Anchor P`、`Opposed Inpaint`、`Gain Map Gamma` 等），上手门槛高，不知道每个滑块干什么用。 | ① 默认进入 **「预设模式（Preset Mode）」**：可视化平台预设卡片 + **5 个直觉滑块** + 自动镜头校正开关 + 画幅裁剪 + 一键导出；② 默认展开一行通俗短说明，点 `?` 浮卡查看「向左拉 / 向右拉效果」。 |
| **专业索尼玩家 / A7C2 画质控**（对标 DxO PhotoLab） | ① 缺少镜头畸变/暗角/紫边自动校正（尤其是新款 E 口镜头如腾龙 25–200mm A075）；② 仅基础去马赛克，ISO 6400–12800 夜景或细密纹理不够锐利纯净；③ 关闭 App 后单图微调不随照片目录持久化。 | ① 引入 **LibRaw AMaZE / LMMSE / DCB** 高精度去马赛克；② 引入 **双开源自动光学引擎（`.ARW` 内嵌工厂光学曲线 + Lensfun 离线开源数据库，GPU 单 Pass 线性采样）**，新款 E 口镜头零手动调试开箱即准；③ **`.chiaro.json` 非破坏 Sidecar** 随图持久化；④ **「专业模式（Pro Mode）」** 全量参数控制 + 中性暗房画布。 |
| **macOS 现代桌面审美用户 & 国际开源用户** | V1.0 UI 为基础表单风格，缺少现代 macOS 液态玻璃层次感；UI 与参数说明仅简体中文。 | 采用 **Apple Liquid Glass 液态玻璃设计体系**（悬浮控件与自适应液态玻璃画布 `adaptive-liquid-glass` 无缝跟随系统浅色/深色外观，同时严格保证 EDR 图像像素上方零有色折射干扰），并实现 **简体中文 + 英文全双语**。 |

---

## 3. v1.1 功能需求详述（Functional Requirements）

### FR-11：许可协议切换与开源影像底层增强（GPL-3.0-or-later）
1. **协议切换**：
   - 仓库 `LICENSE` 由 Apache-2.0 升级为 **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)**；
   - 更新 `THIRD_PARTY_NOTICES.md`、`README.md` 与 `Scripts/verify_licenses.sh`：移除“禁止 LibRaw GPL2/GPL3 demosaic packs / LGPL”拦截规则，升级为 **GPL-3.0 兼容性与 SBOM 审计脚本**（验证所有链接库均为 GPL-3.0 兼容的 OSI 开源许可，输出完整依赖许可清单，杜绝混入不兼容的 GPL-2.0-only 或闭源二进制）。
2. **保留 V1.0 已验证的四路 HDR 编码基线**：
   - 不替换已通过 164/164 E2E 与真实样片验证的 HEIC (`ImageIO`)、JPEG (`libultrahdr` + `ImageIO`)、AVIF (`libavif` + `SVT-AV1`/`libaom` Grid Tiling) 与 10-bit HLG MP4 (`AVAssetWriter` + `VideoToolbox`) 链路。

---

### FR-12：LibRaw GPL2/GPL3 高精度去马赛克引擎（面向 Sony Bayer `.ARW` 深度调优）
1. **依赖升级**：`Vendor/build_deps.sh` 编译 `LibRaw 0.22.3` 时集成官方 `LibRaw-demosaic-pack-GPL2` 与 `LibRaw-demosaic-pack-GPL3`。
2. **可选去马赛克算法（`DemosaicAlgorithm`）**：
   - **`amaze`（默认，高细节首选）**：AMaZE（Aliasing Minimization and Zipper Elimination），显著抑制建筑/织物细密纹理的摩尔纹与拉链伪影，细节解析力对标 DxO / RawTherapee。
   - **`lmmse`（高感夜景首选）**：LMMSE，极佳抑制 A7C2 在 ISO 6400–12800 夜景下的彩噪与伪色（高度适配唐模夜景测试集）。
   - **`dcb`**：DCB 双通道插值，高反差边缘更顺滑、抑制锯齿。
   - **`dht` / `ahd`**：经典快速平衡算法，便于速度优先场景与画质对照。
3. **预览与导出策略**：
   - 实时交互预览（Proxy 模式）继续沿用高速 GCD Bayer 快速路径（保障 `≤ 300ms` 响应 SLA）；
   - 最终导出与 1:1 全尺寸渲染执行用户选定的 `DemosaicAlgorithm`。

---

### FR-13：双开源自动光学模块（Embedded ARW 工厂光学曲线 + Lensfun 离线开源库）
> **设计原则**：**100% 基于开源光学曲线方案，不提供猜测式手动畸变/色差滑块**，确保普通用户开箱即得专业准确的光学矫正效果。

1. **双开源光学引擎协同（`OpticalProfileSource`）**：
   - **引擎 A（自动模式首选）— Sony `.ARW` 内嵌工厂光学曲线（移植 `darktable` / `RawTherapee` GPL-3.0 开源公式）**：
     - 本机真实样片已实测确认：无论是全画幅 33MP（`DSC02532.ARW`，49mm，16 节点）还是 APS-C 14MP 裁切（`DSC02556.ARW`，200mm/等效 300mm，11 节点），新款 `TAMRON 25-200mm F2.8-5.6 A075 E` 与原厂 E 口镜头均在 `.ARW` SubIFD 中逐帧写入了当前焦距/光圈/裁切下的精确工厂光学曲线：
       - `0x7032` `DistortionCorrParams`（径向畸变曲线）
       - `0x7035` `ChromaticAberrationCorrParams`（红/蓝通道横向色差 TCA 曲线）
       - `0x7037` `VignettingCorrParams`（径向暗角失光曲线）
     - 开箱即用覆盖所有现代自动 Sony E 卡口原厂与副厂新镜，无需等待外部数据库更新，也无需用户手动调整。
   - **引擎 B（开源数据库互补与老镜兜底）— `Lensfun` 离线开源光学数据库（LGPL-3.0）**：
     - 随 `ChiaroCore` 内置完整离线 Lensfun XML 镜头/机身数据库（零联网依赖，含 Sony E-mount 全画幅 `1.0×` / APS-C `1.5×` 机身兼容回退）；
     - 当导入无内嵌光学曲线的老镜头/手动镜头时自动回退至 Lensfun 匹配；亦支持专业用户在专业模式下主动切换「仅使用 Lensfun 开源库」对比效果，或导入社区更新的 Lensfun `.xml` 文件（持久化于 `~/Library/Application Support/Chiaro/Lensfun/`）。
2. **极简清晰的光学控制项（`OpticalCorrectionParameters`）**：
   - **总开关（`enabled`）**：预设模式仅暴露这一个一键开关（默认开启），并清晰展示当前生效的开源光学配置来源（如 `内嵌光学曲线 · TAMRON 25-200mm A075 @ 49mm` 或 `Lensfun 开源库 · <镜头名>`）。
   - **专业模式细控**：
     - 光学引擎来源：`自动（优先内嵌曲线，缺失回退 Lensfun）` / `仅内嵌 ARW 光学曲线` / `仅 Lensfun 开源库`（配合可选 Lensfun 镜头检索与自定义 XML 导入）；
     - 畸变校正开关（`distortion`）+ 自动缩放裁切黑边（`autoScale`，默认开启）；
     - 横向色差校正开关（`tca`，消除高反差灯牌/树枝紫绿边）；
     - 暗角校正开关（`vignetting`）+ 暗角补偿比例（`vignettingStrength: 0%–100%`，用于控制保留多少自然镜头暗角氛围，而非手工伪造畸变）。
   - 若既无 `.ARW` 内嵌曲线也未命中 Lensfun 库，安全零开销直通并如实提示「无可用开源光学配置」，不阻断预览或导出。
3. **GPU 线性管线性能要求**：
   - 两种开源光学引擎统一生成标准 GPU 控制网格，在 Metal GPU 的 `rgba16Float` 线性工作空间以单 Pass 采样完成（不得阻塞 CPU 逐像素重算，不得裁切 HDR `>1.0` 高光数值）。

---

### FR-13B：吸收 darktable GPL-3.0 开源画质四大引擎（Metal GPU 原生化）
解除 0-GPL 限制后，v1.1 直接吸收开源影像旗舰 **darktable（GPL-3.0）** 中投入产出比最高、无需额外重型 C++ 依赖、且可直接跑在 Metal `rgba16Float` 线性管线上的 4 项核心算法，大幅缩小与 DxO PhotoLab 的画质差距：

1. **Profiled Denoise 标定高感小波降噪（填补 LibRaw 路线夜景降噪空白，提前验证 v2 `LinearDenoiseStage` 插槽）**：
   - 内置提取自 `darktable` 开源 `noiseprofiles.json` 的 **Sony `ILCE-7CM2` / `ILCE-7M4` 33MP 泊松-高斯噪声模型**（按 ISO 100–51200 自动插值散粒噪声 `a` 与读出噪声 `b`）；
   - 在 **Lensfun 光学几何变形之前** 的线性空间执行 **广义 Anscombe 方差稳定化变换（GAT）→ Metal À-trous 多尺度小波色度/亮度去噪 → 逆变换（IGAT）**；
   - 控件：`高感标定降噪开关`、`彩噪抑制（Chroma: 0–100，默认 65）`、`明度降噪（Luma: 0–100，默认 25，随 ISO 自动温和缩放）`，单帧 33MP GPU 耗时 `< 6ms`，让 `LibRaw + AMaZE/LMMSE` 在 ISO 12800 夜景下即刻拥有干净纯净的暗部。
2. **无光晕局部对比度 / 通透度（`Clarity`，对标 DxO ClearView Plus）**：
   - 移植 `darktable` 边缘感知双边 / 局部拉普拉斯金字塔局部对比度算法至 Metal GPU（`clarity: -100 ~ +100`，默认 `0`），在 Linear/OKLab 亮度通道增强中尺度微反差与通透感，高反差边缘（如夜景楼宇轮廓、天空交界）**零亮边光晕**。
3. **物理反扩散光学锐化（`Optical Sharpness`，对标 DxO Lens Sharpness Optimization）**：
   - 移植 `darktable` `diffuse or sharpen` 的热传导反向扩散原理，封装为面向摄影师的极简单滑块 **`光学清晰度 / 去模糊（opticalSharpness: 0–100）`**（底层在 Metal 执行轻量各向异性反扩散迭代，自动按局部梯度抑噪防放大暗部噪点），无传统 USM 的生硬白边，专治去马赛克微糊与镜头轻度衍射。
4. **`Sigmoid` 色调映射器 + 升级版 `Inpaint Opposed` 高光重构**：
   - SDR 支路新增第 4 种色调映射器 **`Sigmoid`**（移植 `darktable/src/iop/sigmoid.c` 广义对数逻辑斯蒂曲线 + 主色防偏色保护，与 `AgX` / `Neutral Rational` / `OpenDRT` 并列）；
   - 将高光重构 `opposedInpaint` 升级对齐 `darktable` 真实 GPL-3.0 `inpaint opposed` 算法，彻底杜绝夜景过曝灯笼/霓虹灯牌出现洋红裁切色斑。

---

### FR-14：Sony α7C II / `.ARW` 聚焦策略与分层机型扩展机制
1. **v1.1 明确聚焦范围（Tier 1 官方认证）**：
   - 文件发现（`ARWFileDiscovery`）、`chiaro-cli` 与 `Info.plist` 继续专注 **`.ARW`**（大小写不敏感），严格排除 `.HIF` / `.JPG` / `.HEIC` / `.chiaro.json` 及 `*.ARW/` 伪装目录。
   - 官方认证与回归基准锁定为 **Sony α7C II（`ILCE-7CM2`）**（涵盖全画幅 33MP `7008×4672` 横/竖构图、APS-C 14MP `4608×3072` 裁切、无损压缩 RAW、ISO 1600–12800 夜景高感），同时天然兼容同代索尼 Bayer `.ARW` 机型。
2. **核心架构相机无关 + 社区渐进解锁机制**：
   - `ChiaroCore` 线性渲染、Lensfun 光学与 Sidecar 均不写死索尼特定假设；
   - 在 `README.md` 明确列出「Supported Cameras」分级表：v1.1 仅认证 Sony `.ARW`（A7C2 Golden Baseline），未来接受社区贡献其他品牌真实 CC0 RAW 样片并通过完整色准与 E2E 验证后逐机型解锁，杜绝“盲目宣称支持但实际偏色崩溃”。

---

### FR-15：`.chiaro.json` 非破坏 Sidecar 持久化（对标 DxO `.dop`）
1. **文件命名与位置**：与源 `.ARW` 文件同目录同名加 `.chiaro.json`（例如 `DSC02532.ARW` → `DSC02532.ARW.chiaro.json`），采用原子写入（`.tmp` + `replaceItemAt`）杜绝半写损坏。
2. **版本化 Schema（`schemaVersion = 2`）**：
   - 存储当前关联预设 ID、解码后端、去马赛克算法、光学模块配置（含自动/手动选镜与解析微调值）、完整 `PerPhotoDelta`、修改时间戳与 `appVersion`；
   - **前瞻预留扩展字段（可选、默认 `nil`、反序列化安全忽略未知字段）**：
     - `denoise: DenoiseParameters?`（v2 CoreML Apple ANE 降噪参数预留）
     - `aiColor: AIColorGradingParameters?`（v3 多模态 LLM/VLM 调色节点、色轮与提示词记录预留）
3. **App 与 CLI 协同**：
   - **App 端**：提供「自动保存 `.chiaro.json` Sidecar」偏好开关（默认开启）；重新导入目录时自动读取已有 Sidecar 恢复上次全部微调，队列行显示 `Sidecar` / `Delta` 标记；保留原有批量导入/导出合并 `Delta JSON` 的兼容性。
   - **CLI 端**：默认自动探测同目录 `.chiaro.json`（可通过 `--no-sidecar` 禁用）；若同时指定 `--delta-file`，优先级为 `CLI 显式参数 > --delta-file > .chiaro.json Sidecar > Preset 默认值`。

---

### FR-16：预设模式（Preset Mode）与专业模式（Pro Mode）无损切换
1. **顶栏模式切换器**：窗口顶部液态玻璃工具栏常驻分段切换器 **`预设模式` | `专业模式`**（快捷键 `⌘⇧P`），记忆用户上次选择，首次启动默认进入**预设模式**。
2. **双模式参数与界面分层矩阵**：

| 区域 / 能力 | 预设模式（Preset Mode — 面向普通用户） | 专业模式（Pro Mode — 面向专业摄影师） |
|---|---|---|
| **左侧栏** | 顶部「可视化目标预设卡片」（7 套预设以卡片呈现：名称、目标平台图标、输出规格标签、发布提示） + 队列列表 | 紧凑预设下拉/导入导出 + 队列列表（含 Delta/Sidecar/Compliance 徽章） |
| **中间预览区** | 简洁液态玻璃悬浮栏：快捷「原图/成片」长按或分屏对比按钮 + 屏幕 EDR 状态指示 + 精简 EXIF 信息条 | 完整检视工具栏：屏幕 EDR 读数 + iPhone `1×/2×/4×/8×` 模拟与滑块 + 4 检视模式（标准 EDR / 分屏 / 假彩色热力图 / `G` 键 Gain Map 直视）+ 双区直方图 + SDR 曝光缩放 |
| **右侧调节栏** | 仅展示 **3 块核心区**：<br>1. **画面精调（6 个直觉滑块）**：① `整体曝光`（`exposureEV`）、② `HDR 强度`（联动 `targetHeadroomStops` `1.0–3.5 EV`）、③ `暗部提亮`（`shadowRecovery`）、④ `通透度`（`clarity`）、⑤ `色彩鲜艳度`（`vibrance`）、⑥ `画面冷暖`（`whiteBalance`）<br>2. **自动画质增强**：`自动镜头光学校正`开关（显示内嵌曲线/Lensfun 徽章）+ `高感夜景智能降噪`一键开关（Profiled Wavelet 自动按 ISO 适配）<br>3. **画幅与一键导出**：画幅比例 + 裁剪中心微调 + 醒目「导出」按钮 | 展开完整 **5 大折叠分组** + 作用域切换（批量预设 / 单图微调）：<br>1. **解码、降噪与光学模块**（LibRaw/CIRAWv9、去马赛克 AMaZE/LMMSE/DCB/DHT/AHD、Profiled 标定降噪开关及彩噪/明度强度、开源光学引擎来源 `自动/内嵌曲线/Lensfun`、畸变+裁切黑边/TCA/暗角子开关与暗角比例、Lensfun 选镜与自定义 XML 导入、CustomRendered 标记）<br>2. **共享基础调色 (Linear Rec.2020)**（白平衡/色调、曝光、阴影、黑位、通透度 Clarity、光学清晰度 Optical Sharpness、自然饱和度、升级版高光重构、DCP/Creative Look、`.cube` LUT）<br>3. **SDR 基准支路（中灰锁定）**（AgX/Sigmoid/Neutral/OpenDRT、SDR 曝光/高光压缩/反差/饱和度）<br>4. **HDR 与 Gain Map 引擎**（Headroom、锚点 P、高光激励、肩部柔化、1ch/3ch、1/2 vs 1:1、Gamma、闭环补偿、iOS 14–17 双写）<br>5. **构图裁剪与分辨率保护**（画幅、裁剪中心 X/Y、最大长边） |
| **参数短说明默认值** | **默认开启**（每个滑块下方显示一行通俗短简介） | **默认关闭**（保持专业面板紧凑，可随时点击顶栏开关打开，且随时可点 `?` 查看详卡） |

3. **无损双向切换铁律**：
   - 两种模式读写同一份 `EffectiveDevelopParams` / `PerPhotoDelta`，绝不因切换模式丢失任何微调。
   - 若用户在专业模式修改了预设模式未暴露的高级参数（如 `midtoneAnchorP`、`sdrContrast`、`gainMapGamma`、`demosaic`、`opticsSource` 等），切回预设模式后这些参数**继续生效**，右侧栏顶部显示轻提示胶囊 **`含 N 项专业微调`**，提供「前往专业模式查看」与「重置专业微调」快捷操作。

---

### FR-17：100% 全参数功能说明体系（中英双语）
1. **覆盖范围**：覆盖 App 内**全部 100% 可调节项与关键开关**（RAW 后端、去马赛克算法、光学模块自动/手动控制项、共享基础 9 项、SDR 支路 5 项、HDR/Gain Map 9 项、构图 4 项、预览模式 4 项，共计约 36+ 项控件）。
2. **每项参数说明的结构化内容标准（`ParameterDoc`）**：
   - `title`：中英文参数名（如 `中灰锁定锚点 P` / `Midtone Anchor (P)`）
   - `shortSummary`：一句话通俗说明（≤ 28 汉字 / ≤ 75 英文字符，用于内联副标题）
   - `controlsWhat`：控制什么（从光学/色彩管线讲清作用位置）
   - `leftOrLowEffect` / `rightOrHighEffect`：向左拉 / 向右拉（或选择各枚举项）会产生什么具体视觉效果
   - `recommendedRange`：推荐安全区间 / 常见预设值
   - `proTip`：专业避坑提示（例如“拉过高光激励在 SDR 屏不会变亮，只在 HDR 屏增强灯牌耀眼感；若热力图出现洋红过曝请适度回拉”）
3. **交互呈现**：
   - 每个参数标题旁提供轻量 `?` 按钮（低对比度、不抢视觉重心），点击弹出 **Liquid Glass 说明浮卡（Popover）**；
   - 顶栏/右侧栏顶部提供 **「显示参数简介」** 开关，全局控制滑块下方是否常驻 `shortSummary` 一行小字；
   - 单元测试强制校验 `ParameterID.allCases` 中每一项均存在非空的中英文 `ParameterDoc`，保证未来新增参数绝不遗漏说明。

---

### FR-18：Apple Liquid Glass 液态玻璃 UI 设计体系与中英双语
1. **视觉层次划分（暗房色彩准确性铁律）**：
   - **悬浮控制层（Liquid Glass Layer）**：顶部工具栏、模式切换胶囊、左侧预设卡片与队列浮层、右侧参数分组卡片、画布上方悬浮 HUD（EDR 状态、热力图图例、Gain Map 信息胶囊、加载指示器）、`?` 参数说明浮卡、导出与合规报告弹窗——在 **macOS 26.0+** 使用原生 Apple Liquid Glass（`.glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)`），在 **macOS 15** 优雅降级为 `.ultraThinMaterial` + `0.5pt` 高光描边 + 轻阴影。
   - **主预览画布层（v1.1.1 自适应液态玻璃画布 `adaptive-liquid-glass`）**：预览工作区无缝跟随系统 Light/Dark Mode（与左右侧栏保持一致），预览视口采用统一的 `.chiaroGlassSurface(cornerRadius: 12)` 液态玻璃卡片，Metal `MTKView` 清屏色随系统外观动态映射；同时**严禁**在 EDR 图像像素上方叠加任何有色折射或玻璃蒙版，防止色彩污染干扰 10-bit Display P3 白平衡与高光判断。
   - **无障碍适配**：自动响应系统「降低透明度（Reduce Transparency）」与「增加对比度（Increase Contrast）」偏好设置。
2. **中英双语国际化**：
   - 全量 UI 文案、预设描述、发布防坑指引与 `ParameterDocumentationRegistry` 均支持 **简体中文（`zh-Hans`）** 与 **英文（`en`）**；
   - 默认跟随 macOS 系统语言，并在设置/菜单栏提供即时切换开关（`跟随系统 / 简体中文 / English`）。

---

### FR-19：`chiaro-cli` v1.1 同步增强
1. **输入范围**：专注 `.ARW` 发现（保持既有递归、去重与排除 `.HIF` 行为）。
2. **新增 CLI 参数**：
   - `--demosaic <amaze|lmmse|dcb|dht|ahd>`：指定 LibRaw 去马赛克算法（默认 `amaze`）。
   - `--denoise <auto|off>` / `--denoise-chroma <0..100>` / `--denoise-luma <0..100>`：控制 Profiled 标定小波降噪（`auto` 按 EXIF ISO 自动启用并按 A7C2 噪声曲线缩放）。
   - `--lens-correction <auto|embedded|lensfun|off>`：选择开源光学引擎（默认 `auto`：优先 `.ARW` 内嵌工厂光学曲线，无内嵌时回退 Lensfun 离线开源库，均无时安全直通）。
   - `--lens-vignetting <on|off>` / `--lens-distortion <on|off>` / `--lens-tca <on|off>` / `--lens-vignetting-strength <0..100>`：细粒度光学子模块控制。
   - `--tone-mapper <agx|sigmoid|neutral|opendrt>`、`--clarity <-100..100>`、`--sharpness <0..100>`：CLI 同步支持 `Sigmoid`、通透度与物理光学锐化。
   - `--use-sidecar` / `--no-sidecar`：控制是否自动读取同目录 `.chiaro.json`（默认 `--use-sidecar`）。
3. **NDJSON 进度事件增强**：`job_decoded` 事件新增 `demosaicUsed`、`opticsSource`（`embedded_arw` / `lensfun` / `none`）与 `lensMatched` 字段，方便外部脚本与 UI 观测。

---

## 4. 非功能需求（Non-Functional Requirements）

| 维度 | v1.1 指标要求 |
|---|---|
| **实时预览响应** | 拖动滑块（含 Lensfun / 手动光学实时调节）保持 60–120fps 流畅；单张 A7C2 Proxy 首次解码维持 `≤ 300ms`；GPU 光学单 Pass 耗时 `< 5ms`（33MP 全画幅）。 |
| **批处理吞吐与内存** | 全量 35 张 A7C2 33MP/14MP `.ARW`（开启 AMaZE + 光学模块）批处理峰值内存仍控制在 `≤ 4.5 GiB`；双格式导出平均单张耗时 `≤ 1.5s`。 |
| **HDR 合规零回退** | v1.0 全部 164 项 E2E 门禁 + 95 项既有单元测试 100% 保持通过（HEIC/JPEG/AVIF ISO 21496-1 `contentHeadroom` 误差 `< 2%`、AVIF Grid Tiling 零 `pasp` 错挂、小红书 JPEG `≤ 4MB`、抖音 HLG MP4 合规）。 |
| **架构前瞻兼容** | `.chiaro.json` `schemaVersion = 2` 与管线协议在 v1.1 冻结，确保 v2（CoreML ANE 降噪，率先标定 A7C2 33MP 传感器）与 v3（LLM/VLM 调色）接入时**无需破坏既有预设、Sidecar 或渲染管线接口**。 |

---

## 5. v1.1 验收标准（Definition of Done）

1. **构建与许可审计**：`swift build -Xswiftc -warnings-as-errors`、`swift build --build-tests -Xswiftc -warnings-as-errors`、独立版 `Chiaro.app` 与 `chiaro-cli` 发布包均零警告构建通过；`LICENSE` 为 `GPL-3.0-or-later`，`Scripts/verify_licenses.sh` 输出完整开源依赖 SBOM 且零不兼容许可告警。
2. **Sony A7C2 去马赛克与光学模块实测**：
   - `LibRaw` AMaZE / LMMSE / DCB / DHT / AHD 在唐模 A7C2 `.ARW` 样片（全画幅 33MP + APS-C 14MP + ISO 12800 夜景）上全部零报错通过，且不同算法间存在可验证的高频细节/像素差异；
   - **双开源光学引擎实测**：在唐模真实 `.ARW`（全画幅 16 节点 `DSC02532.ARW` 与 APS-C 11 节点 `DSC02556.ARW`）上验证 `.ARW` 内嵌光学曲线（`0x7032`/`0x7035`/`0x7037`）自动解析与畸变/TCA/暗角校正生效；同时验证 Lensfun 离线库匹配（含 Sony E-mount 机身回退与自定义 XML 加载）；GPU 单 Pass 输出有效线性 `rgba16Float`（无 NaN/Inf、无 HDR `>1.0` 高光截断）。
   - **darktable GPL-3.0 四大画质模块实测**：① Profiled Denoise 在 ISO 12800 样片上实测暗部色度方差显著下降且保持亮部细节与线性无裁切；② `Sigmoid` 色调映射单调有界且中灰锁定精准；③ `Clarity` 与 `Optical Sharpness` 均产生可测量微反差/锐度提升且无 NaN/Inf 与明显亮边振铃；④ 升级版 `inpaint opposed` 对单通道饱和高光消除洋红偏色。
3. **Sidecar & CLI 验证**：`.chiaro.json` v2 读写往返、原子落盘、未知 v2/v3 字段前向兼容、CLI 自动读取与优先级（`CLI > --delta-file > Sidecar > Preset`）全部单测与 E2E 通过。
4. **双模式 & 100% 参数文档门禁**：
   - 预设模式 ↔ 专业模式无损往返切换单测通过（含高级参数保留与「含 N 项专业微调」检测）；
   - `ParameterDocumentationTests` 强制断言 `ParameterID.allCases` 100% 拥有非空 `zh-Hans` + `en` 完整 6 字段文档；
   - 中英双语切换无缺失本地化 Key。
5. **液态玻璃 UI & 真机兼容**：`Chiaro.app` 在 macOS 27.2 上编译签名并 3 秒启动冒烟通过，无崩溃日志；主画布采用自适应液态玻璃卡片（`adaptive-liquid-glass`，`.chiaroGlassSurface(cornerRadius: 12)` 无缝跟随系统浅色/深色模式且 EDR 图像像素上方零有色折射）；`@available(macOS 26.0, *)` 与 macOS 15 降级路径均编译通过且支持减少透明度无障碍模式。
6. **回归零退化**：v1.0 全部 95 项既有单元测试 + 164 项 E2E 合规测试（含 `ImageIOProbe`、`avifdec`、`ultrahdr_app`、`exiftool`、`ffprobe`）与新增 v1.1 单测/E2E 全绿通过。
