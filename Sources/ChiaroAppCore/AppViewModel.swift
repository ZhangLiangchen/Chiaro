import AppKit
import Foundation
import ChiaroCore
import Observation
import UniformTypeIdentifiers

private final class SidecarDiskCoordinator: @unchecked Sendable {
    private final class URLSlot {
        let lock = NSLock()
        var writeToken: UInt64 = 0
    }

    private let tableLock = NSLock()
    private var slots: [String: URLSlot] = [:]

    private func slot(for url: URL) -> URLSlot {
        let key = url.standardizedFileURL.path
        tableLock.lock()
        defer { tableLock.unlock() }
        if let existing = slots[key] {
            return existing
        }
        let created = URLSlot()
        slots[key] = created
        return created
    }

    func currentWriteToken(for url: URL) -> UInt64 {
        let s = slot(for: url)
        s.lock.lock()
        defer { s.lock.unlock() }
        return s.writeToken
    }

    @discardableResult
    func advanceWriteToken(for url: URL) -> UInt64 {
        let s = slot(for: url)
        s.lock.lock()
        defer { s.lock.unlock() }
        s.writeToken &+= 1
        return s.writeToken
    }

    func advanceAllWriteTokens() {
        tableLock.lock()
        let allSlots = Array(slots.values)
        tableLock.unlock()
        for s in allSlots {
            s.lock.lock()
            s.writeToken &+= 1
            s.lock.unlock()
        }
    }

    func exists(for url: URL) -> Bool {
        let s = slot(for: url)
        s.lock.lock()
        defer { s.lock.unlock() }
        return ChiaroSidecar.exists(for: url)
    }

    func loadIfExistsAndAdvanceWriteToken(for url: URL) -> ChiaroSidecar? {
        let s = slot(for: url)
        s.lock.lock()
        defer { s.lock.unlock() }
        s.writeToken &+= 1
        return try? ChiaroSidecar.loadIfExists(for: url)
    }

    func deleteAndAdvanceWriteToken(for url: URL) {
        let s = slot(for: url)
        s.lock.lock()
        defer { s.lock.unlock() }
        s.writeToken &+= 1
        try? ChiaroSidecar.delete(for: url)
    }

    func saveIfTokenMatches(_ sidecar: ChiaroSidecar, for url: URL, expectedToken: UInt64) -> Bool {
        let s = slot(for: url)
        s.lock.lock()
        defer { s.lock.unlock() }
        guard s.writeToken == expectedToken else {
            return false
        }
        do {
            try ChiaroSidecar.save(sidecar, for: url)
            return true
        } catch {
            return false
        }
    }

    func deleteIfTokenMatches(for url: URL, expectedToken: UInt64) -> (attempted: Bool, diskExists: Bool) {
        let s = slot(for: url)
        s.lock.lock()
        defer { s.lock.unlock() }
        guard s.writeToken == expectedToken else {
            return (attempted: false, diskExists: ChiaroSidecar.exists(for: url))
        }
        try? ChiaroSidecar.delete(for: url)
        return (attempted: true, diskExists: ChiaroSidecar.exists(for: url))
    }
}

@MainActor
@Observable
public final class AppViewModel {
    public static let headroomPresetSteps: [LinearHeadroom] = [.sdr, .x2, .x4, .x8]

    private enum DefaultsKey {
        static let workspaceMode = "chiaro.workspaceMode"
        static let appLanguage = "chiaro.appLanguage"
        static let autoSaveSidecar = "chiaro.autoSaveSidecar"
        static let inlineDocsPreset = "chiaro.inlineDocs.preset"
        static let inlineDocsPro = "chiaro.inlineDocs.pro"
    }

    private let userDefaults: UserDefaults

    // Dual-Mode Workspace, Localization & Documentation Preferences
    public var workspaceMode: WorkspaceMode {
        didSet {
            userDefaults.set(workspaceMode.rawValue, forKey: DefaultsKey.workspaceMode)
            if workspaceMode == .pro && availableLensfunLenses.isEmpty {
                refreshAvailableLensfunLenses()
            }
        }
    }

    public var appLanguage: AppLanguage {
        didSet {
            userDefaults.set(appLanguage.rawValue, forKey: DefaultsKey.appLanguage)
        }
    }

    public var autoSaveSidecar: Bool {
        didSet {
            userDefaults.set(autoSaveSidecar, forKey: DefaultsKey.autoSaveSidecar)
            if !autoSaveSidecar {
                cancelAllPendingSidecarSaves()
            }
        }
    }

    private var inlineDocsPreset: Bool {
        didSet {
            userDefaults.set(inlineDocsPreset, forKey: DefaultsKey.inlineDocsPreset)
        }
    }

    private var inlineDocsPro: Bool {
        didSet {
            userDefaults.set(inlineDocsPro, forKey: DefaultsKey.inlineDocsPro)
        }
    }

    public var showInlineParameterSummaries: Bool {
        get { workspaceMode == .preset ? inlineDocsPreset : inlineDocsPro }
        set {
            if workspaceMode == .preset {
                inlineDocsPreset = newValue
            } else {
                inlineDocsPro = newValue
            }
        }
    }

    public var resolvedLanguage: ResolvedLanguage {
        appLanguage.resolve()
    }

    // Presets & Baselines
    public var builtInPresets: [PresetSchema] = []
    public var customPresets: [PresetSchema] = []
    public var activePreset: PresetSchema
    private var baselineBuiltInPresets: [String: PresetSchema] = [:]
    private var baselineCustomPresets: [String: PresetSchema] = [:]

    // Queue, Per-Photo Deltas & Sidecars
    public var items: [BatchItem] = []
    public var selectedItemID: UUID?
    public var perPhotoDeltas: [URL: PerPhotoDelta] = [:]
    public var recursiveImport: Bool = false
    public private(set) var sidecarPresentURLs: Set<URL> = []
    private var preservedAIColor: [URL: AIColorGradingParameters] = [:]
    private var pendingSidecarDirtyURLs: Set<URL> = []
    private var sidecarSaveTasks: [URL: Task<Void, Never>] = [:]
    private var sidecarMutationEpoch: [URL: UInt64] = [:]
    private var sidecarLastCommittedPersistOrLoadEpoch: [URL: UInt64] = [:]
    private var sidecarDeletedEpoch: [URL: UInt64] = [:]
    private var sidecarRemovedEpoch: [URL: UInt64] = [:]
    private var activeSidecarDiskTasks: [URL: (id: UUID, task: Task<Void, Never>)] = [:]
    private let sidecarCoordinator = SidecarDiskCoordinator()

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
    public var currentOpticsInfo: OpticsResolutionInfo = .none
    public var currentISO: Int?
    public var currentLensModel: String?
    public var availableLensfunLenses: [String] = []
    public var histogramBins: [UInt32] = Array(repeating: 0, count: 256)
    public var isRenderingPreview: Bool = false
    public var previewError: String?
    public var sharedShaderLibrary: MetalShaderLibrary?

