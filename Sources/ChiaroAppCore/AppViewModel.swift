import AppKit
import Foundation
import ChiaroCore
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
public final class AppViewModel {
    public static let headroomPresetSteps: [LinearHeadroom] = [.sdr, .x2, .x4, .x8]

    // Presets
    public var builtInPresets: [PresetSchema] = []
    public var customPresets: [PresetSchema] = []
    public var activePreset: PresetSchema

    // Queue & Per-Photo Deltas
    public var items: [BatchItem] = []
    public var selectedItemID: UUID?
    public var perPhotoDeltas: [URL: PerPhotoDelta] = [:]
    public var recursiveImport: Bool = false

    // Preview & Inspection State
    public var previewMode: EDRPreviewMode = .standardEDR {
        didSet {
            if previewMode != .gainMapDirectView {
                lastNonGainMapMode = previewMode
            }
        }
    }
    private var lastNonGainMapMode: EDRPreviewMode = .standardEDR
    public var simulatedHeadroom: LinearHeadroom = .x4
    public var sdrExposureScaleEnabled: Bool = false
    public var splitPosition: Float = 0.5
    public var screenMaxEDR: Double = 1.0
    public var currentRenderedFrame: RenderedFrame?
    public var currentFallbackReason: String?
    public var currentEstimatedKelvin: Double?
    public var histogramBins: [UInt32] = Array(repeating: 0, count: 256)
    public var isRenderingPreview: Bool = false
    public var previewError: String?
    public var sharedShaderLibrary: MetalShaderLibrary?

    // Inspector & Backend Options
    public var editScope: InspectorEditScope = .globalPreset
    public var decodeBackend: RAWBackend = .libraw {
        didSet { schedulePreviewRender(immediate: true) }
    }
    public var writeCustomRenderedHDR: Bool {
        get { activePreset.compatOptions.writeCustomRenderedHDR }
        set {
            activePreset.compatOptions.writeCustomRenderedHDR = newValue
        }
    }

    // Export Configuration
    public var outputDirectory: URL
    public var useFormatSubdirectories: Bool = false
    public var namingTemplate: String = "{name}_HDR.{ext}"
    public var conflictPolicy: ConflictPolicy = .overwrite
    public var verifyAfterExport: Bool = true
    public var showExportSheet: Bool = false
    public var showPublishingGuide: Bool = false
    public var showGuideFromExportSheet: Bool = false
    public var isInteractingPreview: Bool = false
    public var isDropTargeted: Bool = false
    public var expandGroup1: Bool = true
    public var expandGroup2: Bool = true
    public var expandGroup3: Bool = true
    public var expandGroup4: Bool = true
    public var inspectingArtifact: ExportArtifact?

    // Batch Export Runtime State
    public var isExporting: Bool = false
    public var exportTotalCount: Int = 0
    public var exportCompletedCount: Int = 0
    public var batchSummary: BatchExportSummary?
    public var alertMessage: String?

    private let previewService = PreviewRenderService()
    private var renderTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    private var exportTask: Task<[ExportResult], Error>?
    private var exportCoordinatorTask: Task<Void, Never>?
    private var activeExportID: UUID?

    public init() {
        let loaded = (try? PresetLoader.loadAllBuiltIn()) ?? []
        let initialPreset = loaded.first ?? Self.fallbackPreset()
        self.builtInPresets = loaded
        self.activePreset = initialPreset
        self.simulatedHeadroom = initialPreset.targetHeadroom.toLinear()

        let picturesDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.outputDirectory = picturesDir.appendingPathComponent("Chiaro_Output", isDirectory: true)
    }

    public var allPresets: [PresetSchema] {
        builtInPresets + customPresets
    }

    public var selectedItem: BatchItem? {
        guard let selectedItemID else { return items.first }
        return items.first(where: { $0.id == selectedItemID }) ?? items.first
    }

    public var isSDRExternalMonitor: Bool {
        screenMaxEDR <= 1.01
    }

    public var effectivePreviewColorSpace: BaseColorSpace {
        activePreset.baseColorSpace
    }

    public var isRGB3chGainMapRestricted: Bool {
        Set(activePreset.outputFormats) == [.jpeg] && activePreset.compatOptions.writeUltrahdrXMP
    }

