import ChiaroAppCore
import ChiaroCore
import Foundation
import Testing

extension ChiaroSerializedSuites {
    @Suite("AppDualModeTests", .serialized)
    struct AppDualModeTests {
        private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
            let suiteName = "io.github.zhangliangchen.chiaro.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            return (defaults, suiteName)
        }

        private func makeTempDir(prefix: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        @Test("WorkspaceMode defaults to .preset, persists preferences, and toggles inline docs per mode")
        @MainActor
        func testWorkspaceModeAndDefaultsPersistence() {
            let (defaults, suiteName) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm1 = AppViewModel(userDefaults: defaults)
            #expect(vm1.workspaceMode == .preset)
            #expect(vm1.appLanguage == .system)
            #expect(vm1.autoSaveSidecar == true)
            #expect(vm1.showInlineParameterSummaries == true)

            vm1.toggleWorkspaceMode()
            #expect(vm1.workspaceMode == .pro)
            #expect(vm1.showInlineParameterSummaries == false)

            vm1.showInlineParameterSummaries = true
            vm1.appLanguage = .en
            vm1.autoSaveSidecar = false

            let vm2 = AppViewModel(userDefaults: defaults)
            #expect(vm2.workspaceMode == .pro)
            #expect(vm2.appLanguage == .en)
            #expect(vm2.autoSaveSidecar == false)
            #expect(vm2.showInlineParameterSummaries == true)

            vm2.toggleWorkspaceMode()
            #expect(vm2.workspaceMode == .preset)
            #expect(vm2.showInlineParameterSummaries == true)
        }

        @Test("All 7 built-in presets report zero Pro overrides upon initial selection")
        @MainActor
        func testAllBuiltInPresetsHaveZeroInitialProOverrides() throws {
            let (defaults, suiteName) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm = AppViewModel(userDefaults: defaults)
            let presets = try PresetLoader.loadAllBuiltIn()
            #expect(presets.count == 7)

            for preset in presets {
                vm.selectPreset(preset)
                #expect(
                    vm.activeProOnlyOverrides.isEmpty,
                    "Preset '\(preset.id)' falsely flagged Pro overrides: \(vm.activeProOnlyOverrides)"
                )
            }
        }

        @Test("Lossless Preset <-> Pro switching preserves Pro overrides and resetProOnlyOverrides keeps Preset edits")
        @MainActor
        func testLosslessDualModeAndResetProOverrides() {
            let (defaults, suiteName) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm = AppViewModel(userDefaults: defaults)
            vm.workspaceMode = .pro
            vm.editScope = .globalPreset

            // Preset-compatible adjustments
            vm.updateExposureEV(1.15)
            vm.updateShadowRecovery(35.0)
            vm.updateClarity(28.0)
            vm.updateVibrance(16.0)
            vm.updateOpticsEnabled(false)
            vm.updateDenoiseEnabled(false)
            vm.updateCropAspect(.ratio3x4)

            // Pro-only adjustments
            vm.updateDemosaicAlgorithm(.lmmse)
            vm.updateOpticsSource(.lensfun)
            vm.updateOpticalSharpness(45.0)
            vm.updateSDRToneMapper(.sigmoid)
            vm.updateSDRContrast(24.0)
            vm.updateMidtoneAnchorP(0.88)
            vm.setGainMapGamma(1.35)

            // Switch to Preset Mode: Pro overrides must remain intact and be counted
            vm.toggleWorkspaceMode()
            #expect(vm.workspaceMode == .preset)
            let overrides = vm.activeProOnlyOverrides
            #expect(overrides.contains(.demosaicAlgorithm))
            #expect(overrides.contains(.opticsSource))
            #expect(overrides.contains(.opticalSharpness))
            #expect(overrides.contains(.sdrToneMapper))
            #expect(overrides.contains(.sdrContrast))
            #expect(overrides.contains(.midtoneAnchorP))
            #expect(overrides.contains(.gainMapGamma))
            #expect(overrides.count >= 7)

            // Switch back to Pro Mode: zero data loss
            vm.toggleWorkspaceMode()
            #expect(vm.workspaceMode == .pro)
            #expect(vm.selectedEffectiveParams.demosaic == .lmmse)
            #expect(vm.selectedEffectiveParams.optics.source == .lensfun)
            #expect(vm.selectedEffectiveParams.develop.opticalSharpness == 45.0)
            #expect(vm.selectedEffectiveParams.sdrToneMapper == .sigmoid)
            #expect(vm.selectedEffectiveParams.develop.sdrContrast == 24.0)
            #expect(vm.selectedEffectiveParams.midtoneAnchorP == 0.88)
            #expect(vm.activePreset.gainMapGamma == 1.35)

            // Reset Pro overrides from Preset Mode: Pro cleared, Preset edits preserved
            vm.toggleWorkspaceMode()
            vm.resetProOnlyOverrides()

            #expect(vm.activeProOnlyOverrides.isEmpty)
            let resolved = vm.selectedEffectiveParams
            #expect(abs(resolved.develop.exposureEV - 1.15) < 1e-4)
            #expect(abs(resolved.develop.shadowRecovery - 35.0) < 1e-4)
            #expect(abs(resolved.develop.clarity - 28.0) < 1e-4)
            #expect(abs(resolved.develop.vibrance - 16.0) < 1e-4)
            #expect(resolved.optics.enabled == false)
            #expect(resolved.denoise.mode == .off)
            #expect(resolved.cropAspect == .ratio3x4)

            #expect(resolved.demosaic == .amaze)
            #expect(resolved.optics.source == .auto)
            #expect(resolved.develop.opticalSharpness == 0.0)
        }