    // Inspector & Global v1.1 Pipeline Defaults
    public var editScope: InspectorEditScope = .globalPreset
    public var decodeBackend: RAWBackend = .libraw {
        didSet { schedulePreviewRender(immediate: true) }
    }
    public var demosaicAlgorithm: DemosaicAlgorithm = .amaze {
        didSet { schedulePreviewRender(immediate: true) }
    }
    public var opticsParameters: OpticalCorrectionParameters = .default {
        didSet { schedulePreviewRender() }
    }
    public var denoiseParameters: DenoiseParameters = .default {
        didSet { schedulePreviewRender() }
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
    public var expandGroup5: Bool = true
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

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        if let rawMode = userDefaults.string(forKey: DefaultsKey.workspaceMode),
           let storedMode = WorkspaceMode(rawValue: rawMode) {
            self.workspaceMode = storedMode
        } else {
            self.workspaceMode = .preset
        }

        if let rawLang = userDefaults.string(forKey: DefaultsKey.appLanguage),
           let storedLang = AppLanguage(rawValue: rawLang) {
            self.appLanguage = storedLang
        } else {
            self.appLanguage = .system
        }

        if userDefaults.object(forKey: DefaultsKey.autoSaveSidecar) != nil {
            self.autoSaveSidecar = userDefaults.bool(forKey: DefaultsKey.autoSaveSidecar)
        } else {
            self.autoSaveSidecar = true
        }

        if userDefaults.object(forKey: DefaultsKey.inlineDocsPreset) != nil {
            self.inlineDocsPreset = userDefaults.bool(forKey: DefaultsKey.inlineDocsPreset)
        } else {
            self.inlineDocsPreset = true
        }

        if userDefaults.object(forKey: DefaultsKey.inlineDocsPro) != nil {
            self.inlineDocsPro = userDefaults.bool(forKey: DefaultsKey.inlineDocsPro)
        } else {
            self.inlineDocsPro = false
        }

        let loaded = (try? PresetLoader.loadAllBuiltIn()) ?? []
        let initialPreset = loaded.first ?? Self.fallbackPreset()
        self.builtInPresets = loaded
        var baselineMap: [String: PresetSchema] = [:]
        for preset in loaded {
            baselineMap[preset.id] = preset
        }
        if baselineMap[initialPreset.id] == nil {
            baselineMap[initialPreset.id] = initialPreset
        }
        self.baselineBuiltInPresets = baselineMap
        self.activePreset = initialPreset
        self.simulatedHeadroom = initialPreset.targetHeadroom.toLinear()

        let picturesDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.outputDirectory = picturesDir.appendingPathComponent("Chiaro_Output", isDirectory: true)
    }

    public var allPresets: [PresetSchema] {
        builtInPresets + customPresets
    }

    public var baselineForActivePreset: PresetSchema {
        baselineBuiltInPresets[activePreset.id]
            ?? baselineCustomPresets[activePreset.id]
            ?? activePreset
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
        effectiveParams(for: selectedItem?.sourceURL)
    }

    public func effectiveParams(for url: URL?) -> EffectiveDevelopParams {
        let delta = url.flatMap { perPhotoDeltas[$0] }
        var resolved = EffectiveDevelopParams.resolve(preset: activePreset, delta: delta)
        if delta?.decodeBackendOverride == nil {
            resolved.decodeBackend = decodeBackend
        }
        if delta?.demosaicOverride == nil {
            resolved.demosaic = demosaicAlgorithm
        }
        if delta?.opticsOverride == nil {
            resolved.optics = opticsParameters.sanitized()
        }
        if delta?.denoiseOverride == nil {
            resolved.denoise = denoiseParameters.sanitized()
        }
        if resolved.aiColor == nil, let url {
            resolved.aiColor = preservedAIColor[url]
        }
        return resolved
    }

    public var activeProOnlyOverrides: [ParameterID] {
        ProOverrideInspector.activeProOnlyOverrides(
            effective: selectedEffectiveParams,
            preset: activePreset,
            baselinePreset: baselineForActivePreset
        )
    }

    public var selectedHasDelta: Bool {
        guard let item = selectedItem, let d = perPhotoDeltas[item.sourceURL] else { return false }
        return !d.isEmpty
    }

    public func hasDelta(for item: BatchItem) -> Bool {
        guard let d = perPhotoDeltas[item.sourceURL] else { return false }
        return !d.isEmpty
    }

    public func hasSidecar(for item: BatchItem) -> Bool {
        item.hasSidecar || sidecarPresentURLs.contains(item.sourceURL)
    }

    private var activeMutationScope: InspectorEditScope {
        (workspaceMode == .preset && selectedItem != nil) ? .perPhotoDelta : editScope
    }

    // MARK: - Dual Mode & Reset Pro Overrides

    public func toggleWorkspaceMode() {
        workspaceMode = (workspaceMode == .preset) ? .pro : .preset
    }