    public var selectedEffectiveParams: EffectiveDevelopParams {
        let delta = selectedItem.flatMap { perPhotoDeltas[$0.sourceURL] }
        return EffectiveDevelopParams.resolve(preset: activePreset, delta: delta)
    }

    public var selectedHasDelta: Bool {
        guard let item = selectedItem, let d = perPhotoDeltas[item.sourceURL] else { return false }
        return !d.isEmpty
    }

    public func hasDelta(for item: BatchItem) -> Bool {
        guard let d = perPhotoDeltas[item.sourceURL] else { return false }
        return !d.isEmpty
    }

    // MARK: - Screen & Headroom Controls

    public func updateScreenMaxEDR(_ value: Double) {
        let clamped = max(1.0, value)
        if abs(screenMaxEDR - clamped) > 0.01 {
            screenMaxEDR = clamped
        }
    }

    public func setSimulatedHeadroom(_ headroom: LinearHeadroom) {
        let clamped = LinearHeadroom(multiplier: min(max(headroom.multiplier, 1.0), 8.0))
        simulatedHeadroom = clamped
        scheduleHistogramRecompute()
    }

    public func toggleGainMapView() {
        if previewMode == .gainMapDirectView {
            previewMode = lastNonGainMapMode
        } else {
            previewMode = .gainMapDirectView
        }
    }

    // MARK: - Preset Selection & Import/Export

    public func selectPreset(_ preset: PresetSchema) {
        activePreset = preset
        simulatedHeadroom = LinearHeadroom(multiplier: min(max(preset.targetHeadroom.toLinear().multiplier, 1.0), 8.0))
        schedulePreviewRender(immediate: true)
    }