        @Test("Preset Mode HDR 1.0..3.5 EV couples excitation cleanly without clobbering 4.0 EV Pro headroom")
        @MainActor
        func testPresetHDRCouplingAnd4EVNonClobbering() {
            let (defaults, suiteName) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm = AppViewModel(userDefaults: defaults)

            // 1. Adjusting Preset Mode HDR slider in 1.0..3.5 sets coupled excitation with 0 Pro overrides
            vm.updatePresetModeHDRIntensity(3.0)
            #expect(abs(vm.selectedEffectiveParams.targetHeadroom.log2Value - 3.0) < 1e-4)
            let expectedEx = ProOverrideInspector.expectedPresetExcitation(forHeadroomStops: 3.0)
            #expect(abs(vm.selectedEffectiveParams.develop.hdrHighlightExcitation - expectedEx) < 1e-4)
            #expect(vm.activeProOnlyOverrides.isEmpty)

            // 2. Setting 4.0 EV in Pro Mode and switching to Preset Mode does NOT clobber 4.0 EV
            vm.workspaceMode = .pro
            vm.updateTargetHeadroomStops(4.0)
            #expect(abs(vm.selectedEffectiveParams.targetHeadroom.log2Value - 4.0) < 1e-4)

            vm.workspaceMode = .preset
            #expect(abs(vm.selectedEffectiveParams.targetHeadroom.log2Value - 4.0) < 1e-4)
            #expect(vm.activeProOnlyOverrides.contains(.targetHeadroomStops))

            // 3. Only explicit drag updates it back into 1.0..3.5 EV
            vm.updatePresetModeHDRIntensity(2.5)
            #expect(abs(vm.selectedEffectiveParams.targetHeadroom.log2Value - 2.5) < 1e-4)
            #expect(vm.activeProOnlyOverrides.isEmpty)
        }

        @Test("Preset Mode WB Kelvin slider transitions As-Shot -> Custom and resets cleanly")
        @MainActor
        func testPresetWhiteBalanceConversion() {
            let (defaults, suiteName) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm = AppViewModel(userDefaults: defaults)
            #expect(vm.selectedEffectiveParams.develop.whiteBalance == .asShot)

            vm.updatePresetModeWhiteBalanceKelvin(6400.0)
            #expect(vm.selectedEffectiveParams.develop.whiteBalance == .custom(temperatureKelvin: 6400.0, tint: 0.0))
            #expect(vm.activeProOnlyOverrides.isEmpty)

            vm.updateWhiteBalance(.asShot)
            #expect(vm.selectedEffectiveParams.develop.whiteBalance == .asShot)
        }