    /// Resets all Pro-only overrides back to baseline/defaults without touching Preset Mode settings
    /// (Exposure, coupled 1.0..3.5 EV Headroom, Shadow Recovery, Clarity, Vibrance, WB Kelvin,
    /// Optics master toggle, Denoise master on/off, Crop Aspect & Crop Center).
    public func resetProOnlyOverrides() {
        let baseline = baselineForActivePreset

        // Preserve Preset Mode global settings on activePreset
        let preservedExposure = activePreset.developDefaults.exposureEV
        let preservedShadow = activePreset.developDefaults.shadowRecovery
        let preservedClarity = activePreset.developDefaults.clarity
        let preservedVibrance = activePreset.developDefaults.vibrance
        let preservedCropAspect = activePreset.cropAspect
        let preservedWB: WhiteBalanceSetting = {
            switch activePreset.developDefaults.whiteBalance {
            case .asShot:
                return .asShot
            case .custom(let k, _):
                return .custom(temperatureKelvin: k, tint: 0.0)
            }
        }()

        let globalHeadroom = activePreset.targetHeadroomStops
        let keepGlobalHeadroom = globalHeadroom >= 1.0 - 1e-4 && globalHeadroom <= 3.5 + 1e-4
            && abs(globalHeadroom - baseline.targetHeadroomStops) > 1e-4

        activePreset.sdrToneMapper = baseline.sdrToneMapper
        activePreset.gainMapChannels = baseline.gainMapChannels
        activePreset.gainMapResolution = baseline.gainMapResolution
        activePreset.gainMapGamma = baseline.gainMapGamma
        activePreset.midtoneAnchorP = baseline.midtoneAnchorP
        activePreset.baseColorSpace = baseline.baseColorSpace
        activePreset.maxLongEdge = baseline.maxLongEdge
        activePreset.compatOptions = baseline.compatOptions
        activePreset.targetHeadroomStops = keepGlobalHeadroom ? globalHeadroom : baseline.targetHeadroomStops

        var resetDev = baseline.developDefaults
        resetDev.exposureEV = preservedExposure
        resetDev.shadowRecovery = preservedShadow
        resetDev.clarity = preservedClarity
        resetDev.vibrance = preservedVibrance
        resetDev.whiteBalance = preservedWB
        if keepGlobalHeadroom {
            resetDev.hdrHighlightExcitation = ProOverrideInspector.expectedPresetExcitation(
                forHeadroomStops: activePreset.targetHeadroomStops
            )
        }
        activePreset.developDefaults = resetDev

        // Global v1.1 parameters: reset Pro sub-settings while keeping Preset Mode master toggles
        decodeBackend = .libraw
        demosaicAlgorithm = .amaze
        opticsParameters = OpticalCorrectionParameters(enabled: opticsParameters.enabled)
        let keptDenoiseMode: DenoiseEngineMode = (denoiseParameters.mode == .off) ? .off : .profiledWavelet
        denoiseParameters = DenoiseParameters(mode: keptDenoiseMode)

        // Reset Pro-only overrides on selected item delta while preserving Preset Mode delta fields
        if let item = selectedItem, var delta = perPhotoDeltas[item.sourceURL] {
            delta.decodeBackendOverride = nil
            delta.demosaicOverride = nil
            delta.sdrExposureEVDelta = nil
            delta.blackPointOverride = nil
            delta.opticalSharpnessOverride = nil
            delta.highlightReconstructionOverride = nil
            delta.sdrHighlightCompressionOverride = nil
            delta.sdrContrastOverride = nil
            delta.sdrSaturationOverride = nil
            delta.sdrToneMapperOverride = nil
            delta.midtoneAnchorPOverride = nil
            delta.hdrRolloffSoftnessOverride = nil
            delta.maxLongEdgeOverride = nil
            delta.clearMaxLongEdgeOverride = false

            if case .custom(let k, _) = delta.whiteBalanceOverride {
                delta.whiteBalanceOverride = .custom(temperatureKelvin: k, tint: 0.0)
            }

            if let hOverride = delta.targetHeadroomStopsOverride {
                if hOverride >= 1.0 - 1e-4 && hOverride <= 3.5 + 1e-4 {
                    delta.hdrHighlightExcitationOverride = ProOverrideInspector.expectedPresetExcitation(
                        forHeadroomStops: hOverride
                    )
                } else {
                    delta.targetHeadroomStopsOverride = nil
                    delta.hdrHighlightExcitationOverride = nil
                }
            } else {
                delta.hdrHighlightExcitationOverride = nil
            }

            if let opt = delta.opticsOverride {
                let cleanOpt = OpticalCorrectionParameters(enabled: opt.enabled)
                delta.opticsOverride = (cleanOpt == opticsParameters) ? nil : cleanOpt
            }
            if let den = delta.denoiseOverride {
                let cleanMode: DenoiseEngineMode = (den.mode == .off) ? .off : .profiledWavelet
                let cleanDen = DenoiseParameters(mode: cleanMode)
                delta.denoiseOverride = (cleanDen == denoiseParameters) ? nil : cleanDen
            }

            if delta.isEmpty {
                perPhotoDeltas.removeValue(forKey: item.sourceURL)
            } else {
                perPhotoDeltas[item.sourceURL] = delta
            }
            bumpSidecarMutationEpoch(item.sourceURL)
            if autoSaveSidecar {
                scheduleSidecarSave(for: item.sourceURL)
            }
        }

        // Ensure crop aspect preserved
        activePreset.cropAspect = preservedCropAspect
        schedulePreviewRender(immediate: true)
    }

    // MARK: - Screen & Headroom Controls

    public func updateScreenMaxEDR(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = max(1.0, value)
        if abs(screenMaxEDR - clamped) > 0.01 {
            screenMaxEDR = clamped
        }
    }