    public func presentImportPresetPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "导入预设 JSON"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let imported = try PresetJSONCodec.importPreset(from: url)
                if let idx = customPresets.firstIndex(where: { $0.id == imported.id }) {
                    customPresets[idx] = imported
                } else {
                    customPresets.append(imported)
                }
                selectPreset(imported)
            } catch {
                alertMessage = "预设 JSON 导入失败：\(error)"
            }
        }
    }

    public func presentExportPresetPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(activePreset.id).json"
        panel.prompt = "导出预设 JSON"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PresetJSONCodec.exportPreset(activePreset, to: url)
            } catch {
                alertMessage = "预设导出失败（校验未通过）：\(error)"
            }
        }
    }

    // MARK: - Import & Queue Management

    public func importLaunchArguments(_ arguments: [String]) {
        let urls = ARWFileDiscovery.parseLaunchURLs(arguments: arguments)
        if !urls.isEmpty {
            addDiscoveredARWs(urls)
        }
    }

    public func importDroppedOrOpenedURLs(_ urls: [URL]) {
        let discovered = ARWFileDiscovery.discover(urls: urls, recursive: recursiveImport)
        if discovered.isEmpty {
            alertMessage = "未在选定路径中找到有效的 .ARW 原始文件（已自动忽略 .HIF 及非 ARW 文件）。"
            return
        }
        addDiscoveredARWs(discovered)
    }

    private func addDiscoveredARWs(_ urls: [URL]) {
        let existingPaths = Set(items.map { $0.sourceURL.standardizedFileURL.path })
        var addedCount = 0
        for url in urls {
            let key = url.standardizedFileURL.path
            guard !existingPaths.contains(key) else { continue }
            items.append(BatchItem(sourceURL: url))
            addedCount += 1
        }
        if selectedItemID == nil, let first = items.first {
            selectedItemID = first.id
            schedulePreviewRender(immediate: true)
        } else if addedCount > 0 && currentRenderedFrame == nil {
            schedulePreviewRender(immediate: true)
        }
    }

    public func selectItem(_ item: BatchItem) {
        selectedItemID = item.id
        schedulePreviewRender(immediate: true)
    }

    public func removeItem(_ item: BatchItem) {
        guard !isExporting else { return }
        items.removeAll { $0.id == item.id }
        perPhotoDeltas.removeValue(forKey: item.sourceURL)
        if selectedItemID == item.id {
            renderTask?.cancel()
            renderTask = nil
            histogramTask?.cancel()
            histogramTask = nil
            isRenderingPreview = false
            previewError = nil
            selectedItemID = items.first?.id
            currentRenderedFrame = nil
            currentFallbackReason = nil
            currentEstimatedKelvin = nil
            histogramBins = Array(repeating: 0, count: 256)
            schedulePreviewRender(immediate: true)
        }
    }

    public func clearQueue() {
        guard !isExporting else { return }
        renderTask?.cancel()
        renderTask = nil
        histogramTask?.cancel()
        histogramTask = nil
        isRenderingPreview = false
        previewError = nil
        items.removeAll()
        perPhotoDeltas.removeAll()
        selectedItemID = nil
        currentRenderedFrame = nil
        currentFallbackReason = nil
        currentEstimatedKelvin = nil
        histogramBins = Array(repeating: 0, count: 256)
        batchSummary = nil
    }

    public func presentImportFilesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "arw") ?? .data]
        panel.prompt = "导入 ARW"
        if panel.runModal() == .OK {
            importDroppedOrOpenedURLs(panel.urls)
        }
    }

    public func presentImportFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "导入文件夹"
        if panel.runModal() == .OK {
            importDroppedOrOpenedURLs(panel.urls)
        }
    }

    public func presentOutputDirectoryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择导出目录"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    // MARK: - Per-Photo Delta Management

    public func resetSelectedDelta() {
        guard let item = selectedItem else { return }
        perPhotoDeltas.removeValue(forKey: item.sourceURL)
        schedulePreviewRender(immediate: true)
    }

    public func syncSelectedDeltaToAll() {
        guard let item = selectedItem else { return }
        let delta = perPhotoDeltas[item.sourceURL]
        for other in items where other.sourceURL != item.sourceURL {
            if let delta, !delta.isEmpty {
                perPhotoDeltas[other.sourceURL] = delta
            } else {
                perPhotoDeltas.removeValue(forKey: other.sourceURL)
            }
        }
    }

    public func presentImportDeltaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "导入单图微调 Delta JSON"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let map = try DeltaJSONCodec.loadMap(from: url)
                for item in items {
                    if let matched = DeltaJSONCodec.matchDelta(in: map, for: item.sourceURL) {
                        perPhotoDeltas[item.sourceURL] = matched
                    }
                }
                schedulePreviewRender(immediate: true)
            } catch {
                alertMessage = "Delta JSON 导入失败：\(error)"
            }
        }
    }

    public func presentExportDeltaPanel() {
        var exportMap: [String: PerPhotoDelta] = [:]
        for item in items {
            if let d = perPhotoDeltas[item.sourceURL], !d.isEmpty {
                exportMap[item.fileName] = d
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "chiaro_deltas.json"
        panel.prompt = "导出 Delta JSON"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try DeltaJSONCodec.saveMap(exportMap, to: url)
            } catch {
                alertMessage = "Delta JSON 导出失败：\(error)"
            }
        }
    }

    private func mutateSelectedDelta(_ body: (inout PerPhotoDelta) -> Void) {
        guard let item = selectedItem else { return }
        var delta = perPhotoDeltas[item.sourceURL] ?? PerPhotoDelta()
        body(&delta)
        if delta.isEmpty {
            perPhotoDeltas.removeValue(forKey: item.sourceURL)
        } else {
            perPhotoDeltas[item.sourceURL] = delta
        }
        schedulePreviewRender()
    }

    // MARK: - Guarded Parameter Mutations (Groups 1-4 + Preset Format Options)

    public func updateExposureEV(_ newValue: Double) {
        let clamped = min(max(newValue, -3.0), 3.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.exposureEV = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                let diff = clamped - activePreset.developDefaults.exposureEV
                d.exposureEVDelta = abs(diff) < 1e-4 ? nil : diff
            }
        }
    }

    public func updateWhiteBalance(_ setting: WhiteBalanceSetting) {
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.whiteBalance = setting
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.whiteBalanceOverride = (setting == activePreset.developDefaults.whiteBalance) ? nil : setting
            }
        }
    }

    public func updateShadowRecovery(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 100.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.shadowRecovery = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.shadowRecoveryOverride = clamped }
        }
    }

    public func updateBlackPoint(_ newValue: Double) {
        let clamped = min(max(newValue, -100.0), 100.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.blackPoint = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.blackPointOverride = clamped }
        }
    }

    public func updateVibrance(_ newValue: Double) {
        let clamped = min(max(newValue, -100.0), 100.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.vibrance = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.vibranceOverride = clamped }
        }
    }

    public func updateHighlightReconstruction(_ mode: HighlightReconstructionMode) {
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.highlightReconstruction = mode
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.highlightReconstructionOverride = mode }
        }
    }

    public func updateCameraProfile(_ profile: CameraColorProfile) {
        activePreset.developDefaults.cameraProfile = profile
        schedulePreviewRender(immediate: true)
    }

    public func presentPickDCPPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dcp") ?? .data]
        panel.prompt = "选择 DCP 相机配置文件"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                _ = try DCPProfile(contentsOf: url)
                updateCameraProfile(.dcp(path: url.path))
            } catch {
                alertMessage = "无效的 .dcp 文件：\(error)"
            }
        }
    }

    public func presentPickCubeLUTPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        panel.prompt = "加载 .cube LUT"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                _ = try CubeLUT(contentsOf: url)
                activePreset.developDefaults.cubeLUTPath = url.path
                schedulePreviewRender(immediate: true)
            } catch {
                alertMessage = "无效的 .cube LUT：\(error)"
            }
        }
    }

    public func clearCubeLUT() {
        activePreset.developDefaults.cubeLUTPath = nil
        schedulePreviewRender(immediate: true)
    }

    // Group 2: SDR Controls
    public func updateSDRToneMapper(_ mapper: SDRToneMapper) {
        switch editScope {
        case .globalPreset:
            activePreset.sdrToneMapper = mapper
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.sdrToneMapperOverride = mapper }
        }
    }

    public func updateSDRExposureEV(_ newValue: Double) {
        let clamped = min(max(newValue, -1.0), 1.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.sdrExposureEV = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                let diff = clamped - activePreset.developDefaults.sdrExposureEV
                d.sdrExposureEVDelta = abs(diff) < 1e-4 ? nil : diff
            }
        }
    }

    public func updateSDRHighlightCompression(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 100.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.sdrHighlightCompression = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.sdrHighlightCompressionOverride = clamped }
        }
    }

    public func updateSDRContrast(_ newValue: Double) {
        let clamped = min(max(newValue, -100.0), 100.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.sdrContrast = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.sdrContrastOverride = clamped }
        }
    }

    public func updateSDRSaturation(_ newValue: Double) {
        let clamped = min(max(newValue, -100.0), 100.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.sdrSaturation = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.sdrSaturationOverride = clamped }
        }
    }

    // Group 3: HDR & Gain Map
    public func updateTargetHeadroomStops(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 4.0)
        switch editScope {
        case .globalPreset:
            activePreset.targetHeadroomStops = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.targetHeadroomStopsOverride = clamped }
        }
    }

    public func updateMidtoneAnchorP(_ newValue: Double) {
        let clamped = min(max(newValue, 0.65), 0.95)
        switch editScope {
        case .globalPreset:
            activePreset.midtoneAnchorP = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.midtoneAnchorPOverride = clamped }
        }
    }

    public func updateHDRHighlightExcitation(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 100.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.hdrHighlightExcitation = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.hdrHighlightExcitationOverride = clamped }
        }
    }

    public func updateHDRRolloffSoftness(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 100.0)
        switch editScope {
        case .globalPreset:
            activePreset.developDefaults.hdrRolloffSoftness = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.hdrRolloffSoftnessOverride = clamped }
        }
    }

    public func setGainMapChannels(_ channels: GainMapChannels) {
        if channels == .rgb3ch && isRGB3chGainMapRestricted {
            activePreset.gainMapChannels = .mono1ch
            alertMessage = "纯 JPEG + Ultra HDR XMP 模式仅支持 1ch 单色 Gain Map（如需 3ch 请先启用 HEIC/AVIF 或关闭 Ultra HDR XMP）。"
            return
        }
        activePreset.gainMapChannels = channels
        if channels == .rgb3ch {
            // PresetLoader.validate guardrail: legacy Apple HDRGainMap requires mono1ch
            if activePreset.compatOptions.writeLegacyAppleHDRGainMap {
                activePreset.compatOptions.writeLegacyAppleHDRGainMap = false
            }
        }
        schedulePreviewRender()
    }

    public func setBaseColorSpace(_ colorSpace: BaseColorSpace) {
        guard activePreset.baseColorSpace != colorSpace else { return }
        activePreset.baseColorSpace = colorSpace
        schedulePreviewRender()
    }

    public func setGainMapResolution(_ resolution: GainMapResolution) {
        activePreset.gainMapResolution = resolution
        schedulePreviewRender()
    }

    public func setGainMapGamma(_ gamma: Double) {
        activePreset.gainMapGamma = min(max(gamma, 0.25), 4.0)
        schedulePreviewRender()
    }

    public func setLegacyAppleGainMap(_ enabled: Bool) {
        activePreset.compatOptions.writeLegacyAppleHDRGainMap = enabled
        if enabled {
            // Auto-enforce mono1ch guardrail
            activePreset.gainMapChannels = .mono1ch
        }
        schedulePreviewRender()
    }

    // Group 4: Composition & Output Guardrails
    public func updateCropAspect(_ aspect: AspectRatio) {
        switch editScope {
        case .globalPreset:
            activePreset.cropAspect = aspect
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in d.cropAspectOverride = aspect }
        }
    }

    public func updateCropOffsetX(_ x: Double) {
        mutateSelectedDelta { d in
            var off = d.cropOffset ?? .centered
            off.normalizedCenterX = min(max(x, 0.0), 1.0)
            d.cropOffset = off
        }
    }

    public func updateCropOffsetY(_ y: Double) {
        mutateSelectedDelta { d in
            var off = d.cropOffset ?? .centered
            off.normalizedCenterY = min(max(y, 0.0), 1.0)
            d.cropOffset = off
        }
    }

    public func updateMaxLongEdge(_ edge: Int?) {
        var sanitized = edge.map { max(64, $0 & ~1) }
        if activePreset.outputFormats.contains(.hlgMP4), let val = sanitized, val > 1920 {
            sanitized = 1920
        }
        switch editScope {
        case .globalPreset:
            activePreset.maxLongEdge = sanitized
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                if let sanitized {
                    d.clearMaxLongEdgeOverride = false
                    d.maxLongEdgeOverride = (sanitized == activePreset.maxLongEdge) ? nil : sanitized
                } else {
                    d.maxLongEdgeOverride = nil
                    d.clearMaxLongEdgeOverride = (activePreset.maxLongEdge != nil)
                }
            }
        }
    }

    public func toggleOutputFormat(_ format: OutputFormat) {
        var formats = activePreset.outputFormats
        if let idx = formats.firstIndex(of: format) {
            guard formats.count > 1 else { return } // Must keep at least one output format
            formats.remove(at: idx)
        } else {
            formats.append(format)
        }
        activePreset.outputFormats = formats

        // Auto-enforce PresetLoader validation invariants
        if formats.contains(.hlgMP4) {
            if activePreset.hlgVideoOptions == nil {
                activePreset.hlgVideoOptions = HLGVideoOptions(
                    aspect: activePreset.cropAspect == .ratio3x4 ? .portrait3x4 : .portrait9x16,
                    durationSeconds: 4.0,
                    fps: 30,
                    bitrateMbps: 14.0
                )
            }
            if let edge = activePreset.maxLongEdge, edge > 1920 {
                activePreset.maxLongEdge = 1920
            }
        }
        if Set(formats) == [.jpeg] {
            activePreset.bitDepth = .bit8
            if activePreset.compatOptions.writeUltrahdrXMP {
                activePreset.gainMapChannels = .mono1ch
            }
        }
        schedulePreviewRender()
    }

    // MARK: - Live Coalesced Preview & Histogram

    public func schedulePreviewRender(immediate: Bool = false) {
        renderTask?.cancel()
        renderTask = nil
        guard let selected = selectedItem else {
            isRenderingPreview = false
            previewError = nil
            return
        }

        let url = selected.sourceURL
        let backend = decodeBackend
        let params = selectedEffectiveParams
        let presetSnapshot = activePreset
        let headroom = simulatedHeadroom

        let lockLegacy = presetSnapshot.outputFormats.contains(.heic)
            && presetSnapshot.compatOptions.writeLegacyAppleHDRGainMap
            && presetSnapshot.gainMapChannels == .mono1ch

        let outputSpec = RenderOutputSpec(
            targetBitDepth: .bit8, // Interactive preview uses fast 8-bit CGImage path + rgba16Float sdrLinearTexture
            baseColorSpace: presetSnapshot.baseColorSpace,
            gainMapChannels: presetSnapshot.gainMapChannels,
            gainMapResolution: presetSnapshot.gainMapResolution,
            gainMapGamma: presetSnapshot.gainMapGamma,
            lockLegacyAppleGainMapBounds: lockLegacy,
            generateHLGTexture: false,
            hlgTargetDimensions: nil
        )

        isRenderingPreview = true
        previewError = nil

        renderTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }

            do {
                let snapshot = try await self?.previewService.renderPreviewAndHistogram(
                    url: url,
                    backend: backend,
                    params: params,
                    outputSpec: outputSpec,
                    displayHeadroom: headroom
                )
                guard !Task.isCancelled, let snapshot, let self else { return }
                if self.sharedShaderLibrary == nil {
                    self.sharedShaderLibrary = try? await self.previewService.sharedShaderLibrary()
                }
                self.currentRenderedFrame = snapshot.renderedFrame
                self.currentFallbackReason = snapshot.fallbackReason
                self.currentEstimatedKelvin = ColorTransforms.estimateSceneKelvin(matrices: snapshot.colorMatrices)
                self.histogramBins = snapshot.histogramBins
                self.isRenderingPreview = false
                if let idx = self.items.firstIndex(where: { $0.sourceURL == snapshot.sourceURL }) {
                    self.items[idx].lastFallbackReason = snapshot.fallbackReason
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.previewError = String(describing: error)
                self.isRenderingPreview = false
            }
        }
    }

    private func scheduleHistogramRecompute() {
        histogramTask?.cancel()
        histogramTask = nil
        guard let frame = currentRenderedFrame else { return }
        let headroom = simulatedHeadroom
        histogramTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, let self else { return }
            do {
                let bins = try await self.previewService.recomputeHistogram(
                    rendered: frame,
                    displayHeadroom: headroom
                )
                guard !Task.isCancelled else { return }
                self.histogramBins = bins
            } catch {
                // Keep previous histogram on cancellation or transient errors
            }
        }
    }

    // MARK: - Batch Export via BoundedBatchPipeline

    public func startBatchExport() {
        guard !isExporting, !items.isEmpty else { return }

        var validatedPreset = activePreset
        if validatedPreset.outputFormats.contains(.hlgMP4) {
            if validatedPreset.hlgVideoOptions == nil {
                validatedPreset.hlgVideoOptions = HLGVideoOptions(
                    aspect: validatedPreset.cropAspect == .ratio3x4 ? .portrait3x4 : .portrait9x16,
                    durationSeconds: 4.0,
                    fps: 30,
                    bitrateMbps: 14.0
                )
            }
            if let edge = validatedPreset.maxLongEdge, edge > 1920 {
                validatedPreset.maxLongEdge = 1920
            }
        }
        do {
            try PresetLoader.validate(validatedPreset)
        } catch {
            alertMessage = "当前预设参数校验未通过：\(error)"
            return
        }

        let decodeOpts = DecodeOptions(
            backend: decodeBackend,
            highlightMode: validatedPreset.developDefaults.highlightReconstruction,
            isProxy: false,
            maxThreadsPerWorker: 2,
            customRenderedHDR: validatedPreset.compatOptions.writeCustomRenderedHDR
        )

        let jobs = items.map { item in
            ExportJob(
                id: item.id,
                inputURL: item.sourceURL,
                outputDirectory: outputDirectory,
                preset: validatedPreset,
                formatOverrides: validatedPreset.outputFormats,
                delta: perPhotoDeltas[item.sourceURL],
                decodeOptions: decodeOpts,
                namingTemplate: namingTemplate,
                useFormatSubdirectories: useFormatSubdirectories,
                conflictPolicy: conflictPolicy,
                verifyAfterExport: verifyAfterExport
            )
        }

        for idx in items.indices {
            items[idx].status = .queued
            items[idx].result = nil
        }

        let runID = UUID()
        activeExportID = runID
        isExporting = true
        exportTotalCount = jobs.count
        exportCompletedCount = 0
        batchSummary = nil

        let service = previewService
        exportCoordinatorTask = Task { [weak self] in
            guard let self else { return }
            await service.evictPoolBeforeBatch()
            guard !Task.isCancelled, self.isExporting, self.activeExportID == runID else {
                return
            }

            let pipeline = BoundedBatchPipeline()
            let (events, task) = pipeline.runWithStream(jobs: jobs)
            if Task.isCancelled || !self.isExporting || self.activeExportID != runID {
                task.cancel()
                return
            }
            self.exportTask = task

            for await event in events {
                guard !Task.isCancelled, self.activeExportID == runID else {
                    break
                }
                self.handleBatchEvent(event, runID: runID)
            }

            _ = try? await task.value
            if self.activeExportID == runID {
                self.isExporting = false
                self.exportTask = nil
                self.exportCoordinatorTask = nil
                self.activeExportID = nil
            }
        }
    }

    public func cancelBatchExport() {
        activeExportID = nil
        exportCoordinatorTask?.cancel()
        exportCoordinatorTask = nil
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
        for idx in items.indices where items[idx].status == .queued || items[idx].status == .decoding || items[idx].status == .rendered {
            items[idx].status = .idle
        }
    }

    private func handleBatchEvent(_ event: BatchProgressEvent, runID: UUID) {
        guard activeExportID == runID else { return }
        switch event {
        case .batchStarted:
            break
        case let .jobStarted(jobID, _):
            if let idx = items.firstIndex(where: { $0.id == jobID }) {
                items[idx].status = .decoding
            }
        case let .jobDecoded(jobID, _, _, fallbackReason):
            if let idx = items.firstIndex(where: { $0.id == jobID }) {
                items[idx].lastFallbackReason = fallbackReason
            }
        case let .jobRendered(jobID, _):
            if let idx = items.firstIndex(where: { $0.id == jobID }) {
                items[idx].status = .rendered
            }
        case let .jobCompleted(result):
            exportCompletedCount += 1
            if let idx = items.firstIndex(where: { $0.id == result.jobID }) {
                items[idx].result = result
                items[idx].lastFallbackReason = result.fallbackReason
                if let err = result.errorDescription {
                    items[idx].status = .failed(err)
                } else {
                    items[idx].status = .completed
                }
            }
        case let .batchCompleted(totalJobs, succeeded, failed, elapsedSeconds):
            batchSummary = BatchExportSummary(
                totalJobs: totalJobs,
                succeeded: succeeded,
                failed: failed,
                elapsedSeconds: elapsedSeconds
            )
            isExporting = false
        }
    }

    private static func fallbackPreset() -> PresetSchema {
        PresetSchema(
            id: "apple_heic",
            name: "Apple 相册原生高保真（默认）",
            description: "10-bit Display P3 HEIC + ISO 21496-1 3ch Gain Map",
            outputFormats: [.heic],
            bitDepth: .bit10,
            baseColorSpace: .displayP3,
            gainMapChannels: .rgb3ch,
            gainMapResolution: .half,
            gainMapGamma: 1.0,
            targetHeadroomStops: 2.5,
            midtoneAnchorP: 0.80,
            sdrToneMapper: .agx,
            developDefaults: .default,
            cropAspect: .original,
            maxLongEdge: nil,
            targetMaxFileBytes: nil,
            quality: 0.90,
            gainMapQuality: nil,
            avifCodec: .svtAV1,
            compatOptions: CompatibilityOptions(),
            hlgVideoOptions: nil,
            platformAdvisory: "推荐经 AirDrop（原图）或 iCloud 照片同步至 iPhone；iOS 18–27 相册原生静态 HDR 无角标。"
        )
    }
}