        @Test("Sidecar .chiaro.json auto-save/load round-trip, ARW-only discovery, and export WYSIWYG parity")
        @MainActor
        func testSidecarLifecycleARWDiscoveryAndExportParity() async throws {
            let (defaults, suiteName) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let tmpDir = try makeTempDir(prefix: "chiaro-m5-sidecar")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let arwURL = tmpDir.appendingPathComponent("DSC00001.ARW")
            let hifURL = tmpDir.appendingPathComponent("DSC00001.HIF")
            let fakeARWDir = tmpDir.appendingPathComponent("Folder.ARW", isDirectory: true)
            try Data("FAKE_ARW".utf8).write(to: arwURL)
            try Data("FAKE_HIF".utf8).write(to: hifURL)
            try FileManager.default.createDirectory(at: fakeARWDir, withIntermediateDirectories: true)

            let vm = AppViewModel(userDefaults: defaults)
            vm.importDroppedOrOpenedURLs([tmpDir])

            #expect(vm.items.count == 1)
            #expect(vm.items.first?.fileName == "DSC00001.ARW")
            #expect(vm.hasSidecar(for: vm.items[0]) == false)
            #expect(!ChiaroSidecar.exists(for: arwURL))

            // User mutations in Preset Mode & Pro Mode write atomic .chiaro.json
            vm.updateExposureEV(0.75)
            vm.updateClarity(32.0)
            vm.workspaceMode = .pro
            vm.editScope = .perPhotoDelta
            vm.updateDemosaicAlgorithm(.lmmse)
            vm.updateOpticsSource(.lensfun)
            vm.updateDenoiseChroma(82.0)

            await vm.flushPendingSidecarSaves()

            #expect(ChiaroSidecar.exists(for: arwURL))
            #expect(vm.hasSidecar(for: vm.items[0]) == true)

            let savedSidecar = try #require(try ChiaroSidecar.loadIfExists(for: arwURL))
            #expect(savedSidecar.schemaVersion == ChiaroSidecar.currentSchemaVersion)
            #expect(savedSidecar.demosaic == .lmmse)
            #expect(savedSidecar.optics?.source == .lensfun)
            #expect(savedSidecar.denoise?.chromaStrength == 82.0)
            #expect(savedSidecar.delta?.clarityOverride == 32.0)

            // Verify export job builder reflects exact in-memory edits with useSidecar == false
            let jobs = vm.buildExportJobs(validatedPreset: vm.activePreset)
            #expect(jobs.count == 1)
            let job = try #require(jobs.first)
            #expect(job.useSidecar == false)
            #expect(job.decodeOptions.demosaicAlgorithm == .lmmse)
            #expect(job.delta?.opticsOverride?.source == .lensfun)
            #expect(job.delta?.denoiseOverride?.chromaStrength == 82.0)

            // Fresh AppViewModel auto-loads existing sidecar on import without mutating disk
            let vmReloaded = AppViewModel(userDefaults: defaults)
            vmReloaded.importDroppedOrOpenedURLs([arwURL])
            #expect(vmReloaded.items.count == 1)
            #expect(vmReloaded.hasSidecar(for: vmReloaded.items[0]) == true)
            let reloadedEffective = vmReloaded.selectedEffectiveParams
            #expect(abs(reloadedEffective.develop.exposureEV - 0.75) < 1e-4)
            #expect(abs(reloadedEffective.develop.clarity - 32.0) < 1e-4)
            #expect(reloadedEffective.demosaic == .lmmse)
            #expect(reloadedEffective.optics.source == .lensfun)
            #expect(abs(reloadedEffective.denoise.chromaStrength - 82.0) < 1e-4)

            // Deleting sidecar removes file and badge
            vmReloaded.deleteSidecar(for: vmReloaded.items[0])
            #expect(!ChiaroSidecar.exists(for: arwURL))
            #expect(vmReloaded.hasSidecar(for: vmReloaded.items[0]) == false)
        }