    public func setSimulatedHeadroom(_ headroom: LinearHeadroom) {
        guard headroom.multiplier.isFinite else { return }
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
        if baselineBuiltInPresets[preset.id] == nil && baselineCustomPresets[preset.id] == nil {
            baselineCustomPresets[preset.id] = preset
        }
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
        panel.prompt = ChiaroStrings.msgImportPresetPrompt(resolvedLanguage)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let imported = try PresetJSONCodec.importPreset(from: url)
                baselineCustomPresets[imported.id] = imported
                if let idx = customPresets.firstIndex(where: { $0.id == imported.id }) {
                    customPresets[idx] = imported
                } else {
                    customPresets.append(imported)
                }
                selectPreset(imported)
            } catch {
                alertMessage = "\(error)"
            }
        }
    }

    public func presentExportPresetPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(activePreset.id).json"
        panel.prompt = ChiaroStrings.msgExportPresetPrompt(resolvedLanguage)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try PresetJSONCodec.exportPreset(activePreset, to: url)
            } catch {
                alertMessage = "\(error)"
            }
        }
    }

    // MARK: - Lensfun Database & Custom XML Import

    public func refreshAvailableLensfunLenses() {
        let sonyE = LensfunOpticsProvider.shared.availableLenses(mountFilter: "Sony E")
        if !sonyE.isEmpty {
            availableLensfunLenses = sonyE.sorted()
        } else {
            availableLensfunLenses = LensfunOpticsProvider.shared.availableLenses(mountFilter: nil).sorted()
        }
    }

    public func importCustomLensfunXML(from url: URL) async throws {
        try LensfunOpticsProvider.shared.importCustomXML(from: url)
        refreshAvailableLensfunLenses()
        await previewService.invalidateOpticsEngine()
        schedulePreviewRender(immediate: true)
    }

    public func presentImportLensfunXMLPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.xml]
        panel.prompt = ChiaroStrings.msgImportLensfunPrompt(resolvedLanguage)
        if panel.runModal() == .OK, let url = panel.url {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.importCustomLensfunXML(from: url)
                    self.alertMessage = ChiaroStrings.lensfunImportedSuccess(
                        url.lastPathComponent,
                        count: self.availableLensfunLenses.count,
                        lang: self.resolvedLanguage
                    )
                } catch {
                    self.alertMessage = ChiaroStrings.lensfunImportFailed(
                        "\(error)",
                        lang: self.resolvedLanguage
                    )
                }
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
            alertMessage = ChiaroStrings.msgNoARWFound(resolvedLanguage)
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
            bumpSidecarMutationEpoch(url)
            var batchItem = BatchItem(sourceURL: url)

            // Passive non-destructive .chiaro.json sidecar auto-load (NEVER writes on import),
            // serialized atomically with writeToken advance against any in-flight Task.detached I/O.
            if let sidecar = sidecarCoordinator.loadIfExistsAndAdvanceWriteToken(for: url) {
                sidecarLastCommittedPersistOrLoadEpoch[url] = sidecarMutationEpoch[url, default: 0]
                batchItem.hasSidecar = true
                sidecarPresentURLs.insert(url)

                var restored = sidecar.delta ?? PerPhotoDelta()
                if restored.decodeBackendOverride == nil {
                    restored.decodeBackendOverride = sidecar.decodeBackend
                }
                if restored.demosaicOverride == nil {
                    restored.demosaicOverride = sidecar.demosaic
                }
                if restored.opticsOverride == nil {
                    restored.opticsOverride = sidecar.optics
                }
                if restored.denoiseOverride == nil {
                    restored.denoiseOverride = sidecar.denoise
                }
                if restored.aiColorOverride == nil {
                    restored.aiColorOverride = sidecar.aiColor
                }
                if !restored.isEmpty {
                    perPhotoDeltas[url] = restored
                }
                if let ai = sidecar.aiColor {
                    preservedAIColor[url] = ai
                }
            }

            items.append(batchItem)
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
        bumpSidecarEpochForRemoval(item.sourceURL)
        sidecarSaveTasks[item.sourceURL]?.cancel()
        sidecarSaveTasks.removeValue(forKey: item.sourceURL)
        pendingSidecarDirtyURLs.remove(item.sourceURL)
        items.removeAll { $0.id == item.id }
        perPhotoDeltas.removeValue(forKey: item.sourceURL)
        preservedAIColor.removeValue(forKey: item.sourceURL)
        sidecarPresentURLs.remove(item.sourceURL)

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
            currentOpticsInfo = .none
            currentISO = nil
            currentLensModel = nil
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
        let allURLs = Set(items.map(\.sourceURL))
            .union(sidecarSaveTasks.keys)
            .union(pendingSidecarDirtyURLs)
            .union(sidecarPresentURLs)
            .union(perPhotoDeltas.keys)
            .union(preservedAIColor.keys)
            .union(activeSidecarDiskTasks.keys)
        for url in allURLs {
            bumpSidecarEpochForRemoval(url)
        }
        sidecarCoordinator.advanceAllWriteTokens()
        for task in sidecarSaveTasks.values {
            task.cancel()
        }
        sidecarSaveTasks.removeAll()
        pendingSidecarDirtyURLs.removeAll()
        isRenderingPreview = false
        previewError = nil
        items.removeAll()
        perPhotoDeltas.removeAll()
        preservedAIColor.removeAll()
        sidecarPresentURLs.removeAll()
        selectedItemID = nil
        currentRenderedFrame = nil
        currentFallbackReason = nil
        currentEstimatedKelvin = nil
        currentOpticsInfo = .none
        currentISO = nil
        currentLensModel = nil
        histogramBins = Array(repeating: 0, count: 256)
        batchSummary = nil
    }

    public func presentImportFilesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "arw") ?? .data]
        panel.prompt = ChiaroStrings.msgImportFilesPrompt(resolvedLanguage)
        if panel.runModal() == .OK {
            importDroppedOrOpenedURLs(panel.urls)
        }
    }

    public func presentImportFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = ChiaroStrings.msgImportFolderPrompt(resolvedLanguage)
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
        panel.prompt = ChiaroStrings.msgOutputDirPrompt(resolvedLanguage)
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    // MARK: - Per-Photo Delta & Sidecar Lifecycle

    public func resetSelectedDelta() {
        guard let item = selectedItem else { return }
        resetDelta(for: item)
    }

    private func bumpSidecarMutationEpoch(_ url: URL) {
        let next = sidecarMutationEpoch[url, default: 0] &+ 1
        sidecarMutationEpoch[url] = next
        sidecarCoordinator.advanceWriteToken(for: url)
    }

    private func bumpSidecarEpochForDeletion(_ url: URL) {
        let next = sidecarMutationEpoch[url, default: 0] &+ 1
        sidecarMutationEpoch[url] = next
        sidecarDeletedEpoch[url] = next
        sidecarCoordinator.advanceWriteToken(for: url)
    }

    private func bumpSidecarEpochForRemoval(_ url: URL) {
        let next = sidecarMutationEpoch[url, default: 0] &+ 1
        sidecarMutationEpoch[url] = next
        sidecarRemovedEpoch[url] = next
        sidecarCoordinator.advanceWriteToken(for: url)
    }

    private func cancelAllPendingSidecarSaves() {
        let urls = Set(sidecarSaveTasks.keys)
            .union(pendingSidecarDirtyURLs)
            .union(activeSidecarDiskTasks.keys)
        for url in urls {
            sidecarMutationEpoch[url, default: 0] &+= 1
        }
        for task in sidecarSaveTasks.values {
            task.cancel()
        }
        sidecarSaveTasks.removeAll()
        pendingSidecarDirtyURLs.removeAll()
    }

    public func resetDelta(for item: BatchItem) {
        bumpSidecarMutationEpoch(item.sourceURL)
        perPhotoDeltas.removeValue(forKey: item.sourceURL)
        preservedAIColor.removeValue(forKey: item.sourceURL)
        if autoSaveSidecar {
            scheduleSidecarSave(for: item.sourceURL)
        }
        if selectedItem?.id == item.id {
            schedulePreviewRender(immediate: true)
        }
    }

    public func deleteSidecar(for item: BatchItem) {
        bumpSidecarEpochForDeletion(item.sourceURL)
        sidecarSaveTasks[item.sourceURL]?.cancel()
        sidecarSaveTasks.removeValue(forKey: item.sourceURL)
        pendingSidecarDirtyURLs.remove(item.sourceURL)
        sidecarCoordinator.deleteAndAdvanceWriteToken(for: item.sourceURL)
        sidecarPresentURLs.remove(item.sourceURL)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].hasSidecar = false
        }
        perPhotoDeltas.removeValue(forKey: item.sourceURL)
        preservedAIColor.removeValue(forKey: item.sourceURL)
        if selectedItem?.id == item.id {
            schedulePreviewRender(immediate: true)
        }
    }

    public func syncSelectedDeltaToAll() {
        guard let item = selectedItem else { return }
        let delta = perPhotoDeltas[item.sourceURL]
        for other in items where other.sourceURL != item.sourceURL {
            bumpSidecarMutationEpoch(other.sourceURL)
            if let delta, !delta.isEmpty {
                perPhotoDeltas[other.sourceURL] = delta
            } else {
                perPhotoDeltas.removeValue(forKey: other.sourceURL)
            }
            if autoSaveSidecar {
                scheduleSidecarSave(for: other.sourceURL)
            }
        }
    }

    public func presentImportDeltaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = ChiaroStrings.msgImportDeltaPrompt(resolvedLanguage)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let map = try DeltaJSONCodec.loadMap(from: url)
                for item in items {
                    if let matched = DeltaJSONCodec.matchDelta(in: map, for: item.sourceURL) {
                        bumpSidecarMutationEpoch(item.sourceURL)
                        perPhotoDeltas[item.sourceURL] = matched
                        if autoSaveSidecar {
                            scheduleSidecarSave(for: item.sourceURL)
                        }
                    }
                }
                schedulePreviewRender(immediate: true)
            } catch {
                alertMessage = "\(error)"
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
        panel.prompt = ChiaroStrings.msgExportDeltaPrompt(resolvedLanguage)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try DeltaJSONCodec.saveMap(exportMap, to: url)
            } catch {
                alertMessage = "\(error)"
            }
        }
    }

    private func mutateSelectedDelta(_ body: (inout PerPhotoDelta) -> Void) {
        guard let item = selectedItem else { return }
        bumpSidecarMutationEpoch(item.sourceURL)
        var delta = perPhotoDeltas[item.sourceURL] ?? PerPhotoDelta()
        body(&delta)
        if delta.isEmpty {
            perPhotoDeltas.removeValue(forKey: item.sourceURL)
        } else {
            perPhotoDeltas[item.sourceURL] = delta
        }
        if autoSaveSidecar {
            scheduleSidecarSave(for: item.sourceURL)
        }
        schedulePreviewRender()
    }

    private func scheduleSidecarSave(for url: URL) {
        guard autoSaveSidecar else { return }
        sidecarSaveTasks[url]?.cancel()
        pendingSidecarDirtyURLs.insert(url)

        sidecarSaveTasks[url] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.autoSaveSidecar else { return }
            await self.persistSidecarNow(for: url)
        }
    }

    public func flushPendingSidecarSaves() async {
        while true {
            guard autoSaveSidecar else {
                cancelAllPendingSidecarSaves()
                if let active = activeSidecarDiskTasks.values.first {
                    await active.task.value
                    continue
                }
                return
            }
            let dirtyURLs = pendingSidecarDirtyURLs.filter { url in
                items.contains(where: { $0.sourceURL == url })
            }
            if !dirtyURLs.isEmpty {
                for url in dirtyURLs {
                    guard autoSaveSidecar,
                          pendingSidecarDirtyURLs.contains(url),
                          items.contains(where: { $0.sourceURL == url }) else {
                        continue
                    }
                    sidecarSaveTasks[url]?.cancel()
                    let task = Task { [weak self] in
                        guard let self else { return }
                        await self.persistSidecarNow(for: url)
                    }
                    sidecarSaveTasks[url] = task
                    await task.value
                }
                continue
            }
            if let active = activeSidecarDiskTasks.values.first {
                await active.task.value
                continue
            }
            break
        }
    }

    private func persistSidecarNow(for url: URL) async {
        guard !Task.isCancelled else { return }

        while let prior = activeSidecarDiskTasks[url] {
            await prior.task.value
            guard !Task.isCancelled else { return }
        }

        guard !Task.isCancelled,
              autoSaveSidecar,
              items.contains(where: { $0.sourceURL == url }) else {
            return
        }

        let capturedEpoch = sidecarMutationEpoch[url, default: 0]
        pendingSidecarDirtyURLs.remove(url)
        if sidecarMutationEpoch[url, default: 0] == capturedEpoch {
            sidecarSaveTasks.removeValue(forKey: url)
        }

        let opID = UUID()
        let opTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeSidecarDiskTasks[url]?.id == opID {
                    self.activeSidecarDiskTasks.removeValue(forKey: url)
                }
            }
            let delta = self.perPhotoDeltas[url]
            let aiColor = delta?.aiColorOverride ?? self.preservedAIColor[url]
            let coordinator = self.sidecarCoordinator

            if (delta == nil || delta?.isEmpty == true) && aiColor == nil {
                let expectedToken = coordinator.currentWriteToken(for: url)
                let hadSidecar = self.sidecarPresentURLs.contains(url) || coordinator.exists(for: url)
                if hadSidecar {
                    await Task.detached(priority: .utility) {
                        _ = coordinator.deleteIfTokenMatches(for: url, expectedToken: expectedToken)
                    }.value
                }
                let stillInQueue = self.items.contains(where: { $0.sourceURL == url })
                let lastCommitted = self.sidecarLastCommittedPersistOrLoadEpoch[url] ?? 0
                guard stillInQueue, lastCommitted <= capturedEpoch else {
                    return
                }
                if !coordinator.exists(for: url) {
                    self.sidecarPresentURLs.remove(url)
                    if let idx = self.items.firstIndex(where: { $0.sourceURL == url }) {
                        self.items[idx].hasSidecar = false
                    }
                } else {
                    self.sidecarPresentURLs.insert(url)
                    if let idx = self.items.firstIndex(where: { $0.sourceURL == url }) {
                        self.items[idx].hasSidecar = true
                    }
                }
                return
            }

            let hadSidecarBefore = self.sidecarPresentURLs.contains(url) || coordinator.exists(for: url)
            let expectedToken = coordinator.currentWriteToken(for: url)
            let sidecar = ChiaroSidecar(
                schemaVersion: ChiaroSidecar.currentSchemaVersion,
                appVersion: "1.1.1",
                updatedAt: ChiaroSidecar.currentTimestamp(),
                presetID: self.activePreset.id,
                decodeBackend: delta?.decodeBackendOverride,
                demosaic: delta?.demosaicOverride,
                optics: delta?.opticsOverride,
                delta: delta,
                denoise: delta?.denoiseOverride,
                aiColor: aiColor
            )

            let saved = await Task.detached(priority: .utility) { () -> Bool in
                coordinator.saveIfTokenMatches(sidecar, for: url, expectedToken: expectedToken)
            }.value

            let stillInQueue = self.items.contains(where: { $0.sourceURL == url })
            let lastCommitted = self.sidecarLastCommittedPersistOrLoadEpoch[url] ?? 0
            let deletedSinceCapture = (self.sidecarDeletedEpoch[url] ?? 0) > capturedEpoch
                && (self.sidecarDeletedEpoch[url] ?? 0) >= lastCommitted
            let removedFreshSinceCapture = !hadSidecarBefore
                && (self.sidecarRemovedEpoch[url] ?? 0) > capturedEpoch
                && (self.sidecarRemovedEpoch[url] ?? 0) >= lastCommitted

            if saved {
                if deletedSinceCapture || removedFreshSinceCapture {
                    let rollbackToken = coordinator.currentWriteToken(for: url)
                    let rollbackResult = await Task.detached(priority: .utility) {
                        coordinator.deleteIfTokenMatches(for: url, expectedToken: rollbackToken)
                    }.value
                    let stillInQueueAfterRollback = self.items.contains(where: { $0.sourceURL == url })
                    let lastCommittedAfterRollback = self.sidecarLastCommittedPersistOrLoadEpoch[url] ?? 0
                    if stillInQueueAfterRollback && lastCommittedAfterRollback <= capturedEpoch && !rollbackResult.diskExists {
                        self.sidecarPresentURLs.remove(url)
                        if let idx = self.items.firstIndex(where: { $0.sourceURL == url }) {
                            self.items[idx].hasSidecar = false
                        }
                    }
                    return
                }

                self.sidecarLastCommittedPersistOrLoadEpoch[url] = max(lastCommitted, capturedEpoch)
                if stillInQueue {
                    self.sidecarPresentURLs.insert(url)
                    if let idx = self.items.firstIndex(where: { $0.sourceURL == url }) {
                        self.items[idx].hasSidecar = true
                    }
                }
            }
        }
        activeSidecarDiskTasks[url] = (opID, opTask)
        await opTask.value
        if activeSidecarDiskTasks[url]?.id == opID {
            activeSidecarDiskTasks.removeValue(forKey: url)
        }
    }

    // MARK: - Guarded Parameter Mutations (Groups 1-5 + Preset Mode Coupled Controls)

    public func updateDecodeBackend(_ backend: RAWBackend) {
        switch activeMutationScope {
        case .globalPreset:
            decodeBackend = backend
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.decodeBackendOverride = (backend == decodeBackend) ? nil : backend
            }
        }
    }

    public func updateDemosaicAlgorithm(_ algorithm: DemosaicAlgorithm) {
        switch activeMutationScope {
        case .globalPreset:
            demosaicAlgorithm = algorithm
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.demosaicOverride = (algorithm == demosaicAlgorithm) ? nil : algorithm
            }
        }
    }

    // Stage 2A Denoise
    public func updateDenoiseEnabled(_ enabled: Bool) {
        let targetMode: DenoiseEngineMode = enabled ? .profiledWavelet : .off
        updateDenoiseMode(targetMode)
    }

    public func updateDenoiseMode(_ mode: DenoiseEngineMode) {
        switch activeMutationScope {
        case .globalPreset:
            var next = denoiseParameters
            next.mode = mode
            denoiseParameters = next.sanitized()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                var current = d.denoiseOverride ?? denoiseParameters
                current.mode = mode
                let clean = current.sanitized()
                d.denoiseOverride = (clean == denoiseParameters) ? nil : clean
            }
        }
    }

    public func updateDenoiseLuminance(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            var next = denoiseParameters
            next.luminanceStrength = clamped
            denoiseParameters = next.sanitized()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                var current = d.denoiseOverride ?? denoiseParameters
                current.luminanceStrength = clamped
                let clean = current.sanitized()
                d.denoiseOverride = (clean == denoiseParameters) ? nil : clean
            }
        }
    }

    public func updateDenoiseChroma(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            var next = denoiseParameters
            next.chromaStrength = clamped
            denoiseParameters = next.sanitized()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                var current = d.denoiseOverride ?? denoiseParameters
                current.chromaStrength = clamped
                let clean = current.sanitized()
                d.denoiseOverride = (clean == denoiseParameters) ? nil : clean
            }
        }
    }

    public func updateDenoiseDetail(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            var next = denoiseParameters
            next.detailPreservation = clamped
            denoiseParameters = next.sanitized()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                var current = d.denoiseOverride ?? denoiseParameters
                current.detailPreservation = clamped
                let clean = current.sanitized()
                d.denoiseOverride = (clean == denoiseParameters) ? nil : clean
            }
        }
    }

    // Stage 2B Open-Source Optics (ADR-013: ZERO manual k1/k2/CA sliders)
    private func mutateOptics(_ body: (inout OpticalCorrectionParameters) -> Void) {
        switch activeMutationScope {
        case .globalPreset:
            var next = opticsParameters
            body(&next)
            opticsParameters = next.sanitized()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                var current = d.opticsOverride ?? opticsParameters
                body(&current)
                let clean = current.sanitized()
                d.opticsOverride = (clean == opticsParameters) ? nil : clean
            }
        }
    }

    public func updateOpticsEnabled(_ enabled: Bool) {
        mutateOptics { $0.enabled = enabled }
    }

    public func updateOpticsSource(_ source: OpticalProfileSource) {
        mutateOptics { $0.source = source }
    }

    public func updateOpticsDistortion(_ enabled: Bool) {
        mutateOptics { $0.distortion = enabled }
    }

    public func updateOpticsAutoScale(_ enabled: Bool) {
        mutateOptics { $0.autoScale = enabled }
    }

    public func updateOpticsTCA(_ enabled: Bool) {
        mutateOptics { $0.tca = enabled }
    }

    public func updateOpticsVignetting(_ enabled: Bool) {
        mutateOptics { $0.vignetting = enabled }
    }

    public func updateOpticsVignettingStrength(_ strength: Double) {
        guard strength.isFinite else { return }
        let clamped = min(max(strength, 0.0), 1.0)
        mutateOptics { $0.vignettingStrength = clamped }
    }

    public func updateLensfunOverride(camera: String? = nil, lens: String?) {
        mutateOptics {
            if let camera {
                $0.lensfunCameraOverride = camera
            }
            $0.lensfunLensOverride = lens
        }
    }

    // Group 2: Shared Base Grading
    public func updateExposureEV(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, -3.0), 3.0)
        switch activeMutationScope {
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
        let sanitizedSetting: WhiteBalanceSetting
        switch setting {
        case .asShot:
            sanitizedSetting = .asShot
        case .custom(let temperatureKelvin, let tint):
            guard temperatureKelvin.isFinite && tint.isFinite else { return }
            let clampedKelvin = min(max(temperatureKelvin, 2000.0), 15000.0)
            let clampedTint = min(max(tint, -150.0), 150.0)
            sanitizedSetting = .custom(temperatureKelvin: clampedKelvin, tint: clampedTint)
        }
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.whiteBalance = sanitizedSetting
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.whiteBalanceOverride = (sanitizedSetting == activePreset.developDefaults.whiteBalance) ? nil : sanitizedSetting
            }
        }
    }

    public func updatePresetModeWhiteBalanceKelvin(_ kelvin: Double) {
        guard kelvin.isFinite else { return }
        let clampedK = min(max(kelvin, 2000.0), 15000.0)
        let currentTint: Double = {
            if case .custom(_, let t) = selectedEffectiveParams.develop.whiteBalance {
                return t
            }
            return 0.0
        }()
        updateWhiteBalance(.custom(temperatureKelvin: clampedK, tint: currentTint))
    }

    public func updateShadowRecovery(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.shadowRecovery = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.shadowRecoveryOverride = abs(clamped - activePreset.developDefaults.shadowRecovery) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateBlackPoint(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, -100.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.blackPoint = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.blackPointOverride = abs(clamped - activePreset.developDefaults.blackPoint) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateClarity(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, -100.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.clarity = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.clarityOverride = abs(clamped - activePreset.developDefaults.clarity) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateOpticalSharpness(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.opticalSharpness = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.opticalSharpnessOverride = abs(clamped - activePreset.developDefaults.opticalSharpness) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateVibrance(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, -100.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.vibrance = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.vibranceOverride = abs(clamped - activePreset.developDefaults.vibrance) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateHighlightReconstruction(_ mode: HighlightReconstructionMode) {
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.highlightReconstruction = mode
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.highlightReconstructionOverride = (mode == activePreset.developDefaults.highlightReconstruction) ? nil : mode
            }
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
        panel.prompt = ChiaroStrings.msgPickDCPPrompt(resolvedLanguage)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                _ = try DCPProfile(contentsOf: url)
                updateCameraProfile(.dcp(path: url.path))
            } catch {
                alertMessage = "\(error)"
            }
        }
    }

    public func presentPickCubeLUTPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .plainText]
        panel.prompt = ChiaroStrings.msgPickCubePrompt(resolvedLanguage)
        if panel.runModal() == .OK, let url = panel.url {
            do {
                _ = try CubeLUT(contentsOf: url)
                activePreset.developDefaults.cubeLUTPath = url.path
                schedulePreviewRender(immediate: true)
            } catch {
                alertMessage = "\(error)"
            }
        }
    }

    public func clearCubeLUT() {
        activePreset.developDefaults.cubeLUTPath = nil
        schedulePreviewRender(immediate: true)
    }

    // Group 3: SDR Controls
    public func updateSDRToneMapper(_ mapper: SDRToneMapper) {
        switch activeMutationScope {
        case .globalPreset:
            activePreset.sdrToneMapper = mapper
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.sdrToneMapperOverride = (mapper == activePreset.sdrToneMapper) ? nil : mapper
            }
        }
    }

    public func updateSDRExposureEV(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, -1.0), 1.0)
        switch activeMutationScope {
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
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.sdrHighlightCompression = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.sdrHighlightCompressionOverride = abs(clamped - activePreset.developDefaults.sdrHighlightCompression) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateSDRContrast(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, -100.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.sdrContrast = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.sdrContrastOverride = abs(clamped - activePreset.developDefaults.sdrContrast) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateSDRSaturation(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, -100.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.sdrSaturation = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.sdrSaturationOverride = abs(clamped - activePreset.developDefaults.sdrSaturation) < 1e-4 ? nil : clamped
            }
        }
    }

    // Group 4: HDR & Gain Map
    public func updateTargetHeadroomStops(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0.0), 4.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.targetHeadroomStops = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.targetHeadroomStopsOverride = abs(clamped - activePreset.targetHeadroomStops) < 1e-4 ? nil : clamped
            }
        }
    }

    /// Updates Preset Mode HDR Intensity (`1.0...3.5 EV`) with coupled `hdrHighlightExcitation`.
    /// Must ONLY be called when the user actively drags/adjusts the Preset Mode HDR slider,
    /// ensuring a 4.0 EV Pro setting is never clobbered on mode switch or view render.
    public func updatePresetModeHDRIntensity(_ stops: Double) {
        guard stops.isFinite else { return }
        let clamped = min(max(stops, 1.0), 3.5)
        let coupledExcitation = ProOverrideInspector.expectedPresetExcitation(forHeadroomStops: clamped)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.targetHeadroomStops = clamped
            activePreset.developDefaults.hdrHighlightExcitation = coupledExcitation
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.targetHeadroomStopsOverride = abs(clamped - activePreset.targetHeadroomStops) < 1e-4 ? nil : clamped
                d.hdrHighlightExcitationOverride = abs(coupledExcitation - activePreset.developDefaults.hdrHighlightExcitation) < 1e-4 ? nil : coupledExcitation
            }
        }
    }

    public func updateMidtoneAnchorP(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0.65), 0.95)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.midtoneAnchorP = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.midtoneAnchorPOverride = abs(clamped - activePreset.midtoneAnchorP) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateHDRHighlightExcitation(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.hdrHighlightExcitation = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.hdrHighlightExcitationOverride = abs(clamped - activePreset.developDefaults.hdrHighlightExcitation) < 1e-4 ? nil : clamped
            }
        }
    }

    public func updateHDRRolloffSoftness(_ newValue: Double) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0.0), 100.0)
        switch activeMutationScope {
        case .globalPreset:
            activePreset.developDefaults.hdrRolloffSoftness = clamped
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.hdrRolloffSoftnessOverride = abs(clamped - activePreset.developDefaults.hdrRolloffSoftness) < 1e-4 ? nil : clamped
            }
        }
    }

    public func setGainMapChannels(_ channels: GainMapChannels) {
        if channels == .rgb3ch && isRGB3chGainMapRestricted {
            activePreset.gainMapChannels = .mono1ch
            alertMessage = ChiaroStrings.msgRGB3chRestricted(resolvedLanguage)
            return
        }
        activePreset.gainMapChannels = channels
        if channels == .rgb3ch {
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
        guard gamma.isFinite else { return }
        activePreset.gainMapGamma = min(max(gamma, 0.25), 4.0)
        schedulePreviewRender()
    }

    public func setLegacyAppleGainMap(_ enabled: Bool) {
        activePreset.compatOptions.writeLegacyAppleHDRGainMap = enabled
        if enabled {
            activePreset.gainMapChannels = .mono1ch
        }
        schedulePreviewRender()
    }

    // Group 5: Composition & Output Guardrails
    public func updateCropAspect(_ aspect: AspectRatio) {
        switch activeMutationScope {
        case .globalPreset:
            activePreset.cropAspect = aspect
            schedulePreviewRender()
        case .perPhotoDelta:
            mutateSelectedDelta { d in
                d.cropAspectOverride = (aspect == activePreset.cropAspect) ? nil : aspect
            }
        }
    }

    public func updateCropOffsetX(_ x: Double) {
        guard x.isFinite else { return }
        mutateSelectedDelta { d in
            var off = d.cropOffset ?? .centered
            off.normalizedCenterX = min(max(x, 0.0), 1.0)
            d.cropOffset = (off == .centered) ? nil : off
        }
    }

    public func updateCropOffsetY(_ y: Double) {
        guard y.isFinite else { return }
        mutateSelectedDelta { d in
            var off = d.cropOffset ?? .centered
            off.normalizedCenterY = min(max(y, 0.0), 1.0)
            d.cropOffset = (off == .centered) ? nil : off
        }
    }

    public func updateMaxLongEdge(_ edge: Int?) {
        var sanitized = edge.map { max(64, $0 & ~1) }
        if activePreset.outputFormats.contains(.hlgMP4), let val = sanitized, val > 1920 {
            sanitized = 1920
        }
        switch activeMutationScope {
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
            guard formats.count > 1 else { return }
            formats.remove(at: idx)
        } else {
            formats.append(format)
        }
        activePreset.outputFormats = formats

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
        let params = selectedEffectiveParams
        let backend = params.decodeBackend
        let presetSnapshot = activePreset
        let headroom = simulatedHeadroom

        let lockLegacy = presetSnapshot.outputFormats.contains(.heic)
            && presetSnapshot.compatOptions.writeLegacyAppleHDRGainMap
            && presetSnapshot.gainMapChannels == .mono1ch

        let outputSpec = RenderOutputSpec(
            targetBitDepth: .bit8,
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
                self.currentOpticsInfo = snapshot.opticsResolution
                self.currentISO = snapshot.isoSpeed
                self.currentLensModel = snapshot.lensModel
                self.histogramBins = snapshot.histogramBins
                self.isRenderingPreview = false
                if let idx = self.items.firstIndex(where: { $0.sourceURL == snapshot.sourceURL }) {
                    self.items[idx].lastFallbackReason = snapshot.fallbackReason
                    self.items[idx].lastOpticsInfo = snapshot.opticsResolution
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

    public func buildExportJobs(validatedPreset: PresetSchema) -> [ExportJob] {
        items.map { item in
            let resolved = effectiveParams(for: item.sourceURL)
            var jobDelta = perPhotoDeltas[item.sourceURL] ?? PerPhotoDelta()
            if jobDelta.decodeBackendOverride == nil {
                jobDelta.decodeBackendOverride = resolved.decodeBackend
            }
            if jobDelta.demosaicOverride == nil {
                jobDelta.demosaicOverride = resolved.demosaic
            }
            if jobDelta.opticsOverride == nil {
                jobDelta.opticsOverride = resolved.optics
            }
            if jobDelta.denoiseOverride == nil {
                jobDelta.denoiseOverride = resolved.denoise
            }
            if jobDelta.aiColorOverride == nil {
                jobDelta.aiColorOverride = resolved.aiColor
            }

            let decodeOpts = DecodeOptions(
                backend: resolved.decodeBackend,
                highlightMode: resolved.develop.highlightReconstruction,
                isProxy: false,
                maxThreadsPerWorker: 2,
                customRenderedHDR: validatedPreset.compatOptions.writeCustomRenderedHDR,
                demosaicAlgorithm: resolved.demosaic
            )

            return ExportJob(
                id: item.id,
                inputURL: item.sourceURL,
                outputDirectory: outputDirectory,
                preset: validatedPreset,
                formatOverrides: validatedPreset.outputFormats,
                delta: jobDelta.isEmpty ? nil : jobDelta,
                decodeOptions: decodeOpts,
                namingTemplate: namingTemplate,
                useFormatSubdirectories: useFormatSubdirectories,
                conflictPolicy: conflictPolicy,
                verifyAfterExport: verifyAfterExport,
                useSidecar: false
            )
        }
    }

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
            alertMessage = "\(error)"
            return
        }

        let jobs = buildExportJobs(validatedPreset: validatedPreset)

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