        @Test("Disabling autoSaveSidecar cancels pending debounced sidecar save tasks without writing to disk")
        @MainActor
        func testDisablingAutoSaveCancelsPendingDebouncedSidecarSave() async throws {
            let (defaults, suiteName) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let tmpDir = try makeTempDir(prefix: "chiaro-m5-sidecar-cancel")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let arwURL = tmpDir.appendingPathComponent("DSC00002.ARW")
            try Data("FAKE_ARW".utf8).write(to: arwURL)

            let vm = AppViewModel(userDefaults: defaults)
            #expect(vm.autoSaveSidecar == true)
            vm.importDroppedOrOpenedURLs([arwURL])
            #expect(vm.items.count == 1)
            #expect(!ChiaroSidecar.exists(for: arwURL))

            // Trigger a debounced sidecar save, then immediately disable autoSaveSidecar
            vm.updateClarity(18.0)
            vm.autoSaveSidecar = false

            // Wait past the 250ms debounce window and also verify flushPendingSidecarSaves is a no-op
            try await Task.sleep(for: .milliseconds(350))
            await vm.flushPendingSidecarSaves()

            #expect(ChiaroSidecar.exists(for: arwURL) == false)
            #expect(vm.hasSidecar(for: vm.items[0]) == false)
        }

        @Test(
            "Real ARW PreviewRenderService executes ProfiledDenoise + EmbeddedOptics + Sigmoid + Clarity + OpticalSharpness",
            .enabled(if: TestFixtures.hasSampleDirectory, "Set CHIARO_SAMPLE_DIR to run real-ARW integration tests")
        )
        @MainActor
        func testRealARWPreviewAndSidecarRoundTrip() async throws {
            let sampleURL = TestFixtures.sampleDirectory.appendingPathComponent("DSC02532.ARW")
            let tmpDir = try makeTempDir(prefix: "chiaro-m5-real-arw")
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let copiedARW = tmpDir.appendingPathComponent("DSC02532.ARW")
            try FileManager.default.copyItem(at: sampleURL, to: copiedARW)

            let preset = try PresetLoader.loadBuiltIn(id: .appleHEIC)
            var delta = PerPhotoDelta()
            delta.sdrToneMapperOverride = .sigmoid
            delta.clarityOverride = 25.0
            delta.opticalSharpnessOverride = 35.0

            let params = EffectiveDevelopParams.resolve(preset: preset, delta: delta)
            let service = PreviewRenderService()
            let outputSpec = RenderOutputSpec(
                targetBitDepth: .bit8,
                baseColorSpace: preset.baseColorSpace,
                gainMapChannels: preset.gainMapChannels,
                gainMapResolution: preset.gainMapResolution,
                gainMapGamma: preset.gainMapGamma,
                lockLegacyAppleGainMapBounds: false
            )

            let snapshot = try await service.renderPreviewAndHistogram(
                url: copiedARW,
                backend: .libraw,
                params: params,
                outputSpec: outputSpec,
                displayHeadroom: .x4
            )

            #expect(snapshot.renderedFrame.sdrLinearTexture != nil)
            #expect(snapshot.opticsResolution.source == .embeddedARW)
            #expect(snapshot.histogramBins.count == 256)
            #expect(snapshot.histogramBins.reduce(0, +) > 0)

            await service.invalidateOpticsEngine()

            // Verify AppViewModel sidecar round-trip on the copied ARW
            let (defaults, suiteName) = makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let vm = AppViewModel(userDefaults: defaults)
            vm.importDroppedOrOpenedURLs([copiedARW])
            vm.updateClarity(22.0)
            await vm.flushPendingSidecarSaves()

            #expect(ChiaroSidecar.exists(for: copiedARW))
            #expect(vm.items.first.map { vm.hasSidecar(for: $0) } == true)
        }
    }
}
